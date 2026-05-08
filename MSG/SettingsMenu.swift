import AppKit

// MARK: - Dot indicators for the slider track

private class SliderDotsView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let knobInset: CGFloat = 9
        let trackWidth = bounds.width - 2 * knobInset
        let minVal: Double = 1
        let maxVal: Double = 30
        let interval: Double = 2

        let dotSize: CGFloat = 2
        NSColor.tertiaryLabelColor.setFill()

        var value = interval
        while value <= maxVal {
            let fraction = CGFloat((value - minVal) / (maxVal - minVal))
            let x = knobInset + fraction * trackWidth
            let dotRect = NSRect(x: x - dotSize / 2, y: (bounds.height - dotSize) / 2, width: dotSize, height: dotSize)
            NSBezierPath(ovalIn: dotRect).fill()
            value += interval
        }
    }
}

// MARK: - Settings Menu

class SettingsMenu: NSObject, NSMenuDelegate {

    private weak var ad: AppDelegate?
    var radiusSlider: NSSlider?
    var radiusLabel: NSTextField?
    private var sliderItem: NSMenuItem?
    private var lastHapticValue: Int = 0

    let menu: NSMenu

    init(delegate: AppDelegate) {
        self.ad = delegate
        self.menu = NSMenu()
        super.init()
        menu.delegate = self
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
            addToggleItem("Prioritize Main Display",
                          state: ad.prioritizeMainDisplay,
                          action: #selector(prioritizeMainChanged(_:)))
        }
        
        addToggleItem("Springy Animation",
                      state: ad.springAnimationEnabled,
                      action: #selector(springAnimationChanged(_:)))

        menu.addItem(.separator())

        // ── Cornermization ──────────
        addHeaderItem("Cornermization", to: menu)
        
        addToggleItem("Top Corners",
                      state: ad.topCornersEnabled,
                      action: #selector(topToggleChanged(_:)))

        addToggleItem("Bottom Corners",
                      state: ad.bottomCornersEnabled,
                      action: #selector(bottomToggleChanged(_:)))

        addSliderItem(value: ad.cornerRadius)

        addToggleItem("External Monitor Corners",
                      state: ad.externalMonitorCorners,
                      action: #selector(externalMonitorChanged(_:)))

        let positionItem = NSMenuItem(title: "Top Position", action: nil, keyEquivalent: "")
        let positionSub = NSMenu()
        let atEdge = NSMenuItem(title: "At Screen Edge", action: #selector(positionScreenEdge), keyEquivalent: "")
        atEdge.target = self
        atEdge.state = ad.topCornersUnderMenuBar ? .off : .on
        positionSub.addItem(atEdge)
        let belowBar = NSMenuItem(title: "Below Menu Bar", action: #selector(positionBelowMenuBar), keyEquivalent: "")
        belowBar.target = self
        belowBar.state = ad.topCornersUnderMenuBar ? .on : .off
        positionSub.addItem(belowBar)
        positionItem.submenu = positionSub
        menu.addItem(positionItem)

        menu.addItem(.separator())

        // ── Laboratory ──────────────
        addHeaderItem("Laboratory", to: menu, showWarning: true)

        addToggleItem("Dark Menu Bar",
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
            asTitle.addAttributes([
                .font: NSFont.systemFont(ofSize: 8),
                .baselineOffset: 0.5
            ], range: nsRange)
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

    private func addSliderItem(value: CGFloat) {
        let item = NSMenuItem()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 250, height: 58))
        let menuFontSize = NSFont.menuFont(ofSize: 0).pointSize

        let title = NSTextField(labelWithString: "Corner Radius")
        title.font = .menuFont(ofSize: 0)
        title.textColor = .labelColor
        title.translatesAutoresizingMaskIntoConstraints = false

        let label = NSTextField(labelWithString: "\(Int(value)) px")
        label.font = .monospacedDigitSystemFont(ofSize: menuFontSize, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.alignment = .right
        label.translatesAutoresizingMaskIntoConstraints = false
        radiusLabel = label

        let slider = NSSlider(value: Double(value), minValue: 1, maxValue: 30,
                              target: self, action: #selector(radiusChanged(_:)))
        slider.controlSize = NSControl.ControlSize.mini
        slider.isContinuous = true
        slider.translatesAutoresizingMaskIntoConstraints = false
        radiusSlider = slider

        let dots = SliderDotsView()
        dots.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(title)
        container.addSubview(label)
        container.addSubview(slider)
        container.addSubview(dots)

        NSLayoutConstraint.activate([
            title.topAnchor.constraint(equalTo: container.topAnchor, constant: 8),
            title.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            label.centerYAnchor.constraint(equalTo: title.centerYAnchor),
            label.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            label.widthAnchor.constraint(equalToConstant: 44),
            slider.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 4),
            slider.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            slider.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            dots.topAnchor.constraint(equalTo: slider.bottomAnchor, constant: 0),
            dots.leadingAnchor.constraint(equalTo: slider.leadingAnchor),
            dots.trailingAnchor.constraint(equalTo: slider.trailingAnchor),
            dots.heightAnchor.constraint(equalToConstant: 8),
            dots.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -4)
        ])

        item.view = container
        item.isHidden = !(ad?.topCornersEnabled ?? true) && !(ad?.bottomCornersEnabled ?? true)
        sliderItem = item
        menu.addItem(item)
    }

    private func addExperimentalToggleItem(_ title: String, state: Bool, action: Selector, to targetMenu: NSMenu) {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 250, height: 24))
        // Tooltip on the view ensures it works with custom views
        container.toolTip = "This feature is under development"

        let button = NSButton(checkboxWithTitle: "", target: self, action: action)
        button.state = state ? .on : .off
        button.translatesAutoresizingMaskIntoConstraints = false
        
        let asTitle = NSMutableAttributedString(string: title, attributes: [
            .font: NSFont.menuFont(ofSize: 0),
            .foregroundColor: NSColor.labelColor
        ])
        if let range = title.range(of: "⚠️") {
            let nsRange = NSRange(range, in: title)
            asTitle.addAttributes([
                .font: NSFont.systemFont(ofSize: 9),
                .baselineOffset: 1.5 
            ], range: nsRange)
        }
        button.attributedTitle = asTitle

        container.addSubview(button)

        NSLayoutConstraint.activate([
            button.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            button.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
            button.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -14)
        ])

        let item = NSMenuItem()
        item.view = container
        targetMenu.addItem(item)
    }

    private func addToggleItem(_ title: String, state: Bool, action: Selector, to targetMenu: NSMenu? = nil) {
        let item = NSMenuItem()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 250, height: 24))

        let button = NSButton(checkboxWithTitle: title, target: self, action: action)
        button.state = state ? .on : .off
        button.font = .menuFont(ofSize: 0)
        button.translatesAutoresizingMaskIntoConstraints = false

        container.addSubview(button)
        NSLayoutConstraint.activate([
            button.centerYAnchor.constraint(equalTo: container.centerYAnchor),
            button.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 14),
        ])

        item.view = container
        (targetMenu ?? menu).addItem(item)
    }

    // MARK: - Actions

    @objc private func selectStyle(_ sender: NSMenuItem) {
        guard let style = sender.representedObject as? DisplayStyle else { return }
        ad?.displayStyle = style
    }

    @objc func radiusChanged(_ sender: NSSlider) {
        let v = CGFloat(sender.intValue)
        radiusLabel?.stringValue = "\(Int(v)) px"
        ad?.cornerRadius = v
        let intVal = Int(v)
        if intVal != lastHapticValue {
            lastHapticValue = intVal
            NSHapticFeedbackManager.defaultPerformer.perform(.alignment, performanceTime: .now)
        }
    }

    @objc private func topToggleChanged(_ sender: NSButton) {
        ad?.topCornersEnabled = sender.state == .on
        updateSliderItemVisibility()
    }

    @objc private func bottomToggleChanged(_ sender: NSButton) {
        ad?.bottomCornersEnabled = sender.state == .on
        updateSliderItemVisibility()
    }

    private func updateSliderItemVisibility() {
        let visible = (ad?.topCornersEnabled ?? true) || (ad?.bottomCornersEnabled ?? true)
        guard let item = sliderItem, let view = item.view else { return }
        
        view.wantsLayer = true // Ensure layer-backed for animation
        
        if visible {
            if item.isHidden {
                view.alphaValue = 0
                item.isHidden = false
                // Delay slightly to allow the menu to register the unhidden item
                DispatchQueue.main.async {
                    NSAnimationContext.runAnimationGroup { context in
                        context.duration = 0.25
                        view.animator().alphaValue = 1
                    }
                }
            }
        } else {
            if !item.isHidden {
                NSAnimationContext.runAnimationGroup({ context in
                    context.duration = 0.2
                    view.animator().alphaValue = 0
                }, completionHandler: {
                    item.isHidden = true
                })
            }
        }
    }

    @objc private func positionScreenEdge() {
        ad?.topCornersUnderMenuBar = false
    }

    @objc private func positionBelowMenuBar() {
        ad?.topCornersUnderMenuBar = true
    }

    @objc private func fullscreenOnlyChanged(_ sender: NSButton) {
        ad?.fullscreenOnly = sender.state == .on
    }

    @objc private func darkMenuBarChanged(_ sender: NSButton) {
        ad?.darkMenuBarEnabled = sender.state == .on
    }

    @objc private func missionControlChanged(_ sender: NSButton) {
        ad?.hideInMissionControl = sender.state == .on
    }

    @objc private func externalMonitorChanged(_ sender: NSButton) {
        ad?.externalMonitorCorners = sender.state == .on
    }

    @objc private func prioritizeMainChanged(_ sender: NSButton) {
        ad?.prioritizeMainDisplay = sender.state == .on
    }

    @objc private func springAnimationChanged(_ sender: NSButton) {
        ad?.springAnimationEnabled = sender.state == .on
    }

    @objc private func quitApp() {
        NSApp.terminate(nil)
    }
}
