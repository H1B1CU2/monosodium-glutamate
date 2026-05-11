import AppKit

final class SettingsMenu: NSObject, NSMenuDelegate {

    let menu = NSMenu()
    private let settings: Settings

    // Track visibility state
    private var externalSectionItems: [NSMenuItem] = []
    private var externalHeaderItem: NSMenuItem?
    private var externalSepItem: NSMenuItem?
    private var focusDetectionItem: NSMenuItem?
    private var displayOrderItem: NSMenuItem?
    private var sliderItem: NSMenuItem?
    private var extSliderItem: NSMenuItem?
    private var extTopToggleItem: NSMenuItem?
    private var extBottomToggleItem: NSMenuItem?

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
        externalSectionItems.removeAll(); externalHeaderItem = nil; externalSepItem = nil
        focusDetectionItem = nil; displayOrderItem = nil

        menu.autoenablesItems = false

        // ── Spacer ──────────────────
        addHeaderItem("Spacer", to: menu)

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
        let styleItem = NSMenuItem(title: "Indicator Style", action: nil, keyEquivalent: "")
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
        let animItem = NSMenuItem(title: "Animation", action: nil, keyEquivalent: "")
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
        let detectionItem = NSMenuItem(title: "Focus Detection", action: nil, keyEquivalent: "")
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
        let orderItem = NSMenuItem(title: "Display Order", action: nil, keyEquivalent: "")
        orderItem.submenu = orderMenu
        menu.addItem(orderItem)
        displayOrderItem = orderItem

        menu.addItem(.separator())

        // ── Cornermization ──────────
        addHeaderItem("Cornermization", to: menu)

        let model = modelName()
        addHeaderItem(model, to: menu, indent: true)

        let topPosMenu = createPositionMenu(isExternal: false)
        addToggleItem("Top Corners", state: settings.topCornersEnabled, action: #selector(topToggle(_:)), submenu: topPosMenu)

        addToggleItem("Bottom Corners", state: settings.bottomCornersEnabled, action: #selector(bottomToggle(_:)))

        addSliderItem(value: settings.cornerRadius, isExternal: false)

        menu.addItem(.separator())

        // ── External Monitors ───────
        externalSectionItems.removeAll()
        externalHeaderItem = nil

        addHeaderItem("External Monitors", to: menu)
        externalHeaderItem = menu.items.last

        addToggleItem("Mirror \(model) settings", state: settings.mirrorMainDisplay, action: #selector(mirrorToggle(_:)))

        let extTopPosMenu = createPositionMenu(isExternal: true)
        addToggleItem("Top Corners", state: settings.extTopCornersEnabled, action: #selector(extTopToggle(_:)), submenu: extTopPosMenu)

        addToggleItem("Bottom Corners", state: settings.extBottomCornersEnabled, action: #selector(extBottomToggle(_:)))

        addSliderItem(value: settings.extCornerRadius, isExternal: true)

        if let builtIn = NSScreen.screens.first {
            for (idx, screen) in NSScreen.screens.enumerated() where idx > 0 {
                addDisplayPositionItem(screen: screen, index: idx, relativeTo: builtIn)
            }
        }

        externalSepItem = NSMenuItem.separator()
        menu.addItem(externalSepItem!)

        if let headerIdx = menu.items.firstIndex(of: externalHeaderItem!) {
            for i in (headerIdx + 1)..<menu.items.count {
                externalSectionItems.append(menu.items[i])
            }
        }
        externalSectionItems.insert(externalHeaderItem!, at: 0)
        if let sep = externalSepItem { externalSectionItems.append(sep) }

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

        let label = NSTextField(labelWithString: "\(Int(value)) px")
        label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.alignment = .right
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)

        let title = NSTextField(labelWithString: "Corner Radius")
        title.font = .menuFont(ofSize: 0)
        title.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(title)

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            title.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            label.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            slider.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
            slider.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            slider.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20)
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

    private func addToggleItem(_ title: String, state: Bool, action: Selector, submenu: NSMenu? = nil) {
        let item = NSMenuItem()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 250, height: 24))
        container.wantsLayer = true
        let button = NSButton(checkboxWithTitle: title, target: self, action: action)
        button.state = state ? .on : .off
        button.font = .menuFont(ofSize: 0)
        button.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(button)
        NSLayoutConstraint.activate([
            button.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            button.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            button.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14)
        ])
        item.view = container
        item.submenu = submenu
        menu.addItem(item)
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

    private func displayPosition(for screen: NSScreen, relativeTo builtIn: NSScreen) -> String {
        let e = screen.frame, m = builtIn.frame
        var h = "", v = ""
        if e.maxX <= m.minX { h = "Left" } else if e.minX >= m.maxX { h = "Right" }
        if e.minY >= m.maxY { v = "Above" } else if e.maxY <= m.minY { v = "Below" }
        if h.isEmpty && v.isEmpty { return "Overlapping" }
        if h.isEmpty { return v }; if v.isEmpty { return h }
        return "\(v) & \(h)"
    }

    private func addDisplayPositionItem(screen: NSScreen, index: Int, relativeTo builtIn: NSScreen) {
        let name = screen.localizedName
        let pos = displayPosition(for: screen, relativeTo: builtIn)
        let item = NSMenuItem(title: "\(name): \(pos)", action: nil, keyEquivalent: "")
        item.isEnabled = false
        menu.addItem(item)
    }

    // MARK: - Visibility helpers

    private func updateSliderVisibility(animated: Bool = true) {
        let visible = settings.topCornersEnabled || settings.bottomCornersEnabled
        animateItemVisibility(sliderItem, visible: visible, animated: animated)
    }
    private func updateExtSliderVisibility(animated: Bool = true) {
        let visible = !settings.mirrorMainDisplay && (settings.extTopCornersEnabled || settings.extBottomCornersEnabled)
        animateItemVisibility(extSliderItem, visible: visible, animated: animated)
    }
    private func updateExtTogglesVisibility(animated: Bool = true) {
        let visible = !settings.mirrorMainDisplay
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
    private func updateSliderLabels(in container: NSView?, value: Double) {
        guard let c = container else { return }
        for v in c.subviews {
            if let l = v as? NSTextField, l.alignment == .right { l.stringValue = "\(Int(value)) px" }
        }
    }

    @objc func topToggle(_ sender: NSButton)     { settings.topCornersEnabled = (sender.state == .on) }
    @objc func bottomToggle(_ sender: NSButton)  { settings.bottomCornersEnabled = (sender.state == .on) }
    @objc func extTopToggle(_ sender: NSButton)  { settings.extTopCornersEnabled = (sender.state == .on) }
    @objc func extBottomToggle(_ sender: NSButton) { settings.extBottomCornersEnabled = (sender.state == .on) }
    @objc func mirrorToggle(_ sender: NSButton)  { settings.mirrorMainDisplay = (sender.state == .on) }
    @objc func posEdge()                         { settings.topCornersUnderMenuBar = false }
    @objc func posBelow()                        { settings.topCornersUnderMenuBar = true }
    @objc func extPosEdge()                      { settings.extTopCornersUnderMenuBar = false }
    @objc func extPosBelow()                     { settings.extTopCornersUnderMenuBar = true }
    @objc func quitApp() { NSApplication.shared.terminate(nil) }
}
