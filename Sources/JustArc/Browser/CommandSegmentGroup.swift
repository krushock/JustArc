import AppKit
import JustArcCore

/// Answers whether a command can run right now, so each segment of a capsule can be
/// dimmed on its own.
@MainActor
protocol CommandAvailability: AnyObject {
    func canPerform(_ action: Selector?) -> Bool
}

/// A toolbar item drawn as one capsule with divided segments, the way Disk Utility
/// draws its volume plus and minus.
///
/// It is a toolbar item holding an `NSSegmentedControl` of our own. An earlier version
/// used `NSToolbarItemGroup`'s segmented factory instead and did not work: the factory
/// returns a plain group whatever class it is called on, AppKit validates such a group
/// only as a whole so segments could not be dimmed separately, and presses went through
/// a private picker view that never reached the command. With our own control every
/// part of that is public API: we read the pressed segment, enable segments one by
/// one, and AppKit still draws the control in the toolbar's glass style.
@MainActor
final class CommandSegmentItem: NSToolbarItem {
    struct Segment {
        let label: String
        let symbol: String
        let action: Selector
    }

    private let segments: [Segment]
    private let control: NSSegmentedControl
    private weak var handler: AnyObject?

    init(identifier: NSToolbarItem.Identifier, label: String, segments: [Segment], handler: AnyObject?) {
        self.segments = segments
        self.handler = handler
        let images = segments.map {
            NSImage(systemSymbolName: $0.symbol, accessibilityDescription: $0.label) ?? NSImage()
        }
        control = NSSegmentedControl(images: images, trackingMode: .momentary, target: nil, action: nil)
        control.segmentStyle = .automatic
        for (index, segment) in segments.enumerated() {
            control.setToolTip(segment.label, forSegment: index)
            control.setWidth(34, forSegment: index)
        }
        super.init(itemIdentifier: identifier)

        control.target = self
        control.action = #selector(segmentPressed(_:))
        view = control
        self.label = label
        paletteLabel = label
        toolTip = label
        isBordered = true
        menuFormRepresentation = makeMenuForm(label: label)
    }

    @objc private func segmentPressed(_ sender: NSSegmentedControl) {
        let index = sender.selectedSegment
        guard segments.indices.contains(index) else { return }
        perform(segments[index].action)
    }

    private func perform(_ command: Selector) {
        NSApp.sendAction(command, to: resolvedHandler(for: command), from: self)
    }

    /// Toolbar items with a custom view are not validated automatically, so each
    /// segment is enabled here from what the handler says it can do right now.
    override func validate() {
        var anyEnabled = false
        for (index, segment) in segments.enumerated() {
            let enabled = isAvailable(segment.action)
            control.setEnabled(enabled, forSegment: index)
            anyEnabled = anyEnabled || enabled
        }
        isEnabled = anyEnabled
    }

    private func isAvailable(_ command: Selector) -> Bool {
        let target = resolvedHandler(for: command)
        if let answering = target as? CommandAvailability { return answering.canPerform(command) }
        return target != nil
    }

    /// The handler is passed in rather than looked up from the key window, because when
    /// the app is not frontmost there is no key window and every segment would dim.
    private func resolvedHandler(for command: Selector) -> AnyObject? {
        if let handler, handler.responds(to: command) { return handler }
        return NSApp.target(forAction: command, to: nil, from: self) as AnyObject?
    }

    /// What the item turns into when the toolbar is too narrow and it moves to the
    /// overflow menu: a submenu with one entry per segment.
    private func makeMenuForm(label: String) -> NSMenuItem {
        let item = NSMenuItem(title: label, action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: label)
        for segment in segments {
            let entry = NSMenuItem(title: segment.label, action: #selector(menuEntryChosen(_:)),
                                   keyEquivalent: "")
            entry.target = self
            entry.representedObject = NSStringFromSelector(segment.action)
            entry.image = NSImage(systemSymbolName: segment.symbol, accessibilityDescription: segment.label)
            submenu.addItem(entry)
        }
        item.submenu = submenu
        return item
    }

    @objc private func menuEntryChosen(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        perform(NSSelectorFromString(name))
    }
}
