import AppKit

// PRODUCTION_APPLE_MUSIC_SNAPSHOT

@main struct AppleMusicSnapshotTests {
    static func descriptor(state: String, title: String = "วันที่ฟ้าเป็นใจ | Live", duration: Double = 240) -> NSAppleEventDescriptor {
        let list = NSAppleEventDescriptor.list()
        let fields = [NSAppleEventDescriptor(string: state), NSAppleEventDescriptor(string: title),
                      NSAppleEventDescriptor(string: "Penguin Villa"), NSAppleEventDescriptor(int32: 45),
                      NSAppleEventDescriptor(double: 120), NSAppleEventDescriptor(double: duration)]
        for (index, field) in fields.enumerated() { list.insert(field, at: index + 1) }
        return list
    }
    static func main() {
        let paused = AppleMusicSnapshot(descriptor: descriptor(state: "paused"))!
        precondition(!paused.isPlaying && paused.title == "วันที่ฟ้าเป็นใจ | Live")
        precondition(paused.artist == "Penguin Villa" && paused.elapsed == 120 && paused.duration == 240)
        let playing = AppleMusicSnapshot(descriptor: descriptor(state: "playing"))!
        precondition(playing.isPlaying && playing.title == paused.title)
        let stopped = AppleMusicSnapshot(descriptor: descriptor(state: "stopped"))!
        precondition(!stopped.isPlaying && stopped.title == nil && stopped.artist == nil && stopped.duration == nil)
        let unknownDuration = AppleMusicSnapshot(descriptor: descriptor(state: "paused", duration: 0))!
        precondition(unknownDuration.title == paused.title && unknownDuration.duration == nil)
        precondition(AppleMusicSnapshot(descriptor: .list()) == nil)
        precondition(AppleMusicSnapshot(descriptor: descriptor(state: "invalid")) == nil)
        print("Paused Music metadata, separator-safe titles and stopped-state clearing passed")
    }
}
