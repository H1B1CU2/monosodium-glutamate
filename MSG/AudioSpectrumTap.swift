import AppKit
import CoreAudio
import Accelerate

/// Number of visualizer bars. Shared by the tap engine, the menu bar renderer,
/// and the tray popover so they always agree. Top-level (not on the 14.2-gated
/// class) so pre-14.2 code paths can reference it too.
let audioVisualizerBandCount = 6

/// Captures the live system audio mix through a Core Audio process tap
/// (macOS 14.2+) and reduces it to a few smoothed frequency-band levels that
/// drive the now-playing visualizer bars (menu bar + tray popover).
///
/// First use triggers the one-time "record audio from other applications"
/// system prompt (System Audio Recording, not Screen Recording). If the tap
/// can't produce audio — permission denied, older OS — `isDelivering` /
/// `hasSignal` stay false and consumers keep their random-motion fallback.
@available(macOS 14.2, *)
final class AudioSpectrumTap {

    static let shared = AudioSpectrumTap()
    static let bandCount = audioVisualizerBandCount

    /// Latest smoothed band levels (0…1, low → high frequency). Main thread only.
    private(set) var levels: [CGFloat] = Array(repeating: 0, count: AudioSpectrumTap.bandCount)

    /// True while tap buffers have arrived within the last second.
    var isDelivering: Bool { CACurrentMediaTime() - lastDeliveryTime < 1.0 }

    /// True once actual signal (not silence) has been seen since capture
    /// start. Distinguishes a denied-permission tap, which delivers only
    /// silence, from a working one during a quiet passage.
    private(set) var hasSignal = false

    private var lastDeliveryTime: CFTimeInterval = 0
    private var consumers = 0

    // Core Audio objects
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?
    private let ioQueue = DispatchQueue(label: "msg.audio-spectrum-tap")

    // DSP state — touched only on ioQueue while capture runs
    private let fftSize = 1024
    private let log2n = vDSP_Length(10)
    private var fftSetup: FFTSetup?
    private var window = [Float]()
    private var pending = [Float]()
    private var sampleRate: Double = 48000
    private var bandSmoothed = [Float](repeating: 0, count: AudioSpectrumTap.bandCount)
    private var agcCeilingDb: Float = -28

    /// Band edges in Hz (bandCount + 1 entries, log-spaced) plus a mild treble
    /// tilt so the upper bars aren't dwarfed by bass energy.
    private let bandEdges: [Double] = [40, 100, 250, 650, 1700, 4400, 12000]
    private let bandTiltDb: [Float] = [0, 2.4, 4.8, 7.2, 9.6, 12]

    // MARK: - Consumers (main thread)

    func acquire() {
        consumers += 1
        if consumers == 1 { startCapture() }
    }

    func release() {
        consumers = max(0, consumers - 1)
        if consumers == 0 { stopCapture() }
    }

    // MARK: - Capture lifecycle

    private func startCapture() {
        guard aggregateID == kAudioObjectUnknown else { return }

        let desc = CATapDescription(monoGlobalTapButExcludeProcesses: [])
        desc.name = "MSG Visualizer Tap"
        desc.isPrivate = true

        var tap = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateProcessTap(desc, &tap) == noErr, tap != kAudioObjectUnknown else { return }
        tapID = tap

        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        if AudioObjectGetPropertyData(tapID, &addr, 0, nil, &size, &asbd) == noErr, asbd.mSampleRate > 0 {
            sampleRate = asbd.mSampleRate
        }

        // Aggregate device: default output as clock source + our tap as input
        var aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey: "MSG Visualizer Tap",
            kAudioAggregateDeviceUIDKey: AudioDeviceRouting.visualizerTapUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: desc.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        if let outputUID = defaultOutputDeviceUID() {
            aggDesc[kAudioAggregateDeviceMainSubDeviceKey] = outputUID
            aggDesc[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: outputUID]]
        }

        var agg = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &agg) == noErr,
              agg != kAudioObjectUnknown else {
            stopCapture()
            return
        }
        aggregateID = agg

        if fftSetup == nil {
            fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
            window = [Float](repeating: 0, count: fftSize)
            vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        }
        ioQueue.async { [weak self] in
            guard let self else { return }
            self.pending.removeAll(keepingCapacity: true)
            self.bandSmoothed = [Float](repeating: 0, count: Self.bandCount)
        }

        let status = AudioDeviceCreateIOProcIDWithBlock(&ioProcID, aggregateID, ioQueue) { [weak self] _, inInputData, _, _, _ in
            self?.processBuffers(inInputData)
        }
        guard status == noErr, ioProcID != nil, AudioDeviceStart(aggregateID, ioProcID) == noErr else {
            stopCapture()
            return
        }
    }

    private func stopCapture() {
        if aggregateID != kAudioObjectUnknown, let proc = ioProcID {
            AudioDeviceStop(aggregateID, proc)
            AudioDeviceDestroyIOProcID(aggregateID, proc)
        }
        ioProcID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = AudioObjectID(kAudioObjectUnknown)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = AudioObjectID(kAudioObjectUnknown)
        }
        levels = Array(repeating: 0, count: Self.bandCount)
        lastDeliveryTime = 0
        hasSignal = false
    }

    private func defaultOutputDeviceUID() -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID) == noErr,
              deviceID != kAudioObjectUnknown else { return nil }
        addr.mSelector = kAudioDevicePropertyDeviceUID
        var uid: CFString?
        size = UInt32(MemoryLayout<CFString?>.size)
        let err = withUnsafeMutablePointer(to: &uid) {
            AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, $0)
        }
        guard err == noErr, let uid else { return nil }
        return uid as String
    }

    // MARK: - DSP (ioQueue)

    private func processBuffers(_ list: UnsafePointer<AudioBufferList>) {
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: list))
        // The mono global tap delivers a single buffer; if a stereo format
        // ever shows up, mix interleaved channels down to mono.
        if let buf = abl.first(where: { $0.mData != nil }), let data = buf.mData {
            let floats = data.assumingMemoryBound(to: Float.self)
            let count = Int(buf.mDataByteSize) / MemoryLayout<Float>.size
            let ch = max(1, Int(buf.mNumberChannels))
            if ch == 1 {
                pending.append(contentsOf: UnsafeBufferPointer(start: floats, count: count))
            } else {
                let frames = count / ch
                pending.reserveCapacity(pending.count + frames)
                for f in 0..<frames {
                    var sum: Float = 0
                    for c in 0..<ch { sum += floats[f * ch + c] }
                    pending.append(sum / Float(ch))
                }
            }
        }
        while pending.count >= fftSize { analyzeChunk() }
        if pending.count > fftSize * 4 { pending.removeAll(keepingCapacity: true) }
    }

    /// Consumes `fftSize` samples from `pending`, publishes band levels.
    private func analyzeChunk() {
        guard let setup = fftSetup else {
            pending.removeFirst(fftSize)
            return
        }

        var windowed = [Float](repeating: 0, count: fftSize)
        pending.withUnsafeBufferPointer {
            vDSP_vmul($0.baseAddress!, 1, window, 1, &windowed, 1, vDSP_Length(fftSize))
        }
        pending.removeFirst(fftSize)

        let halfN = fftSize / 2
        var power = [Float](repeating: 0, count: halfN)
        var real = [Float](repeating: 0, count: halfN)
        var imag = [Float](repeating: 0, count: halfN)
        real.withUnsafeMutableBufferPointer { rp in
            imag.withUnsafeMutableBufferPointer { ip in
                var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                windowed.withUnsafeBufferPointer { wp in
                    wp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: halfN) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(halfN))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &power, 1, vDSP_Length(halfN))
            }
        }

        // Mean power per band → dB (0 dB ≈ full-scale), plus treble tilt
        let norm = 1.0 / Float(fftSize * fftSize)
        let hzPerBin = sampleRate / Double(fftSize)
        var bandDb = [Float](repeating: -120, count: Self.bandCount)
        for b in 0..<Self.bandCount {
            let lo = max(1, Int(bandEdges[b] / hzPerBin))
            let hi = min(halfN - 1, Int(bandEdges[b + 1] / hzPerBin))
            guard hi >= lo else { continue }
            var sum: Float = 0
            for i in lo...hi { sum += power[i] }
            let mean = sum / Float(hi - lo + 1) * norm
            bandDb[b] = 10 * log10f(max(mean, 1e-12)) + bandTiltDb[b]
        }

        // Auto gain: ride a slowly decaying ceiling so quiet and loud sources
        // both use the full bar range; floor keeps silence from being amplified.
        let range: Float = 36
        agcCeilingDb = max(bandDb.max() ?? -120, agcCeilingDb - 0.15, -40)
        let floorDb = agcCeilingDb - range

        // Fast attack, slower release
        for b in 0..<Self.bandCount {
            let target = min(1, max(0, (bandDb[b] - floorDb) / range))
            bandSmoothed[b] += (target - bandSmoothed[b]) * (target > bandSmoothed[b] ? 0.55 : 0.2)
        }

        let published = bandSmoothed.map { CGFloat($0) }
        DispatchQueue.main.async { [weak self] in
            guard let self, self.aggregateID != kAudioObjectUnknown else { return }
            self.levels = published
            self.lastDeliveryTime = CACurrentMediaTime()
            if !self.hasSignal, published.contains(where: { $0 > 0.02 }) {
                self.hasSignal = true
            }
        }
    }
}
