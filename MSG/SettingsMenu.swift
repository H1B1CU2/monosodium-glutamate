import AppKit

class SettingsMenu: NSObject, NSMenuDelegate {

    let menu = NSMenu()
    weak var ad: AppDelegate?

    init(ad: AppDelegate) {
        self.ad = ad
        super.init()
        menu.delegate = self
        
        let nc = NotificationCenter.default
        nc.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in self?.menu.update() }
        nc.addObserver(forName: NSNotification.Name("SettingsChanged"), object: nil, queue: .main) { [weak self] _ in self?.updateAllVisibilities() }
    }

    // MARK: - NSMenuDelegate

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let ad = ad else { return }
        menu.autoenablesItems = false

        // ── Spacer ──────────────────
        addHeaderItem("Spacer", to: menu)
        
        let styleMenu = NSMenu()
        for style in DisplayStyle.allCases {
            let item = NSMenuItem(title: style.rawValue, action: #selector(selectStyle(_:)), keyEquivalent: "")
            item.representedObject = style
            item.target = self
            item.state = (style == ad.displayStyle) ? .on : .off
            styleMenu.addItem(item)
        }
        let styleItem = NSMenuItem(title: "Indicator Style", action: nil, keyEquivalent: "")
        styleItem.submenu = styleMenu
        menu.addItem(styleItem)

        if NSScreen.screens.count > 1 {
            addToggleItem("Built-in Display",
                          state: ad.prioritizeMainDisplay,
                          action: #selector(prioritizeMainChanged(_:)))
        }
        
        addToggleItem("Springy Animation",
                      state: ad.springAnimationEnabled,
                      action: #selector(springAnimationChanged(_:)))

        menu.addItem(.separator())

        // ── Cornermization ──────────
        addHeaderItem("Cornermization", to: menu)
        
        // --- Built-in Display ---
        let model = getModelName()
        addHeaderItem(model, to: menu)
        
        let topPosMenu = createPositionMenu(isExternal: false)
        addToggleItem("Top Corners",
                      state: ad.topCornersEnabled,
                      action: #selector(topToggleChanged(_:)),
                      submenu: topPosMenu,
                      isExternal: false,
                      isTopToggle: true)

        addToggleItem("Bottom Corners",
                      state: ad.bottomCornersEnabled,
                      action: #selector(bottomToggleChanged(_:)),
                      isExternal: false,
                      isBottomToggle: true)

        addSliderItem(value: ad.cornerRadius, isExternal: false)

        menu.addItem(.separator())
        
        // --- External Monitors ---
        if NSScreen.screens.count > 1 {
            addHeaderItem("External Monitors", to: menu)
            
            let extTopPosMenu = createPositionMenu(isExternal: true)
            addToggleItem("Top Corners",
                          state: ad.extTopCornersEnabled,
                          action: #selector(extTopToggleChanged(_:)),
                          submenu: extTopPosMenu,
                          isExternal: true,
                          isTopToggle: true)

            addToggleItem("Bottom Corners",
                          state: ad.extBottomCornersEnabled,
                          action: #selector(extBottomToggleChanged(_:)),
                          isExternal: true,
                          isBottomToggle: true)

            addSliderItem(value: ad.extCornerRadius, isExternal: true)

            addToggleItem("Mirror \(model) settings",
                          state: ad.mirrorMainDisplay,
                          action: #selector(mirrorToggleChanged(_:)))

            menu.addItem(.separator())
        }
        
        // ── Laboratory ──────────────
        addHeaderItem("Laboratory", to: menu, showWarning: true)

        addToggleItem("Black Menu Bar",
                      state: ad.darkMenuBarEnabled,
                      action: #selector(darkMenuBarChanged(_:)))

        addToggleItem("Only in Fullscreen",
                      state: ad.fullscreenOnly,
                      action: #selector(fullscreenOnlyChanged(_:)))

        addToggleItem("Hide in Mission Control",
                      state: ad.hideInMissionControl,
                      action: #selector(missionControlChanged(_:)))

        menu.addItem(.separator())
        
        // ── Quit ───────────────────────────────────
        let quit = NSMenuItem(title: "Quit MSG", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
        
        updateAllVisibilities()
    }

    private func updateAllVisibilities() {
        updateSliderItemVisibility()
        updateExtSliderVisibility()
        updateExtTogglesVisibility()
    }

    // MARK: - Helpers

    private func addHeaderItem(_ title: String, to targetMenu: NSMenu, showWarning: Bool = false) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 250, height: 20))
        let text = title.uppercased() + (showWarning ? " ⚠️" : "")
        let asTitle = NSMutableAttributedString(string: text, attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .bold),
            .foregroundColor: NSColor.secondaryLabelColor
        ])
        if showWarning, let range = text.range(of: "⚠️") {
            let nsRange = NSRange(range, in: text)
            asTitle.addAttributes([.font: NSFont.systemFont(ofSize: 8), .baselineOffset: 0.5], range: nsRange)
            container.toolTip = "The features in this section are work in progress"
        }
        let label = NSTextField(labelWithAttributedString: asTitle)
        label.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14)
        ])
        item.view = container
        item.isEnabled = false
        targetMenu.addItem(item)
    }

    private func addSliderItem(value: CGFloat, isExternal: Bool) {
        let item = NSMenuItem()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 250, height: 58))
        container.wantsLayer = true
        let slider = NSSlider(value: Double(value), minValue: 1, maxValue: 30, target: self, action: isExternal ? #selector(extRadiusChanged(_:)) : #selector(radiusChanged(_:)))
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
        guard let ad = ad else { return NSMenu() }
        let underBar = isExternal ? ad.extTopCornersUnderMenuBar : ad.topCornersUnderMenuBar
        let sub = NSMenu()
        let atEdge = NSMenuItem(title: "At Screen Edge", action: isExternal ? #selector(extPositionScreenEdge) : #selector(positionScreenEdge), keyEquivalent: "")
        atEdge.target = self
        atEdge.state = underBar ? .off : .on
        sub.addItem(atEdge)
        let belowBar = NSMenuItem(title: "Below Menu Bar", action: isExternal ? #selector(extPositionBelowMenuBar) : #selector(positionBelowMenuBar), keyEquivalent: "")
        belowBar.target = self
        belowBar.state = underBar ? .on : .off
        sub.addItem(belowBar)
        return sub
    }

    private func addToggleItem(_ title: String, state: Bool, action: Selector, to targetMenu: NSMenu? = nil, submenu: NSMenu? = nil, isExternal: Bool = false, isTopToggle: Bool = false, isBottomToggle: Bool = false) {
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
            button.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            button.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14)
        ])
        item.view = container
        item.submenu = submenu
        (targetMenu ?? menu).addItem(item)
        if isExternal { if isTopToggle { extTopToggleItem = item } else if isBottomToggle { extBottomToggleItem = item } }
    }

    private func getModelName() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &model, &size, nil, 0)
        let identifier = String(cString: model)
        if identifier.contains("MacBookAir") { return "MacBook Air" }
        if identifier.contains("MacBookPro") { return "MacBook Pro" }
        if identifier.contains("Macmini") { return "Mac mini" }
        if identifier.contains("iMac") { return "iMac" }
        if identifier.contains("MacStudio") { return "Mac Studio" }
        if identifier.contains("MacPro") { return "Mac Pro" }
        return "Built-in Display"
    }

    private var sliderItem: NSMenuItem?
    private var extSliderItem: NSMenuItem?
    private var extTopToggleItem: NSMenuItem?
    private var extBottomToggleItem: NSMenuItem?

    private func updateSliderItemVisibility() {
        let visible = (ad?.topCornersEnabled ?? true) || (ad?.bottomCornersEnabled ?? true)
        animateItemVisibility(sliderItem, visible: visible)
    }

    private func updateExtSliderVisibility() {
        let mirroring = ad?.mirrorMainDisplay ?? false
        let visible = !mirroring && ((ad?.extTopCornersEnabled ?? true) || (ad?.extBottomCornersEnabled ?? true))
        animateItemVisibility(extSliderItem, visible: visible)
    }

    private func updateExtTogglesVisibility() {
        let mirroring = ad?.mirrorMainDisplay ?? false
        animateItemVisibility(extTopToggleItem, visible: !mirroring)
        animateItemVisibility(extBottomToggleItem, visible: !mirroring)
    }

    private func animateItemVisibility(_ item: NSMenuItem?, visible: Bool) {
        guard let item = item, let view = item.view else { return }
        view.wantsLayer = true
        if visible {
            if item.isHidden { view.alphaValue = 0; item.isHidden = false
                DispatchQueue.main.async { NSAnimationContext.runAnimationGroup { context in context.duration = 0.25; view.animator().alphaValue = 1 } }
            }
        } else {
            if !item.isHidden {
                NSAnimationContext.runAnimationGroup({ context in context.duration = 0.2; view.animator().alphaValue = 0 }, completionHandler: { item.isHidden = true })
            }
        }
    }

    // MARK: - Actions
    @objc func selectStyle(_ sender: NSMenuItem) { if let style = sender.representedObject as? DisplayStyle { ad?.displayStyle = style } }
    @objc func prioritizeMainChanged(_ sender: NSButton) { ad?.prioritizeMainDisplay = (sender.state == .on) }
    @objc func springAnimationChanged(_ sender: NSButton) { ad?.springAnimationEnabled = (sender.state == .on) }
    @objc func radiusChanged(_ sender: NSSlider) { 
        let val = Int(sender.doubleValue); if val != lastHapticValue { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now); lastHapticValue = val }
        ad?.cornerRadius = CGFloat(sender.doubleValue); updateSliderLabels(in: sender.superview, value: sender.doubleValue)
    }
    @objc func extRadiusChanged(_ sender: NSSlider) { 
        let val = Int(sender.doubleValue); if val != lastExtHapticValue { NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now); lastExtHapticValue = val }
        ad?.extCornerRadius = CGFloat(sender.doubleValue); updateSliderLabels(in: sender.superview, value: sender.doubleValue)
    }
    private var lastHapticValue: Int = -1
    private var lastExtHapticValue: Int = -1
    private func updateSliderLabels(in container: NSView?, value: Double) {
        guard let container = container else { return }
        for v in container.subviews { if let label = v as? NSTextField, label.alignment == .right { label.stringValue = "\(Int(value)) px" } }
    }
    @objc func topToggleChanged(_ sender: NSButton) { ad?.topCornersEnabled = (sender.state == .on); updateSliderItemVisibility() }
    @objc func bottomToggleChanged(_ sender: NSButton) { ad?.bottomCornersEnabled = (sender.state == .on); updateSliderItemVisibility() }
    @objc func extTopToggleChanged(_ sender: NSButton) { ad?.extTopCornersEnabled = (sender.state == .on); updateExtSliderVisibility() }
    @objc func extBottomToggleChanged(_ sender: NSButton) { ad?.extBottomCornersEnabled = (sender.state == .on); updateExtSliderVisibility() }
    @objc func mirrorToggleChanged(_ sender: NSButton) { ad?.mirrorMainDisplay = (sender.state == .on) }
    @objc func positionScreenEdge() { ad?.topCornersUnderMenuBar = false }
    @objc func positionBelowMenuBar() { ad?.topCornersUnderMenuBar = true }
    @objc func extPositionScreenEdge() { ad?.extTopCornersUnderMenuBar = false }
    @objc func extPositionBelowMenuBar() { ad?.extTopCornersUnderMenuBar = true }
    @objc func darkMenuBarChanged(_ sender: NSButton) { ad?.darkMenuBarEnabled = (sender.state == .on) }
    @objc func fullscreenOnlyChanged(_ sender: NSButton) { ad?.fullscreenOnly = (sender.state == .on) }
    @objc func missionControlChanged(_ sender: NSButton) { ad?.hideInMissionControl = (sender.state == .on) }
    @objc func quitApp() { NSApplication.shared.terminate(nil) }
}
