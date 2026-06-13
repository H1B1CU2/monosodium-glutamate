import SwiftUI
import AppKit
import Combine

// MARK: - Corner Preview

@available(macOS 14.0, *)
struct CornerPreviewView: View {
    let radius: CGFloat
    let topEnabled: Bool
    let bottomEnabled: Bool
    let underBar: Bool
    var wallpaperImage: NSImage? = nil

    var body: some View {
        DisplayPreviewView(
            stackMode: .inline,
            spaceCount: 4, activeSpace: 2,
            showMusic: false, screenCount: 1,
            cornerRadius: radius,
            topCornersEnabled: topEnabled,
            bottomCornersEnabled: bottomEnabled,
            underMenuBar: underBar,
            wallpaperImage: wallpaperImage
        )
    }
}

// MARK: - Music Preview

@available(macOS 14.0, *)
struct MusicPreviewView: View {
    let mode: MusicDisplayMode
    var wallpaperImage: NSImage? = nil

    var body: some View {
        DisplayPreviewView(
            stackMode: .inline,
            spaceCount: 4, activeSpace: 2,
            showMusic: mode != .off, screenCount: 1,
            fixedHeight: 80,
            wallpaperImage: wallpaperImage
        )
    }
}

struct TrackpadPreview: View {
    @State private var fingerX: CGFloat = -20

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(LinearGradient(colors: [Color(hex: 0xf3f3f5), Color(hex: 0xe2e2e6)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
            ForEach([-4, 6], id: \.self) { dy in
                Circle()
                    .fill(Color.accentColor)
                    .frame(width: 9, height: 9)
                    .shadow(color: Color.accentColor.opacity(0.3), radius: 4)
                    .offset(x: fingerX, y: CGFloat(dy))
            }
        }
        .onAppear {
            withAnimation(.easeInOut(duration: 1.3).repeatForever(autoreverses: true)) { fingerX = 20 }
        }
    }
}

// MARK: - Spacer Preview Scene (top-right crop, mirrors MusicPopoverScene)

@available(macOS 14.0, *)
struct SpacerPreviewScene: View {
    let stackMode: StackMode
    let screenCount: Int
    var wallpaperImage: NSImage? = nil
    @State private var activeSpace: Int = 2
    private let spaceCount = 5
    private let menuBarHeight: CGFloat = 30
    private let trailingPad: CGFloat = 16

    private var screenRatio: CGFloat {
        guard let s = NSScreen.main else { return 1.6 }
        return s.frame.width / s.frame.height
    }

    var body: some View {
        Color.clear
            .aspectRatio(screenRatio, contentMode: .fit)
            .overlay(sceneContent)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
            .onReceive(Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()) { _ in
                activeSpace = activeSpace >= spaceCount ? 1 : activeSpace + 1
            }
    }

    private var sceneContent: some View {
        ZStack(alignment: .topTrailing) {
            if let wp = wallpaperImage {
                Image(nsImage: wp).resizable().aspectRatio(contentMode: .fill)
                    .scaleEffect(2.0, anchor: .topTrailing)
            } else {
                LinearGradient(
                    stops: [
                        .init(color: Color(hex: 0x5b8def), location: 0),
                        .init(color: Color(hex: 0x8a6df3), location: 0.5),
                        .init(color: Color(hex: 0xd660b4), location: 1),
                    ],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            }
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Spacer()
                    PreviewSpaceIndicator(
                        stackMode: stackMode,
                        spaceCount: spaceCount, activeSpace: activeSpace,
                        screenCount: screenCount,
                        scale: 2.0
                    )
                    Image(systemName: "switch.2")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundColor(Color.black.opacity(0.85))
                    Text("10:00")
                        .font(.system(size: 12))
                        .foregroundColor(Color.black.opacity(0.85))
                }
                .padding(.horizontal, trailingPad)
                .frame(height: menuBarHeight)
                .background(Color.white.opacity(0.65))
                Spacer()
            }
        }
    }
}

// MARK: - Music Popover Preview

@available(macOS 14.0, *)
struct MusicPopoverPreview: View {
    // Proportions mirror MusicPopover.swift: 208×220 popover, 160×160 touchpad,
    // 20pt volume bar column with 6pt track, 30pt corner radius.
    var width: CGFloat = 208
    private var refW: CGFloat { 208 }
    private var refH: CGFloat { 220 }
    private var s: CGFloat { width / refW }
    private var height: CGFloat { refH * s }
    private var inset: CGFloat { 12 * s }
    private var touchpadSize: CGFloat { 160 * s }
    private var volColW: CGFloat { 20 * s }
    private var volBarHeight: CGFloat { 140 * s }
    private var trackW: CGFloat { 6 * s }
    private var cornerR: CGFloat { 30 * s }
    private var touchpadCornerR: CGFloat { 20 * s }
    private var volumeLevel: CGFloat { 0.62 }

    var body: some View {
        ZStack(alignment: .topLeading) {
            HStack(alignment: .top, spacing: 4 * s) {
                touchpad
                volumeColumn
                    .padding(.leading, 4)
            }
            .padding(.leading, inset)
            .padding(.top, inset)

            VStack(alignment: .leading, spacing: 2 * s) {
                Text("Miss Summer")
                    .font(.system(size: 12 * s, weight: .semibold))
                    .foregroundColor(.white)
                Text("temp.")
                    .font(.system(size: 11 * s))
                    .foregroundColor(.white.opacity(0.55))
            }
            .padding(.leading, 26 * s)
            .padding(.top, inset + touchpadSize + 6 * s)
        }
        .frame(width: width, height: height, alignment: .topLeading)
        .background(
            ZStack {
                VisualEffectBlur(material: .fullScreenUI, blendingMode: .withinWindow)
                Color.black.opacity(0.08)
            }
            .clipShape(RoundedRectangle(cornerRadius: cornerR))
        )
        .overlay(RoundedRectangle(cornerRadius: cornerR).strokeBorder(Color.white.opacity(0.12), lineWidth: 1))
    }

    private var touchpad: some View {
        RoundedRectangle(cornerRadius: touchpadCornerR)
            .fill(Color.white.opacity(0.06))
            .overlay(
                Canvas { ctx, size in
                    let dot = Color.white.opacity(0.10)
                    let padInset: CGFloat = 24 * s
                    let rows = 8
                    let vSpacing = (size.height - 2 * padInset) / CGFloat(rows - 1)
                    let cols = max(8, Int((size.width - 2 * padInset) / vSpacing + 0.5))
                    let spacing = min((size.width - 2 * padInset) / CGFloat(cols - 1), vSpacing)
                    let gridW = spacing * CGFloat(cols - 1)
                    let gridH = spacing * CGFloat(rows - 1)
                    let offsetX = (size.width - gridW) / 2
                    let offsetY = (size.height - gridH) / 2
                    let r: CGFloat = 1.0 * s
                    for row in 0..<rows {
                        for col in 0..<cols {
                            let x = offsetX + CGFloat(col) * spacing
                            let y = offsetY + CGFloat(row) * spacing
                            let rect = CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)
                            ctx.fill(Path(ellipseIn: rect), with: .color(dot))
                        }
                    }
                }
            )
            .frame(width: touchpadSize, height: touchpadSize)
    }

    private var volumeColumn: some View {
        ZStack(alignment: .top) {
            // Track + fill stack
            HStack(spacing: 7 * s) {
                ZStack(alignment: .bottom) {
                    Capsule()
                        .fill(Color.white.opacity(0.08))
                        .frame(width: trackW)
                    Capsule()
                        .fill(Color.white.opacity(0.5))
                        .frame(width: trackW, height: max(trackW, volBarHeight * volumeLevel - 8 * s))
                }
                .frame(height: volBarHeight - 8 * s)
                .padding(.vertical, 4 * s)

                // Indicator dots
                VStack(spacing: 16 * s - 2 * s) {
                    ForEach(0..<8) { _ in
                        Circle()
                            .fill(Color.white.opacity(0.25))
                            .frame(width: 2 * s, height: 2 * s)
                    }
                }
                .padding(.top, 6 * s)
            }
        }
        .frame(width: volColW, height: volBarHeight, alignment: .top)
        .padding(.top, 10 * s)
    }
}

// Downward-pointing notch connecting menu bar label to popover
struct DownNotch: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
        p.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
        p.closeSubpath()
        return p
    }
}

@available(macOS 14.0, *)
struct MusicPopoverScene: View {
    var wallpaperImage: NSImage? = nil
    private let popoverWidth: CGFloat = 200
    private let menuBarHeight: CGFloat = 30
    private let trailingPad: CGFloat = 16

    private var screenRatio: CGFloat {
        guard let s = NSScreen.main else { return 1.6 }
        return s.frame.width / s.frame.height
    }

    var body: some View {
        Color.clear
            .aspectRatio(screenRatio, contentMode: .fit)
            .overlay(sceneContent)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
    }

    private var sceneContent: some View {
        ZStack(alignment: .topTrailing) {
            if let wp = wallpaperImage {
                Image(nsImage: wp).resizable().aspectRatio(contentMode: .fill)
                    .scaleEffect(2.0, anchor: .topTrailing)
            } else {
                LinearGradient(
                    stops: [
                        .init(color: Color(hex: 0x5b8def), location: 0),
                        .init(color: Color(hex: 0x8a6df3), location: 0.5),
                        .init(color: Color(hex: 0xd660b4), location: 1),
                    ],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            }

            // Minimal right-edge menu bar slice (music label + control center + time)
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Spacer()
                    musicLabel
                    Image(systemName: "switch.2")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundColor(Color.black.opacity(0.85))
                    Text("10:00")
                        .font(.system(size: 12))
                        .foregroundColor(Color.black.opacity(0.85))
                }
                .padding(.horizontal, trailingPad)
                .frame(height: menuBarHeight)
                .background(Color.white.opacity(0.65))
                Spacer()
            }

            // Popover anchored under the music label
            popoverAnimatedView
            .padding(.top, menuBarHeight + 6)
            .padding(.trailing, 78)
        }
    }

    private var musicLabel: some View {
        HStack(spacing: 6) {
            Text("Miss Summer — temp.")
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(Color.black.opacity(0.85))
            TimelineView(.animation) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                HStack(spacing: 2) {
                    ForEach(0..<4) { i in
                        RoundedRectangle(cornerRadius: 1)
                            .fill(Color.black.opacity(0.65))
                            .frame(width: 2, height: barH(i, at: t))
                    }
                }
            }
        }
    }

    private func barH(_ i: Int, at t: TimeInterval) -> CGFloat {
        let offsets: [CGFloat] = [0, 0.4, 0.9, 1.3]
        let phase = t * 2 * .pi / 1.2
        let h = sin(phase + offsets[i]) * 0.5 + 0.5
        return 5 + h * 8
    }

    private var popoverAnimatedView: some View {
        TimelineView(.animation) { timeline in
            MusicPopoverPreview(width: popoverWidth)
                .opacity(popoverAnim(at: timeline.date).opacity)
                .offset(x: 20, y: popoverAnim(at: timeline.date).offsetY)
        }
    }

    private func popoverAnim(at date: Date) -> (opacity: Double, offsetY: CGFloat) {
        let t = date.timeIntervalSinceReferenceDate
        let cycle = t.truncatingRemainder(dividingBy: 10.0)
        let appearing = cycle < 0.35
        let opacity: Double = appearing ? cycle / 0.35 : 1.0
        let offsetY: CGFloat = appearing ? CGFloat((1.0 - cycle / 0.35) * 10.0) : 0
        return (opacity, offsetY)
    }
}

// MARK: - Display Preview (16:10 simulated screen)

@available(macOS 14.0, *)
struct DisplayPreviewView: View {
    let stackMode: StackMode
    let spaceCount: Int
    let activeSpace: Int
    let showMusic: Bool
    let screenCount: Int
    var cornerRadius: CGFloat = 0
    var topCornersEnabled: Bool = false
    var bottomCornersEnabled: Bool = false
    var underMenuBar: Bool = false
    var fixedHeight: CGFloat? = nil
    var wallpaperImage: NSImage? = nil

    private let menuBarH: CGFloat = 20

    private var screenRatio: CGFloat {
        guard let s = NSScreen.main else { return 1.6 }
        return s.frame.width / s.frame.height
    }

    var body: some View {
        Group {
            if let h = fixedHeight {
                Color.clear.frame(height: h).aspectRatio(screenRatio, contentMode: .fill)
            } else {
                Color.clear.aspectRatio(screenRatio, contentMode: .fit)
            }
        }
        .overlay(displayContent)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
    }

    private var displayContent: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                if let wp = wallpaperImage {
                    Image(nsImage: wp).resizable().aspectRatio(contentMode: .fill)
                } else {
                    LinearGradient(
                        stops: [
                            .init(color: Color(hex: 0x5b8def), location: 0),
                            .init(color: Color(hex: 0x8a6df3), location: 0.5),
                            .init(color: Color(hex: 0xd660b4), location: 1),
                        ],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                }

                VStack(spacing: 0) {
                    PreviewMenuBar(
                        stackMode: stackMode,
                        spaceCount: spaceCount, activeSpace: activeSpace,
                        showMusic: showMusic, screenCount: screenCount
                    )
                    Spacer()
                }

                if cornerRadius > 0 {
                    Canvas { ctx, _ in drawCorners(ctx: &ctx, size: geo.size) }
                        .frame(width: geo.size.width, height: geo.size.height)
                }
            }
        }
    }

    private func drawCorners(ctx: inout GraphicsContext, size: CGSize) {
        let r = cornerRadius, c = Color.black.opacity(0.65), ty = underMenuBar ? menuBarH : CGFloat(0)

        func pie(_ path: inout Path, _ p: CGPoint, _ dx: CGFloat, _ center: CGPoint, _ start: Double, _ delta: Double) {
            path.move(to: p)
            path.addLine(to: CGPoint(x: p.x + dx, y: p.y))
            path.addRelativeArc(center: center, radius: r, startAngle: .degrees(start), delta: .degrees(delta))
            path.closeSubpath()
        }

        if topCornersEnabled {
            var tl = Path(); pie(&tl, CGPoint(x: 0, y: ty), r, CGPoint(x: r, y: ty + r), 270, -90)
            ctx.fill(tl, with: .color(c))
            var tr = Path(); pie(&tr, CGPoint(x: size.width, y: ty), -r, CGPoint(x: size.width - r, y: ty + r), 270, 90)
            ctx.fill(tr, with: .color(c))
        }
        if bottomCornersEnabled {
            var bl = Path(); pie(&bl, CGPoint(x: 0, y: size.height), r, CGPoint(x: r, y: size.height - r), 90, 90)
            ctx.fill(bl, with: .color(c))
            var br = Path(); pie(&br, CGPoint(x: size.width, y: size.height), -r, CGPoint(x: size.width - r, y: size.height - r), 90, -90)
            ctx.fill(br, with: .color(c))
        }
    }
}

// MARK: - Preview sub-views

struct PreviewMenuBar: View {
    let stackMode: StackMode
    let spaceCount: Int
    let activeSpace: Int
    let showMusic: Bool
    let screenCount: Int

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "apple.logo").font(.system(size: 7, weight: .medium))
            Text("Finder").font(.system(size: 8, weight: .semibold))
            Text("File").font(.system(size: 8)).opacity(0.75)
            Text("Edit").font(.system(size: 8)).opacity(0.75)
            Text("View").font(.system(size: 8)).opacity(0.75)
            Spacer()
            PreviewSpaceIndicator(stackMode: stackMode,
                                  spaceCount: spaceCount, activeSpace: activeSpace, screenCount: screenCount)
            if showMusic { PreviewMusicPill() }
            Image(systemName: "switch.2")
                .font(.system(size: 9))
            TimelineView(.periodic(from: .now, by: 30)) { _ in
                Text(Date.now, format: .dateTime.hour().minute())
                    .font(.system(size: 8))
            }
            Spacer().frame(width: 4)
        }
        .foregroundColor(Color.black.opacity(0.85))
        .padding(.horizontal, 10)
        .frame(height: 20)
        .background(Color.white.opacity(0.65))
    }
}

// Real renderer constants from IndicatorRenderer.swift, scaled for 20pt preview menu bar.
struct PillDotsDims {
    let dotD: CGFloat, pillW: CGFloat, pillH: CGFloat, sp: CGFloat, rowH: CGFloat
    static func pill(compact: Bool) -> PillDotsDims {
        compact ? .init(dotD: 2, pillW: 9, pillH: 2, sp: 2, rowH: 4)
                : .init(dotD: 3, pillW: 14, pillH: 5, sp: 3, rowH: 11)
    }
    func naturalWidth(spaceCount: Int) -> CGFloat {
        CGFloat(spaceCount) * dotD + max(0, CGFloat(spaceCount - 1)) * sp + (pillW - dotD)
    }
    func scaled(_ s: CGFloat) -> PillDotsDims {
        .init(dotD: dotD*s, pillW: pillW*s, pillH: pillH*s, sp: sp*s, rowH: rowH*s)
    }
}

struct PreviewSpaceIndicator: View {
    let stackMode: StackMode
    let spaceCount: Int
    let activeSpace: Int
    let screenCount: Int
    var scale: CGFloat = 1.0

    private var stacked: Bool {
        screenCount > 1
            && (stackMode == .stack || stackMode == .dynamic)
    }

    var body: some View {
        pillBody
    }

    @ViewBuilder
    private var pillBody: some View {
        let compact = stacked
        let dims = PillDotsDims.pill(compact: compact).scaled(scale)
        let rowCounts: [Int] = screenCount > 1 ? [spaceCount, max(1, spaceCount - 1)] : [spaceCount]

        if stacked {
            // Equal-length stacked rows — matches real renderer's rowStretch behavior.
            let widest = rowCounts.map { dims.naturalWidth(spaceCount: $0) }.max() ?? 0
            VStack(spacing: 1 * scale) {
                ForEach(0..<rowCounts.count, id: \.self) { i in
                    AnimatedPillDotsRow(
                        spaceCount: rowCounts[i],
                        activeSpace: i == 0 ? activeSpace : 1,
                        dims: dims,
                        dimmed: i != 0,
                        stretchToWidth: widest
                    )
                }
            }
        } else if rowCounts.count > 1 {
            // Inline multi-display: side-by-side rows with a separator capsule.
            HStack(spacing: 0) {
                ForEach(0..<rowCounts.count, id: \.self) { i in
                    if i > 0 {
                        Capsule()
                            .fill(Color.black.opacity(0.40))
                            .frame(width: 1.5 * scale, height: 8 * scale)
                            .padding(.horizontal, 8 * scale)
                    }
                    AnimatedPillDotsRow(
                        spaceCount: rowCounts[i],
                        activeSpace: i == 0 ? activeSpace : 1,
                        dims: dims,
                        dimmed: false
                    )
                }
            }
        } else {
            AnimatedPillDotsRow(
                spaceCount: spaceCount, activeSpace: activeSpace,
                dims: dims, dimmed: false
            )
        }
    }
}

// TimelineView-driven row that interpolates fractional active-pill position to match
// IndicatorRenderer's widthForSpace / heightForSpace / colorForSpace math.
struct AnimatedPillDotsRow: View {
    let spaceCount: Int
    let activeSpace: Int
    let dims: PillDotsDims
    let dimmed: Bool
    var stretchToWidth: CGFloat? = nil

    @State private var fromActive: Int = 1
    @State private var toActive: Int = 1
    @State private var transitionStart: Date = Date()

    private var renderWidth: CGFloat {
        max(dims.naturalWidth(spaceCount: spaceCount), stretchToWidth ?? 0)
    }
    private var rowStretch: CGFloat {
        max(0, (stretchToWidth ?? 0) - dims.naturalWidth(spaceCount: spaceCount))
    }

    var body: some View {
        TimelineView(.animation) { timeline in
            let frac = fractionalActive(at: timeline.date)
            Canvas { ctx, _ in draw(ctx: &ctx, frac: frac) }
                .frame(width: renderWidth, height: dims.rowH)
        }
        .onAppear { fromActive = activeSpace; toActive = activeSpace }
        .onChange(of: activeSpace) { newValue in
            let snapshot = fractionalActive(at: Date())
            fromActive = max(1, min(spaceCount, Int(round(snapshot))))
            toActive = newValue
            transitionStart = Date()
        }
    }

    private func fractionalActive(at date: Date) -> CGFloat {
        if fromActive == toActive { return CGFloat(toActive) }
        let elapsed = date.timeIntervalSince(transitionStart)
        let duration: Double = 0.5
        let raw = max(0, min(1, CGFloat(elapsed / duration)))
        let eased = applyEasing(raw)
        return CGFloat(fromActive) + CGFloat(toActive - fromActive) * eased
    }

    private func draw(ctx: inout GraphicsContext, frac: CGFloat) {
        let clamped = max(1.0, min(CGFloat(spaceCount), frac))
        let pL = floor(clamped), pH = ceil(clamped)
        let f = clamped - pL

        func widthFor(_ i: Int) -> CGFloat {
            let iF = CGFloat(i)
            if pL == pH { return iF == pL ? (dims.pillW + rowStretch) : dims.dotD }
            if iF == pL { return dims.dotD + (dims.pillW + rowStretch - dims.dotD) * (1 - f) }
            if iF == pH { return dims.dotD + (dims.pillW + rowStretch - dims.dotD) * f }
            return dims.dotD
        }
        func heightFor(_ i: Int) -> CGFloat {
            let iF = CGFloat(i)
            if pL == pH { return iF == pL ? dims.pillH : dims.dotD }
            if iF == pL { return dims.dotD + (dims.pillH - dims.dotD) * (1 - f) }
            if iF == pH { return dims.dotD + (dims.pillH - dims.dotD) * f }
            return dims.dotD
        }
        func colorFor(_ i: Int) -> Color {
            let iF = CGFloat(i)
            let alpha: CGFloat
            if pL == pH { alpha = iF == pL ? 1 : 0 }
            else if iF == pL { alpha = 1 - f }
            else if iF == pH { alpha = f }
            else { alpha = 0 }
            return blendBlack(weight: alpha, dimmed: dimmed)
        }

        var x: CGFloat = 0
        for i in 1...spaceCount {
            let w = widthFor(i)
            let h = heightFor(i)
            let y = (dims.rowH - h) / 2
            let rect = CGRect(x: x, y: y, width: w, height: h)
            ctx.fill(Path(roundedRect: rect, cornerSize: CGSize(width: h/2, height: h/2)),
                     with: .color(colorFor(i)))
            x += w
            if i < spaceCount { x += dims.sp }
        }
    }
}

// MARK: - Animation helpers (mirroring Indicator.swift + IndicatorRenderer.swift constants)

private func applyEasing(_ t: CGFloat) -> CGFloat {
    let c = max(0, min(1, t))
    return 1 - pow(1 - c, 4)  // Easing.outQuart
}

private func blendBlack(weight: CGFloat, dimmed: Bool) -> Color {
    let a = 0.40 + 0.45 * max(0, min(1, weight))
    return Color.black.opacity(a * (dimmed ? 0.55 : 1.0))
}

struct PreviewMusicPill: View {
    var body: some View {
        HStack(spacing: 3) {
            Text("Miss Summer — temp.")
                .font(.system(size: 8))
                .foregroundColor(Color.black.opacity(0.85))
            TimelineView(.animation) { timeline in
                let t = timeline.date.timeIntervalSinceReferenceDate
                HStack(spacing: 1) {
                    ForEach(0..<4) { i in
                        RoundedRectangle(cornerRadius: 0.75)
                            .fill(Color.black.opacity(0.6))
                            .frame(width: 1.5, height: barHeight(i, at: t))
                    }
                }
            }
        }
    }

    private func barHeight(_ i: Int, at t: TimeInterval) -> CGFloat {
        let offsets: [CGFloat] = [0, 0.4, 0.9, 1.3]
        let phase = t * 2 * .pi / 1.2
        let h = sin(phase + offsets[i]) * 0.5 + 0.5
        return 2 + h * 4
    }
}

