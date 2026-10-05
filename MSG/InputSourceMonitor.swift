import AppKit
import Carbon

// MARK: - InputSourceMonitor
//
// Watches the system keyboard input source (language/layout). TIS posts a
// distributed notification whenever the selected keyboard input source
// changes — from the Fn/globe key, ⌃Space, the Input menu, or automatic
// per-document switching. On each change the monitor re-reads the current
// source and fires `onChange` with a short display label derived from the
// source's language ("TH" / "ENG"); other languages fall back to the
// localized name the Input menu shows.

final class InputSourceMonitor: NSObject {

    /// Fired on the main thread with the new input source's localized name.
    var onChange: ((String) -> Void)?

    private var observing = false
    private var lastSourceID: String?
    private var retryWorkItem: DispatchWorkItem?

    func start() {
        guard !observing else { return }
        observing = true
        lastSourceID = currentSource()?.id
        // Delivered immediately: by default AppKit holds distributed
        // notifications while the app is inactive, and MSG never is active.
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(sourceChanged),
            name: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil, suspensionBehavior: .deliverImmediately)
    }

    @objc private func sourceChanged() {
        // Distributed notifications arrive on the main run loop already.
        DispatchQueue.main.async { [weak self] in self?.handleChange(allowRetry: true) }
    }

    func stop() {
        if observing { DistributedNotificationCenter.default().removeObserver(self) }
        observing = false
        retryWorkItem?.cancel(); retryWorkItem = nil
    }

    private func handleChange(allowRetry: Bool) {
        guard let source = currentSource() else { return }
        if source.id == lastSourceID {
            // The distributed notification can arrive before TIS reflects the
            // switch; re-read once shortly after instead of dropping the event.
            guard allowRetry else { return }
            retryWorkItem?.cancel()
            let item = DispatchWorkItem { [weak self] in self?.handleChange(allowRetry: false) }
            retryWorkItem = item
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: item)
            return
        }
        lastSourceID = source.id
        onChange?(source.name)
    }

    private func currentSource() -> (id: String, name: String)? {
        guard let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        func property(_ key: CFString) -> String? {
            guard let ptr = TISGetInputSourceProperty(source, key) else { return nil }
            return Unmanaged<CFString>.fromOpaque(ptr).takeUnretainedValue() as String
        }
        guard let id = property(kTISPropertyInputSourceID) else { return nil }

        // Primary language of the source (BCP-47, e.g. "th", "en", "en-GB").
        var language: String?
        if let ptr = TISGetInputSourceProperty(source, kTISPropertyInputSourceLanguages) {
            let langs = Unmanaged<CFArray>.fromOpaque(ptr).takeUnretainedValue() as? [String]
            language = langs?.first
        }

        let name: String
        if let language, language == "th" || language.hasPrefix("th-") {
            name = "TH"
        } else if let language, language == "en" || language.hasPrefix("en-") {
            name = "ENG"
        } else {
            name = property(kTISPropertyLocalizedName) ?? id
        }
        return (id, name)
    }
}
