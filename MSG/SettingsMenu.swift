import AppKit

final class SettingsMenu: NSObject, NSMenuDelegate {

    let menu = NSMenu()
    private let settings: AppSettings

    // Track visibility state
    private var externalSectionItems: [NSMenuItem] = []
    private var externalSepItem: NSMenuItem?
    private var focusDetectionItem: NSMenuItem?
    private var displayOrderItem: NSMenuItem?
    private var musicModePickerItem: NSMenuItem?
    private var lingerSlider: NSSlider?
    private var lingerLabel: NSTextField?
    private var extMirrorFadeItems: [NSMenuItem] = []
    private var extHeaderItems: [NSMenuItem] = []

    var onOpenSettings: (() -> Void)?

    init(settings: AppSettings) {
        self.settings = settings
        super.init()
        menu.delegate = self

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.updateExternalMonitorVisibility() }
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        externalSectionItems.removeAll(); externalSepItem = nil
        extMirrorFadeItems.removeAll()
        extToggleItems.removeAll()
        extHeaderItems.removeAll()
        focusDetectionItem = nil; displayOrderItem = nil

        // Follow the System Settings appearance, not the menu bar's.
        //
        // A menu popped from a status item inherits the *menu bar's* appearance,
        // and macOS turns that vibrantLight over a light wallpaper even while the
        // system is in Dark mode — so the menu came up light on a dark system.
        // Pinning it to NSApp's effective appearance (which tracks the Appearance
        // setting) keeps it in step with the rest of the app. Re-read on every
        // open so toggling Light/Dark is picked up without a relaunch.
        let systemIsDark = NSApp.effectiveAppearance
            .bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        menu.appearance = NSAppearance(named: systemIsDark ? .darkAqua : .aqua)

        menu.autoenablesItems = false

        // ── Spacer ──────────────────
        addHeaderItem("Spacer", to: menu)

        addSpaceItem()

        let stackMenu = NSMenu()
        for mode in StackMode.allCases {
            let item = NSMenuItem(title: mode.rawValue, action: #selector(selStack(_:)), keyEquivalent: "")
            item.representedObject = mode
            item.target = self
            item.state = (mode == settings.stackMode) ? .on : .off
            stackMenu.addItem(item)
        }
        let stackItem = NSMenuItem(title: "  Stack Mode", action: nil, keyEquivalent: "")
        stackItem.submenu = stackMenu
        menu.addItem(stackItem)

        let animMenu = NSMenu()
        for style in AnimationStyle.allCases {
            let item = NSMenuItem(title: style.rawValue, action: #selector(selAnim(_:)), keyEquivalent: "")
            item.representedObject = style
            item.target = self
            item.state = (style == settings.animationStyle) ? .on : .off
            animMenu.addItem(item)
        }
        let animItem = NSMenuItem(title: "  Animation", action: nil, keyEquivalent: "")
        animItem.submenu = animMenu
        menu.addItem(animItem)

        let detectionMenu = NSMenu()
        for mode in FocusDetectionMode.allCases {
            let item = NSMenuItem(title: mode.rawValue, action: #selector(selDetection(_:)), keyEquivalent: "")
            item.representedObject = mode
            item.target = self
            item.state = (mode == settings.focusDetectionMode) ? .on : .off
            detectionMenu.addItem(item)
        }
        let detectionItem = NSMenuItem(title: "  Focus Detection", action: nil, keyEquivalent: "")
        detectionItem.submenu = detectionMenu
        menu.addItem(detectionItem)
        focusDetectionItem = detectionItem

        let orderMenu = NSMenu()
        for mode in DisplayOrderMode.allCases {
            let item = NSMenuItem(title: mode.rawValue, action: #selector(selOrder(_:)), keyEquivalent: "")
            item.representedObject = mode
            item.target = self
            item.state = (mode == settings.displayOrderMode) ? .on : .off
            orderMenu.addItem(item)
        }
        let orderItem = NSMenuItem(title: "  Display Order", action: nil, keyEquivalent: "")
        orderItem.submenu = orderMenu
        menu.addItem(orderItem)
        displayOrderItem = orderItem

        addSpaceItem()

        // ── Music Display ──────────
        menu.addItem(.separator())
        addSpaceItem()
        addHeaderItem("Music Display", to: menu)

        let sourcePickerItem = NSMenuItem(title: "  Source", action: nil, keyEquivalent: "")
        let sourcePickerMenu = NSMenu()
        for src in MusicSource.allCases {
            let m = NSMenuItem(title: "  \(src.displayLabel)", action: #selector(musicSourcePicked(_:)), keyEquivalent: "")
            m.target = self
            m.state = settings.musicSource == src ? .on : .off
            m.tag = MusicSource.allCases.firstIndex(of: src) ?? 0
            m.isEnabled = src.isAvailable
            sourcePickerMenu.addItem(m)
        }
        sourcePickerItem.submenu = sourcePickerMenu
        menu.addItem(sourcePickerItem)

        let musicPickerItem = NSMenuItem(title: "  Mode", action: nil, keyEquivalent: "")
        let musicPickerMenu = NSMenu()
        for mode in MusicDisplayMode.allCases {
            let m = NSMenuItem(title: "  \(mode.rawValue)", action: #selector(musicModePicked(_:)), keyEquivalent: "")
            m.target = self
            m.state = settings.musicDisplayMode == mode ? .on : .off
            m.tag = MusicDisplayMode.allCases.firstIndex(of: mode) ?? 0
            musicPickerMenu.addItem(m)
        }
        musicPickerItem.submenu = musicPickerMenu
        menu.addItem(musicPickerItem)
        musicModePickerItem = musicPickerItem

        addSpaceItem()

        menu.addItem(.separator())

        // ── Cornermizer ──────────
        addHeaderItem("Cornermizer", to: menu)

        let model = MacModel.name
        let builtIn = NSScreen.screens.first
        let externals = builtIn != nil ? NSScreen.screens.filter { $0 != builtIn } : []

        addSpaceItem()
        addHeaderItem("\(model) Display", to: menu, indent: true)

        // Mirror toggle at top of built-in, only when external connected
        if !externals.isEmpty {
            addToggleItem("Apply to all display", state: settings.mirrorMainDisplay, action: #selector(mirrorToggle(_:)))
            mirrorToggleItem = menu.items.last
        }

        let topPosMenu = createPositionMenu(isExternal: false)
        addToggleItem("Top Corners", state: settings.topCornersEnabled, action: #selector(topToggle(_:)), submenu: topPosMenu)

        addToggleItem("Bottom Corners", state: settings.bottomCornersEnabled, action: #selector(bottomToggle(_:)))

        addSpaceItem()

        // ── External Monitors ───────
        externalSectionItems.removeAll()

        if !externals.isEmpty {
            let mirroring = settings.mirrorMainDisplay
            for ext in externals {
                guard let uuid = ext.uuid else { continue }
                let name = ext.localizedName
                addHeaderItem(name, to: menu, indent: true)
                extHeaderItems.append(menu.items.last!)

                let extTopPosMenu = createExtPositionMenu(uuid: uuid)
                addToggleItem("Top Corners", state: settings.extTopCornersEnabled(for: uuid),
                              action: #selector(extTopToggleUUID(_:)), submenu: extTopPosMenu, uuid: uuid, initiallyHidden: mirroring)
                extToggleItems.append(menu.items.last!)
                extMirrorFadeItems.append(menu.items.last!)
                externalSectionItems.append(menu.items.last!)

                addToggleItem("Bottom Corners", state: settings.extBottomCornersEnabled(for: uuid),
                              action: #selector(extBottomToggleUUID(_:)), uuid: uuid, initiallyHidden: mirroring)
                extToggleItems.append(menu.items.last!)
                extMirrorFadeItems.append(menu.items.last!)
                externalSectionItems.append(menu.items.last!)
            }
        }

        externalSepItem = NSMenuItem.separator()
        menu.addItem(externalSepItem!)
        externalSectionItems.append(externalSepItem!)

        updateExternalMonitorVisibility(animated: false)
        updateAllVisibilities(animated: false)

        // ── Displaplacer ────────────
        addDisplaplacerSection()

        // ── Monitor Input ───────────
        addMonitorInputSection()

        // ── Quit ────────────────────
        menu.addItem(.separator())
        addRefreshDisplayItem()
        let openItem = NSMenuItem(title: "Open Settings…", action: #selector(openSettingsAction), keyEquivalent: "s")
        openItem.target = self
        menu.addItem(openItem)
        let quit = NSMenuItem(title: "No added MSG", action: #selector(quitApp), keyEquivalent: "q")
        let attrTitle = NSMutableAttributedString(string: "No added MSG")
        attrTitle.addAttribute(.font, value: NSFont.menuFont(ofSize: 0), range: NSRange(location: 0, length: 9))
        attrTitle.addAttribute(.font, value: NSFont.monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular), range: NSRange(location: 9, length: 3))
        quit.attributedTitle = attrTitle
        quit.target = self
        menu.addItem(quit)

        updateAllVisibilities(animated: false)
    }

    // MARK: - Visibility

    private func updateAllVisibilities(animated: Bool = true) {
        updateExtTogglesVisibility(animated: animated)
    }

    func updateExternalMonitorVisibility(animated: Bool = true) {
        let hasExternals = NSScreen.screens.count > 1
        let mirroring = settings.mirrorMainDisplay
        for item in externalSectionItems {
            let hiddenByMirror = mirroring && extMirrorFadeItems.contains(where: { $0 === item })
            animateItemVisibility(item, visible: hasExternals && !hiddenByMirror, animated: animated)
        }
        for item in extHeaderItems {
            // Hide per-monitor name headers when mirroring — their corner toggles
            // are hidden too, so the section collapses to just "Apply to all display".
            animateItemVisibility(item, visible: hasExternals && !mirroring, animated: animated)
        }
        focusDetectionItem?.isHidden = !hasExternals
        displayOrderItem?.isHidden = !hasExternals
    }

    // MARK: - Helpers

    private func addSpaceItem() {
        let item = NSMenuItem()
        let v = NSView(frame: NSRect(x: 0, y: 0, width: 250, height: 8))
        item.view = v
        menu.addItem(item)
    }

    private func addHeaderItem(_ title: String, to targetMenu: NSMenu, indent: Bool = false) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 250, height: 20))
        let attr = NSAttributedString(string: indent ? "  \(title.uppercased())" : title.uppercased(), attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .bold),
            .foregroundColor: NSColor.secondaryLabelColor
        ])
        let label = NSTextField(labelWithAttributedString: attr)
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: indent ? 20 : 14)
        ])
        item.view = container
        item.isEnabled = false
        targetMenu.addItem(item)
    }

    private func createPositionMenu(isExternal: Bool) -> NSMenu {
        let underBar = isExternal ? settings.extTopCornersUnderMenuBar : settings.topCornersUnderMenuBar
        let sub = NSMenu()
        let atEdge = NSMenuItem(title: "At Screen Edge", action: isExternal ? #selector(extPosEdge) : #selector(posEdge), keyEquivalent: "")
        atEdge.target = self; atEdge.state = underBar ? .off : .on; sub.addItem(atEdge)
        let belowBar = NSMenuItem(title: "Below Menu Bar", action: isExternal ? #selector(extPosBelow) : #selector(posBelow), keyEquivalent: "")
        belowBar.target = self; belowBar.state = underBar ? .on : .off; sub.addItem(belowBar)
        sub.addItem(.separator())
        let fsOnly = NSMenuItem(title: "Fullscreen Only",
                                action: isExternal ? #selector(extFullscreenOnlyToggle) : #selector(fullscreenOnlyToggle),
                                keyEquivalent: "")
        fsOnly.target = self
        fsOnly.state = (isExternal ? settings.extTopCornersFullscreenOnly : settings.topCornersFullscreenOnly) ? .on : .off
        sub.addItem(fsOnly)
        return sub
    }

    private func addToggleItem(_ title: String, state: Bool, action: Selector, submenu: NSMenu? = nil, uuid: String? = nil, initiallyHidden: Bool = false) {
        let item = NSMenuItem()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 250, height: 24))
        container.wantsLayer = true
        if let uuid { container.identifier = NSUserInterfaceItemIdentifier("toggle_\(uuid)") }
        if initiallyHidden { container.isHidden = true; container.alphaValue = 0; item.isHidden = true }
        let button = NSButton(checkboxWithTitle: title, target: self, action: action)
        button.state = state ? .on : .off
        button.font = .menuFont(ofSize: 0)
        button.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(button)
        NSLayoutConstraint.activate([
            button.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            button.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 28),
            button.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14)
        ])
        item.view = container
        item.submenu = submenu
        menu.addItem(item)
    }

    private func createExtPositionMenu(uuid: String) -> NSMenu {
        let underBar = settings.extTopCornersUnderMenuBar(for: uuid)
        let sub = NSMenu()
        let atEdge = NSMenuItem(title: "At Screen Edge", action: #selector(extPosEdgeUUID(_:)), keyEquivalent: "")
        atEdge.target = self; atEdge.representedObject = uuid; atEdge.state = underBar ? .off : .on
        sub.addItem(atEdge)
        let belowBar = NSMenuItem(title: "Below Menu Bar", action: #selector(extPosBelowUUID(_:)), keyEquivalent: "")
        belowBar.target = self; belowBar.representedObject = uuid; belowBar.state = underBar ? .on : .off
        sub.addItem(belowBar)
        sub.addItem(.separator())
        let fsOnly = NSMenuItem(title: "Fullscreen Only", action: #selector(extFullscreenOnlyToggleUUID(_:)), keyEquivalent: "")
        fsOnly.target = self; fsOnly.representedObject = uuid
        fsOnly.state = settings.extTopCornersFullscreenOnly(for: uuid) ? .on : .off
        sub.addItem(fsOnly)
        return sub
    }

    @objc private func extTopToggleUUID(_ sender: NSButton) {
        guard let raw = sender.superview?.identifier?.rawValue,
              raw.hasPrefix("toggle_") else { return }
        let uuid = String(raw.dropFirst(7))
        settings.setExtTopCornersEnabled(sender.state == .on, for: uuid)
    }
    @objc private func extBottomToggleUUID(_ sender: NSButton) {
        guard let raw = sender.superview?.identifier?.rawValue,
              raw.hasPrefix("toggle_") else { return }
        let uuid = String(raw.dropFirst(7))
        settings.setExtBottomCornersEnabled(sender.state == .on, for: uuid)
    }

    @objc private func extPosEdgeUUID(_ sender: NSMenuItem) {
        guard let uuid = sender.representedObject as? String else { return }
        settings.setExtTopCornersUnderMenuBar(false, for: uuid)
    }
    @objc private func extPosBelowUUID(_ sender: NSMenuItem) {
        guard let uuid = sender.representedObject as? String else { return }
        settings.setExtTopCornersUnderMenuBar(true, for: uuid)
    }
    @objc private func extFullscreenOnlyToggleUUID(_ sender: NSMenuItem) {
        guard let uuid = sender.representedObject as? String else { return }
        settings.setExtTopCornersFullscreenOnly(!settings.extTopCornersFullscreenOnly(for: uuid), for: uuid)
    }

    // MARK: - Visibility helpers

    private var extToggleItems: [NSMenuItem] = []

    private func updateExtTogglesVisibility(animated: Bool = true) {
        let visible = NSScreen.screens.count > 1 && !settings.mirrorMainDisplay
        for item in extToggleItems {
            animateItemVisibility(item, visible: visible, animated: animated)
        }
    }

    private func animateItemVisibility(_ item: NSMenuItem?, visible: Bool, animated: Bool = false) {
        guard let item = item, let view = item.view else { return }
        view.wantsLayer = true
        if visible {
            if item.isHidden { view.isHidden = false; view.alphaValue = 0; item.isHidden = false
                if animated {
                    DispatchQueue.main.async { NSAnimationContext.runAnimationGroup { ctx in ctx.duration = 0.25; view.animator().alphaValue = 1 } }
                } else { view.alphaValue = 1 }
            }
        } else {
            if !item.isHidden {
                if animated {
                    NSAnimationContext.runAnimationGroup({ ctx in ctx.duration = 0.2; view.animator().alphaValue = 0 }, completionHandler: { item.isHidden = true; view.isHidden = true })
                } else { view.alphaValue = 0; item.isHidden = true; view.isHidden = true }
            }
        }
    }

    // MARK: - Actions

    @objc private func openSettingsAction() { onOpenSettings?() }

    @objc func selStack(_ sender: NSMenuItem) {
        if let s = sender.representedObject as? StackMode { settings.stackMode = s }
    }
    @objc func selAnim(_ sender: NSMenuItem) {
        if let s = sender.representedObject as? AnimationStyle { settings.animationStyle = s }
    }
    @objc func selDetection(_ sender: NSMenuItem) {
        if let s = sender.representedObject as? FocusDetectionMode { settings.focusDetectionMode = s }
    }
    @objc func selOrder(_ sender: NSMenuItem) {
        if let s = sender.representedObject as? DisplayOrderMode { settings.displayOrderMode = s }
    }

    @objc func topToggle(_ sender: NSButton)     { settings.topCornersEnabled = (sender.state == .on) }
    @objc func bottomToggle(_ sender: NSButton)  { settings.bottomCornersEnabled = (sender.state == .on) }
    @objc func extTopToggle(_ sender: NSButton)  { settings.extTopCornersEnabled = (sender.state == .on) }
    @objc func extBottomToggle(_ sender: NSButton) { settings.extBottomCornersEnabled = (sender.state == .on) }
    private var mirrorToggleItem: NSMenuItem?

    @objc func mirrorToggle(_ sender: NSButton)  {
        settings.mirrorMainDisplay = (sender.state == .on)
        let mirroring = sender.state == .on
        updateExtTogglesVisibility(animated: true)
        for item in extHeaderItems {
            animateItemVisibility(item, visible: !mirroring, animated: true)
        }
        for item in externalSectionItems where item != mirrorToggleItem && !extHeaderItems.contains(item) {
            let isToggle = extToggleItems.contains(item)
            if !isToggle {
                animateItemVisibility(item, visible: !mirroring, animated: true)
            }
        }
        for item in extMirrorFadeItems where item != mirrorToggleItem {
            let isToggle = extToggleItems.contains(item)
            if !isToggle {
                animateItemVisibility(item, visible: !mirroring, animated: true)
            }
        }
    }
    @objc func posEdge()                         { settings.topCornersUnderMenuBar = false }
    @objc func posBelow()                        { settings.topCornersUnderMenuBar = true }
    @objc func extPosEdge()                      { settings.extTopCornersUnderMenuBar = false }
    @objc func extPosBelow()                     { settings.extTopCornersUnderMenuBar = true }
    @objc func fullscreenOnlyToggle()            { settings.topCornersFullscreenOnly.toggle() }
    @objc func extFullscreenOnlyToggle()         { settings.extTopCornersFullscreenOnly.toggle() }
    @objc func musicModePicked(_ sender: NSMenuItem) {
        let modes = MusicDisplayMode.allCases
        guard sender.tag >= 0, sender.tag < modes.count else { return }
        settings.musicDisplayMode = modes[sender.tag]
    }
    @objc func musicSourcePicked(_ sender: NSMenuItem) {
        let sources = MusicSource.allCases
        guard sender.tag >= 0, sender.tag < sources.count else { return }
        settings.musicSource = sources[sender.tag]
    }
    @objc func musicLingerChanged(_ sender: NSSlider) {
        let v = TimeInterval(sender.doubleValue)
        settings.musicLingerDuration = v
        lingerLabel?.attributedStringValue = lingerLabelText(Int(v))
    }
    private func lingerLabelText(_ v: Int) -> NSAttributedString {
        .init(string: "Linger after pause \(v)s",
              attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                           .foregroundColor: NSColor.secondaryLabelColor])
    }
    @objc func quitApp() { (NSApp.delegate as? AppDelegate)?.requestQuit() }

    // MARK: - Displaplacer

    private func addDisplaplacerSection() {
        guard settings.displaplacerEnabled else { return }
        let externals = DisplaplacerEngine.externalDisplays()
        // No external monitor → hide the whole section (separator, header, presets, toggles).
        guard !externals.isEmpty else { return }

        menu.addItem(.separator())
        addHeaderItem("Displaplacer", to: menu)

        addSpaceItem()
        addHeaderItem("Presets", to: menu, indent: true)
        let presets = settings.displaplacerPresets
        if presets.isEmpty {
            let empty = NSMenuItem(title: "  No presets saved", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            empty.indentationLevel = 1
            menu.addItem(empty)
        } else {
            let currentLayout = DisplaplacerEngine.captureCurrentLayout()
            for preset in presets {
                let item = NSMenuItem(title: "  \(preset.name)", action: #selector(applyPreset(_:)), keyEquivalent: "")
                item.representedObject = preset.id.uuidString
                item.target = self
                item.indentationLevel = 1
                let isActive = preset.layouts.count == currentLayout.count && preset.layouts.allSatisfy { layout in
                    currentLayout.contains(layout)
                }
                item.state = isActive ? .on : .off
                menu.addItem(item)
            }
        }

        addSpaceItem()
        addHeaderItem("Connected Monitors", to: menu, indent: true)
        // Count ALL active displays (incl. built-in) so the last external can
        // still be ejected while the built-in remains.
        let totalActive = DisplaplacerEngine.allOnlineDisplays().filter { $0.enabled }.count
        let builtIn = NSScreen.screens.first
        for display in externals {
            // Show the monitor's arrangement position (e.g. "Right") for connected
            // displays; ejected ones have no NSScreen so they show just the name.
            var title = "  \(display.name)"
            if display.enabled, let builtIn = builtIn,
               let screen = NSScreen.screens.first(where: { $0.uuid == display.uuid }) {
                title += " (\(displayPosition(for: screen, relativeTo: builtIn)))"
            }
            let item = NSMenuItem(title: title, action: #selector(toggleDisplay(_:)), keyEquivalent: "")
            item.representedObject = display.uuid
            item.target = self
            item.state = display.enabled ? .on : .off
            item.isEnabled = display.enabled ? totalActive > 1 : true
            item.indentationLevel = 1
            menu.addItem(item)
        }

        addSpaceItem()
    }

    /// DDC/CI input switching. Reads only the engine's cache — a live scan is a
    /// dozen 60 ms I2C round trips per panel and would stall the menu opening.
    /// The cache is filled at launch and on every screen-parameter change.
    private func addMonitorInputSection() {
        let monitors = DisplayInputEngine.monitors.filter { !$0.inputs.isEmpty }
        guard !monitors.isEmpty else { return }

        menu.addItem(.separator())
        addHeaderItem("Monitor Input", to: menu)
        addSpaceItem()

        for monitor in monitors {
            // One monitor: hang the inputs straight off the section rather than
            // making the user open a submenu to reach two items.
            let target: NSMenu
            if monitors.count == 1 {
                target = menu
            } else {
                let parent = NSMenuItem(title: "  \(monitor.name)", action: nil, keyEquivalent: "")
                let sub = NSMenu()
                parent.submenu = sub
                menu.addItem(parent)
                target = sub
            }

            let indent = monitors.count == 1 ? 1 : 0

            // Unreachable means the panel is showing another machine: its DDC bus
            // is silent, so no input row would do anything. Say so, and offer the
            // one action that still works — reconnecting the display costs no DDC.
            guard monitor.reachable else {
                let note = NSMenuItem(title: "  Showing another device", action: nil, keyEquivalent: "")
                note.isEnabled = false
                note.indentationLevel = indent
                target.addItem(note)

                let hint = NSMenuItem(title: "  Press the monitor's input button to return",
                                      action: nil, keyEquivalent: "")
                hint.isEnabled = false
                hint.indentationLevel = indent
                target.addItem(hint)

                if DisplayInputEngine.isHandoverEjected(monitorKey: monitor.key) {
                    let fix = NSMenuItem(title: "  Reconnect Display",
                                         action: #selector(monitorInputReconnect(_:)), keyEquivalent: "")
                    fix.target = self
                    fix.indentationLevel = indent
                    fix.representedObject = MonitorInputChoice(monitorKey: monitor.key, code: 0)
                    target.addItem(fix)
                }
                continue
            }

            for input in monitor.inputs {
                // Mark the Mac's own input so it reads as "come back here", not
                // as another handover target.
                let title = input.isMac ? "  \(input.label) (this Mac)" : "  \(input.label)"
                let item = NSMenuItem(title: title,
                                      action: #selector(monitorInputPicked(_:)), keyEquivalent: "")
                item.target = self
                item.indentationLevel = indent
                item.representedObject = MonitorInputChoice(monitorKey: monitor.key, code: input.code)
                // Most panels never report their live input (the MSI MP341CQ
                // answers 0xFF forever), so currentCode is usually nil and no
                // row gets a checkmark. That is correct — a wrong checkmark is
                // worse than none.
                item.state = (monitor.currentCode == input.code) ? .on : .off
                target.addItem(item)
            }
        }

        addSpaceItem()
    }

    /// Boxed so it can ride in `representedObject`.
    private final class MonitorInputChoice: NSObject {
        let monitorKey: String
        let code: UInt16
        init(monitorKey: String, code: UInt16) {
            self.monitorKey = monitorKey
            self.code = code
        }
    }

    @objc private func monitorInputPicked(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? MonitorInputChoice else { return }
        DisplayInputEngine.selectInput(monitorKey: choice.monitorKey,
                                       code: choice.code,
                                       autoEject: settings.monitorInputAutoEject)
    }

    @objc private func monitorInputReconnect(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? MonitorInputChoice else { return }
        DisplayInputEngine.reconnectDisplay(monitorKey: choice.monitorKey)
    }

    // A monitor that is enumerated and active but showing no picture looks identical
    // to a working one from software, so there is nothing to detect and auto-repair —
    // this re-triggers the link the way pulling the cable does. It lives in the bottom
    // section rather than under Displaplacer, and is deliberately not gated on
    // `displaplacerEnabled`: it's a rescue action, and the state it rescues you from
    // is exactly the one where you'd rather not go hunting through settings.
    private func addRefreshDisplayItem() {
        let online = DisplaplacerEngine.allOnlineDisplays()
        let hasActiveExternal = online.contains { !$0.isBuiltin && $0.enabled }
        guard hasActiveExternal, online.filter({ $0.enabled }).count > 1 else { return }

        let fix = NSMenuItem(title: "Refresh Display",
                             action: #selector(relinkDisplays), keyEquivalent: "")
        fix.target = self
        menu.addItem(fix)
    }

    @objc private func relinkDisplays() {
        DisplaplacerEngine.relinkAllExternals()
    }

    @objc private func applyPreset(_ sender: NSMenuItem) {
        guard let idString = sender.representedObject as? String,
              let uuid = UUID(uuidString: idString),
              let preset = settings.displaplacerPresets.first(where: { $0.id == uuid }) else { return }
        DisplaplacerEngine.apply(preset)
    }

    @objc private func toggleDisplay(_ sender: NSMenuItem) {
        guard let uuid = sender.representedObject as? String else { return }
        let isEnabled = sender.state == .on
        DisplaplacerEngine.setEnabled(uuid, enabled: !isEnabled)
    }

}
