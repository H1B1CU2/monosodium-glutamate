import AppKit

final class SettingsMenu: NSObject, NSMenuDelegate {

    let menu = NSMenu()
    private let settings: Settings

    // Track visibility state
    private var externalSectionItems: [NSMenuItem] = []
    private var externalSepItem: NSMenuItem?
    private var focusDetectionItem: NSMenuItem?
    private var displayOrderItem: NSMenuItem?
    private var sliderItem: NSMenuItem?
    private var extSliderItem: NSMenuItem?
    private var extTopToggleItem: NSMenuItem?
    private var extBottomToggleItem: NSMenuItem?
    private var extMirrorFadeItems: [NSMenuItem] = []

    init(settings: Settings) {
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
        focusDetectionItem = nil; displayOrderItem = nil

        menu.autoenablesItems = false

        // ── Spacer ──────────────────
        addHeaderItem("Spacer", to: menu)

        addSpaceItem()

        let styleMenu = NSMenu()
        for style in DisplayStyle.allCases {
            let item = NSMenuItem(title: style.rawValue, action: #selector(selectStyle(_:)), keyEquivalent: "")
            item.representedObject = style
            item.target = self
            item.state = (style == settings.displayStyle) ? .on : .off
            if style == .pill && NSScreen.screens.count > 1 && settings.displayStyle == .pill {
                let stackSub = NSMenu()
                for mode in StackMode.allCases {
                    let sItem = NSMenuItem(title: mode.rawValue, action: #selector(selStack(_:)), keyEquivalent: "")
                    sItem.representedObject = mode
                    sItem.target = self
                    sItem.state = (mode == settings.stackMode) ? .on : .off
                    stackSub.addItem(sItem)
                }
                item.submenu = stackSub
            }
            styleMenu.addItem(item)
        }
        let styleItem = NSMenuItem(title: "  Indicator Style", action: nil, keyEquivalent: "")
        styleItem.submenu = styleMenu
        menu.addItem(styleItem)

        let animMenu = NSMenu()
        let hideJelly = settings.displayStyle == .numbers || settings.displayStyle == .boldNumber || settings.displayStyle == .dots
        for style in AnimationStyle.allCases {
            guard !(hideJelly && style == .jelly) else { continue }
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

        menu.addItem(.separator())

        // ── Cornermization ──────────
        addHeaderItem("Cornermization", to: menu)

        let model = modelName()
        addSpaceItem()
        addHeaderItem(model, to: menu, indent: true)

        let topPosMenu = createPositionMenu(isExternal: false)
        addToggleItem("Top Corners", state: settings.topCornersEnabled, action: #selector(topToggle(_:)), submenu: topPosMenu)

        addToggleItem("Bottom Corners", state: settings.bottomCornersEnabled, action: #selector(bottomToggle(_:)))

        addSliderItem(value: settings.cornerRadius, isExternal: false)

        addSpaceItem()

        // ── External Monitors ───────
        externalSectionItems.removeAll()

        let builtIn = NSScreen.screens.first
        let externals = builtIn != nil ? NSScreen.screens.filter { $0 != builtIn } : []

        if !externals.isEmpty {
            for ext in externals {
                guard let uuid = screenUUID(ext) else { continue }
                let name = ext.localizedName
                let pos = builtIn.map { displayPosition(for: ext, relativeTo: $0) } ?? ""
                addHeaderItem("\(name) (\(pos))", to: menu, indent: true)
                externalSectionItems.append(menu.items.last!)

                let extTopPosMenu = createExtPositionMenu(uuid: uuid)
                addToggleItem("Top Corners", state: settings.extTopCornersEnabled(for: uuid),
                              action: #selector(extTopToggleUUID(_:)), submenu: extTopPosMenu, isExtTop: true, uuid: uuid)
                extMirrorFadeItems.append(menu.items.last!)
                externalSectionItems.append(menu.items.last!)

                addToggleItem("Bottom Corners", state: settings.extBottomCornersEnabled(for: uuid),
                              action: #selector(extBottomToggleUUID(_:)), isExtBottom: true, uuid: uuid)
                extMirrorFadeItems.append(menu.items.last!)
                externalSectionItems.append(menu.items.last!)

                addExtSliderItem(value: settings.extCornerRadius(for: uuid), uuid: uuid)
                extMirrorFadeItems.append(menu.items.last!)
                externalSectionItems.append(menu.items.last!)

                addSpaceItem()
            }

            addToggleItem("Mirror \(model) settings", state: settings.mirrorMainDisplay, action: #selector(mirrorToggle(_:)))
            mirrorToggleItem = menu.items.last
        }

        externalSepItem = NSMenuItem.separator()
        menu.addItem(externalSepItem!)
        externalSectionItems.append(externalSepItem!)

        updateExternalMonitorVisibility(animated: false)

        // ── Quit ────────────────────
        menu.addItem(.separator())
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
        updateSliderVisibility(animated: animated)
        updateExtSliderVisibility(animated: animated)
        updateExtTogglesVisibility(animated: animated)
    }

    func updateExternalMonitorVisibility(animated: Bool = true) {
        let visible = NSScreen.screens.count > 1
        for item in externalSectionItems {
            animateItemVisibility(item, visible: visible, animated: animated)
        }
        focusDetectionItem?.isHidden = !visible
        displayOrderItem?.isHidden = !visible
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

    private func addSliderItem(value: CGFloat, isExternal: Bool) {
        let item = NSMenuItem()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 250, height: 58))
        container.wantsLayer = true
        let slider = NSSlider(value: Double(value), minValue: 1, maxValue: 30,
                              target: self, action: isExternal ? #selector(extRadiusChanged(_:)) : #selector(radiusChanged(_:)))
        slider.controlSize = .mini
        slider.numberOfTickMarks = 15
        slider.tickMarkPosition = .below
        slider.allowsTickMarkValuesOnly = false
        slider.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(slider)

        let title = NSTextField(labelWithAttributedString: sliderLabelText(value: Int(value)))
        title.alignment = .right
        title.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(title)

        NSLayoutConstraint.activate([
            slider.topAnchor.constraint(equalTo: container.topAnchor, constant: 22),
            slider.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 28),
            slider.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            title.bottomAnchor.constraint(equalTo: slider.topAnchor, constant: -2),
            title.trailingAnchor.constraint(equalTo: slider.trailingAnchor)
        ])
        item.view = container
        menu.addItem(item)
        if isExternal { extSliderItem = item } else { sliderItem = item }
    }

    private func createPositionMenu(isExternal: Bool) -> NSMenu {
        let underBar = isExternal ? settings.extTopCornersUnderMenuBar : settings.topCornersUnderMenuBar
        let sub = NSMenu()
        let atEdge = NSMenuItem(title: "At Screen Edge", action: isExternal ? #selector(extPosEdge) : #selector(posEdge), keyEquivalent: "")
        atEdge.target = self; atEdge.state = underBar ? .off : .on; sub.addItem(atEdge)
        let belowBar = NSMenuItem(title: "Below Menu Bar", action: isExternal ? #selector(extPosBelow) : #selector(posBelow), keyEquivalent: "")
        belowBar.target = self; belowBar.state = underBar ? .on : .off; sub.addItem(belowBar)
        return sub
    }

    private func addToggleItem(_ title: String, state: Bool, action: Selector, submenu: NSMenu? = nil, isExtTop: Bool = false, isExtBottom: Bool = false, uuid: String? = nil) {
        let item = NSMenuItem()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 250, height: 24))
        container.wantsLayer = true
        if let uuid { container.identifier = NSUserInterfaceItemIdentifier(uuid) }
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
        if isExtTop { extTopToggleItem = item }
        if isExtBottom { extBottomToggleItem = item }
    }

    private func modelName() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &model, &size, nil, 0)
        let id = String(cString: model)
        if id.contains("MacBookAir")  { return "MacBook Air" }
        if id.contains("MacBookPro")  { return "MacBook Pro" }
        if id.contains("Macmini")     { return "Mac mini" }
        if id.contains("iMac")        { return "iMac" }
        if id.contains("MacStudio")   { return "Mac Studio" }
        if id.contains("MacPro")      { return "Mac Pro" }
        return "Built-in Display"
    }

    private func screenUUID(_ screen: NSScreen) -> String? {
        guard let dID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID,
              let u = CGDisplayCreateUUIDFromDisplayID(dID),
              let s = CFUUIDCreateString(nil, u.takeRetainedValue()) as String? else { return nil }
        return s
    }

    private func addExtSliderItem(value: CGFloat, uuid: String) {
        let item = NSMenuItem()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 250, height: 58))
        container.wantsLayer = true
        container.identifier = NSUserInterfaceItemIdentifier(uuid)
        let slider = NSSlider(value: Double(value), minValue: 1, maxValue: 30,
                              target: self, action: #selector(extRadiusChangedUUID(_:)))
        slider.controlSize = .mini
        slider.numberOfTickMarks = 15
        slider.tickMarkPosition = .below
        slider.allowsTickMarkValuesOnly = false
        slider.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(slider)

        let title = NSTextField(labelWithAttributedString: sliderLabelText(value: Int(value)))
        title.alignment = .right
        title.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(title)

        NSLayoutConstraint.activate([
            slider.topAnchor.constraint(equalTo: container.topAnchor, constant: 22),
            slider.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 28),
            slider.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            title.bottomAnchor.constraint(equalTo: slider.topAnchor, constant: -2),
            title.trailingAnchor.constraint(equalTo: slider.trailingAnchor)
        ])
        item.view = container
        item.representedObject = uuid
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
        return sub
    }

    @objc private func extTopToggleUUID(_ sender: NSButton) {
        guard let uuid = sender.superview?.identifier?.rawValue else { return }
        settings.setExtTopCornersEnabled(sender.state == .on, for: uuid)
        updateExtSliderForUUID(uuid)
    }
    @objc private func extBottomToggleUUID(_ sender: NSButton) {
        guard let uuid = sender.superview?.identifier?.rawValue else { return }
        settings.setExtBottomCornersEnabled(sender.state == .on, for: uuid)
        updateExtSliderForUUID(uuid)
    }

    private func updateExtSliderForUUID(_ uuid: String) {
        let visible = settings.extTopCornersEnabled(for: uuid) || settings.extBottomCornersEnabled(for: uuid)
        for item in externalSectionItems {
            guard item.view?.identifier?.rawValue == uuid else { continue }
            animateItemVisibility(item, visible: visible, animated: true)
            break
        }
    }
    @objc private func extRadiusChangedUUID(_ sender: NSSlider) {
        guard let uuid = sender.superview?.identifier?.rawValue else { return }
        let val = Int(sender.doubleValue)
        if val != lastExtHapticValue { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now); lastExtHapticValue = val }
        settings.setExtCornerRadius(CGFloat(sender.doubleValue), for: uuid)
        updateSliderLabels(in: sender.superview, value: sender.doubleValue)
    }
    @objc private func extPosEdgeUUID(_ sender: NSMenuItem) {
        guard let uuid = sender.representedObject as? String else { return }
        settings.setExtTopCornersUnderMenuBar(false, for: uuid)
    }
    @objc private func extPosBelowUUID(_ sender: NSMenuItem) {
        guard let uuid = sender.representedObject as? String else { return }
        settings.setExtTopCornersUnderMenuBar(true, for: uuid)
    }

    private func displayPosition(for screen: NSScreen, relativeTo builtIn: NSScreen) -> String {
        let e = screen.frame, m = builtIn.frame
        var h = "", v = ""
        if e.maxX <= m.minX { h = "Left" } else if e.minX >= m.maxX { h = "Right" }
        if e.minY >= m.maxY { v = "Above" } else if e.maxY <= m.minY { v = "Below" }
        if h.isEmpty && v.isEmpty { return "Overlapping" }
        if h.isEmpty { return v }; if v.isEmpty { return h }
        return "\(v) & \(h)"
    }

    // MARK: - Visibility helpers

    private func updateSliderVisibility(animated: Bool = true) {
        let visible = settings.topCornersEnabled || settings.bottomCornersEnabled
        animateItemVisibility(sliderItem, visible: visible, animated: animated)
    }
    private func updateExtSliderVisibility(animated: Bool = true) {
        let visible = NSScreen.screens.count > 1 && !settings.mirrorMainDisplay
            && (settings.extTopCornersEnabled || settings.extBottomCornersEnabled)
        animateItemVisibility(extSliderItem, visible: visible, animated: animated)
    }
    private func updateExtTogglesVisibility(animated: Bool = true) {
        let visible = NSScreen.screens.count > 1 && !settings.mirrorMainDisplay
        animateItemVisibility(extTopToggleItem, visible: visible, animated: animated)
        animateItemVisibility(extBottomToggleItem, visible: visible, animated: animated)
    }

    private func animateItemVisibility(_ item: NSMenuItem?, visible: Bool, animated: Bool = false) {
        guard let item = item, let view = item.view else { return }
        view.wantsLayer = true
        if visible {
            if item.isHidden { view.alphaValue = 0; item.isHidden = false
                if animated {
                    DispatchQueue.main.async { NSAnimationContext.runAnimationGroup { ctx in ctx.duration = 0.25; view.animator().alphaValue = 1 } }
                } else { view.alphaValue = 1 }
            }
        } else {
            if !item.isHidden {
                if animated {
                    NSAnimationContext.runAnimationGroup({ ctx in ctx.duration = 0.2; view.animator().alphaValue = 0 }, completionHandler: { item.isHidden = true })
                } else { view.alphaValue = 0; item.isHidden = true }
            }
        }
    }

    // MARK: - Actions

    @objc func selectStyle(_ sender: NSMenuItem) {
        if let s = sender.representedObject as? DisplayStyle { settings.displayStyle = s }
    }
    @objc func selAnim(_ sender: NSMenuItem) {
        if let s = sender.representedObject as? AnimationStyle { settings.animationStyle = s }
    }
    @objc func selStack(_ sender: NSMenuItem) {
        if let s = sender.representedObject as? StackMode { settings.stackMode = s }
    }
    @objc func selDetection(_ sender: NSMenuItem) {
        if let s = sender.representedObject as? FocusDetectionMode { settings.focusDetectionMode = s }
    }
    @objc func selOrder(_ sender: NSMenuItem) {
        if let s = sender.representedObject as? DisplayOrderMode { settings.displayOrderMode = s }
    }

    private var lastHapticValue: Int = -1
    private var lastExtHapticValue: Int = -1

    @objc func radiusChanged(_ sender: NSSlider) {
        let val = Int(sender.doubleValue)
        if val != lastHapticValue { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now); lastHapticValue = val }
        settings.cornerRadius = CGFloat(sender.doubleValue)
        updateSliderLabels(in: sender.superview, value: sender.doubleValue)
    }
    @objc func extRadiusChanged(_ sender: NSSlider) {
        let val = Int(sender.doubleValue)
        if val != lastExtHapticValue { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now); lastExtHapticValue = val }
        settings.extCornerRadius = CGFloat(sender.doubleValue)
        updateSliderLabels(in: sender.superview, value: sender.doubleValue)
    }
    private func sliderLabelText(value: Int) -> NSAttributedString {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        let color = NSColor.secondaryLabelColor
        let full = NSMutableAttributedString(string: "Radius: ", attributes: [
            .font: font, .foregroundColor: color
        ])
        full.append(NSAttributedString(string: "\(value) px", attributes: [
            .font: font, .foregroundColor: color
        ]))
        return full
    }

    private func updateSliderLabels(in container: NSView?, value: Double) {
        guard let c = container else { return }
        for v in c.subviews {
            if let l = v as? NSTextField, l.attributedStringValue.string.hasPrefix("Radius") {
                l.attributedStringValue = sliderLabelText(value: Int(value))
            }
        }
    }

    @objc func topToggle(_ sender: NSButton)     {
        settings.topCornersEnabled = (sender.state == .on)
        updateSliderVisibility(animated: true)
    }
    @objc func bottomToggle(_ sender: NSButton)  {
        settings.bottomCornersEnabled = (sender.state == .on)
        updateSliderVisibility(animated: true)
    }
    @objc func extTopToggle(_ sender: NSButton)  {
        settings.extTopCornersEnabled = (sender.state == .on)
        updateExtSliderVisibility(animated: true)
    }
    @objc func extBottomToggle(_ sender: NSButton) {
        settings.extBottomCornersEnabled = (sender.state == .on)
        updateExtSliderVisibility(animated: true)
    }
    private var mirrorToggleItem: NSMenuItem?

    @objc func mirrorToggle(_ sender: NSButton)  {
        settings.mirrorMainDisplay = (sender.state == .on)
        let mirroring = sender.state == .on
        // Fade all external sub-items EXCEPT the "External Monitors" header and mirror toggle
        for item in externalSectionItems where item != mirrorToggleItem {
            animateItemVisibility(item, visible: !mirroring, animated: true)
        }
        updateExtTogglesVisibility(animated: true)
        updateExtSliderVisibility(animated: true)
    }
    @objc func posEdge()                         { settings.topCornersUnderMenuBar = false }
    @objc func posBelow()                        { settings.topCornersUnderMenuBar = true }
    @objc func extPosEdge()                      { settings.extTopCornersUnderMenuBar = false }
    @objc func extPosBelow()                     { settings.extTopCornersUnderMenuBar = true }
    @objc func quitApp() { NSApplication.shared.terminate(nil) }
}
