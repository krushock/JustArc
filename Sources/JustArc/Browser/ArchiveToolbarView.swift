import AppKit
import JustArcCore

/// WinRAR's command strip: large icons with the command name underneath,
/// grouped by a thin vertical divider.
final class ArchiveToolbarView: NSView {
    enum Command: String, CaseIterable {
        case add, extractTo, test, view, delete, find, info, password, save

        var title: String {
            switch self {
            case .add: return L("Add")
            case .extractTo: return L("Extract To")
            case .test: return L("Test")
            case .view: return L("View")
            case .delete: return L("Delete")
            case .find: return L("Find")
            case .info: return L("Info")
            case .password: return L("Password")
            case .save: return L("Save")
            }
        }

        var symbol: String {
            switch self {
            case .add: return "plus.rectangle.on.folder"
            case .extractTo: return "tray.and.arrow.up"
            case .test: return "checkmark.seal"
            case .view: return "eye"
            case .delete: return "trash"
            case .find: return "magnifyingglass"
            case .info: return "info.circle"
            case .password: return "lock"
            case .save: return "square.and.arrow.down"
            }
        }

        /// A divider is drawn after these, matching WinRAR's grouping.
        var startsNewGroup: Bool {
            self == .find
        }
    }

    var onCommand: ((Command) -> Void)?
    private var buttons: [Command: NSButton] = [:]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 58)
    }

    private func build() {
        wantsLayer = true
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.alignment = .centerY
        stack.edgeInsets = NSEdgeInsets(top: 2, left: 8, bottom: 2, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        for command in Command.allCases {
            if command.startsNewGroup {
                stack.addArrangedSubview(makeDivider())
            }
            let button = makeButton(for: command)
            buttons[command] = button
            stack.addArrangedSubview(button)
        }
        stack.addArrangedSubview(NSView())

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func makeButton(for command: Command) -> NSButton {
        let button = NSButton()
        button.bezelStyle = .smallSquare
        button.isBordered = false
        button.imagePosition = .imageAbove
        button.image = NSImage(systemSymbolName: command.symbol, accessibilityDescription: command.title)
        button.image?.isTemplate = true
        button.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 18, weight: .regular)
        button.title = command.title
        button.font = .systemFont(ofSize: 10)
        button.target = self
        button.action = #selector(buttonTapped(_:))
        button.tag = Command.allCases.firstIndex(of: command) ?? 0
        button.toolTip = command.title
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 58).isActive = true
        button.heightAnchor.constraint(equalToConstant: 52).isActive = true
        return button
    }

    private func makeDivider() -> NSView {
        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        divider.widthAnchor.constraint(equalToConstant: 1).isActive = true
        divider.heightAnchor.constraint(equalToConstant: 32).isActive = true
        let holder = NSView()
        holder.translatesAutoresizingMaskIntoConstraints = false
        holder.addSubview(divider)
        NSLayoutConstraint.activate([
            holder.widthAnchor.constraint(equalToConstant: 11),
            divider.centerXAnchor.constraint(equalTo: holder.centerXAnchor),
            divider.centerYAnchor.constraint(equalTo: holder.centerYAnchor),
        ])
        return holder
    }

    @objc private func buttonTapped(_ sender: NSButton) {
        guard sender.tag < Command.allCases.count else { return }
        onCommand?(Command.allCases[sender.tag])
    }

    func setEnabled(_ enabled: Bool, for command: Command) {
        buttons[command]?.isEnabled = enabled
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.separatorColor.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
    }
}
