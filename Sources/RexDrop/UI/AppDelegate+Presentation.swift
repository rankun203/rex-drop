import AppKit

extension AppDelegate {
    func installScroll(_ scroll: NSScrollView, stack: NSStackView, in root: NSView, inset: CGFloat) -> NSLayoutConstraint {
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 7
        scroll.drawsBackground = false; scroll.hasHorizontalScroller = false; scroll.horizontalScrollElasticity = .none; scroll.borderType = .noBorder; scroll.hasVerticalScroller = true; scroll.autohidesScrollers = true; scroll.documentView = stack
        root.addSubview(scroll); scroll.translatesAutoresizingMaskIntoConstraints = false; stack.translatesAutoresizingMaskIntoConstraints = false
        let height = scroll.heightAnchor.constraint(equalToConstant: 100)
        NSLayoutConstraint.activate([scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: inset), scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -inset), scroll.topAnchor.constraint(equalTo: root.topAnchor, constant: inset), scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -inset), height, stack.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor), stack.topAnchor.constraint(equalTo: scroll.contentView.topAnchor), stack.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor)])
        return height
    }
    func makePanel() {
        panel = DropPanel(contentRect: NSRect(x: 0, y: 0, width: 600, height: 155), styleMask: [.titled, .closable, .resizable, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
        panel.minSize = NSSize(width: 400, height: 90)
        panel.title = "Rex Drop"; panel.titleVisibility = .hidden; panel.titlebarAppearsTransparent = true
        panel.delegate = self; panel.isFloatingPanel = true; panel.level = .floating
        panel.hidesOnDeactivate = false; panel.isReleasedWhenClosed = false; panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let root: NSView
        if preview { let plain = NSView(); plain.wantsLayer = true; plain.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor; root = plain }
        else { let effect = NSVisualEffectView(); effect.material = .popover; effect.blendingMode = .behindWindow; effect.state = .active; root = effect }
        panel.contentView = root
        let container = NSView(); root.addSubview(container); container.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([container.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12), container.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12), container.topAnchor.constraint(equalTo: root.topAnchor, constant: 34), container.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12)])
        listHeight = installScroll(scroll, stack: list, in: container, inset: 0)
        listHeight.priority = .defaultLow
        panel.center()
    }
    func makePopover() {
        let controller = NSViewController(), root = DestinationSurface(frame: NSRect(x: 0, y: 0, width: 400, height: 116))
        root.owner = self; controller.view = root
        let content = NSView(); root.addSubview(content); content.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([content.leadingAnchor.constraint(equalTo: root.leadingAnchor), content.trailingAnchor.constraint(equalTo: root.trailingAnchor), content.topAnchor.constraint(equalTo: root.topAnchor), content.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -32)])
        destinationHeight = installScroll(destinationScroll, stack: destinations, in: content, inset: 10)
        let divider = NSBox(); divider.boxType = .separator
        root.addSubview(divider); divider.translatesAutoresizingMaskIntoConstraints = false
        quitButton.target = self; quitButton.action = #selector(quit)
        quitButton.isBordered = false; quitButton.font = .systemFont(ofSize: 12)
        root.addSubview(quitButton); quitButton.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([divider.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 10), divider.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -10), divider.topAnchor.constraint(equalTo: content.bottomAnchor), quitButton.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -14), quitButton.centerYAnchor.constraint(equalTo: content.bottomAnchor, constant: 16)])
        popover.contentViewController = controller; popover.delegate = self
        popover.behavior = .applicationDefined; popover.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        renderDestinations()
    }
    func clear(_ stack: NSStackView) {
        for view in stack.arrangedSubviews { stack.removeArrangedSubview(view); view.removeFromSuperview() }
    }
    func renderDestinations() {
        clear(destinations)
        if targets.isEmpty {
            let empty = NSTextField(labelWithString: refreshing ? "Loading…" : "No destinations")
            empty.font = .systemFont(ofSize: 12); empty.textColor = .secondaryLabelColor; empty.alignment = .center
            destinations.addArrangedSubview(empty)
            empty.widthAnchor.constraint(equalTo: destinations.widthAnchor).isActive = true
            empty.heightAnchor.constraint(equalToConstant: 70).isActive = true
        }
        for target in targets {
            let row = TargetRow(target: target, owner: self); destinations.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: destinations.widthAnchor).isActive = true
        }
        let height = CGFloat(min(455, max(70, targets.count * 72 - 7)))
        destinationHeight.constant = height; popover.contentSize = NSSize(width: 400, height: height + 52)
        updateQuitButton()
        popover.contentViewController?.view.layoutSubtreeIfNeeded()
    }
    func renderContent() {
        clear(list); cards.removeAll()
        for task in tasks {
            let card = TaskCard(task: task, owner: self); list.addArrangedSubview(card); cards[task.id] = card
            card.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
        }
        resizeProgressPanel()
    }
    func resizeProgressPanel() {
        let height = min(CGFloat(430), max(CGFloat(44), tasks.reduce(CGFloat(0)) { $0 + $1.preferredHeight } + CGFloat(max(0, tasks.count - 1) * 7)))
        let old = panel.frame
        let screen = panel.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1920, height: 1080)
        let availableWidth = max(300, screen.width - 32)
        // Reserve controls and byte counts, then fit the widest path. Grow while
        // transferring so changing byte labels never make the window jitter.
        let titleWidth = cards.values.map { card in
            (card.title.stringValue as NSString).size(withAttributes: [.font: card.title.font!]).width
        }.max() ?? 0
        let desiredWidth = min(availableWidth, max(600, ceil(titleWidth) + 310))
        let newContent = desiredWidth != fittedProgressWidth
        let newHeight = listHeight.constant != height
        guard newContent || newHeight else { return }
        let width = newContent ? min(availableWidth, max(old.width, desiredWidth)) : old.width
        let windowHeight = newHeight ? height + 46 : old.height
        fittedProgressWidth = desiredWidth
        listHeight.constant = height
        let x = max(screen.minX + 16, min(old.midX - width / 2, screen.maxX - width - 16))
        panel.setFrame(NSRect(x: x, y: old.maxY - windowHeight, width: width, height: windowHeight), display: true)
        panel.contentView?.layoutSubtreeIfNeeded()
    }
}
