import AppKit
import JustArcCore

/// The small progress panel WinRAR shows while it works: a bar, elapsed and
/// remaining time, the current file, and a cancel button.
@MainActor
final class ProgressWindowController: NSWindowController {
    private let titleLabel = NSTextField(labelWithString: "")
    private let bar = NSProgressIndicator()
    private let percentLabel = NSTextField(labelWithString: "0%")
    private let elapsedLabel = NSTextField(labelWithString: "0:00")
    private let remainingLabel = NSTextField(labelWithString: "--:--")
    private let fileLabel = NSTextField(labelWithString: "")
    private let cancelButton = NSButton(title: "Cancel", target: nil, action: nil)

    private let cancellation: CancellationToken
    private let startDate = Date()
    private var ticker: Timer?
    private var lastFraction: Double = 0

    var onCancel: (() -> Void)?

    init(title: String, cancellation: CancellationToken) {
        self.cancellation = cancellation

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 430, height: 190),
                              styleMask: [.titled, .closable],
                              backing: .buffered,
                              defer: false)
        window.title = "JustArc"
        window.isReleasedWhenClosed = false
        window.center()
        super.init(window: window)

        titleLabel.stringValue = title
        buildLayout()
        startTicking()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("not supported") }

    private func buildLayout() {
        guard let content = window?.contentView else { return }

        titleLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingMiddle

        bar.isIndeterminate = true
        bar.style = .bar
        bar.minValue = 0
        bar.maxValue = 1
        bar.startAnimation(nil)

        percentLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        percentLabel.alignment = .right
        percentLabel.textColor = .secondaryLabelColor

        fileLabel.font = .systemFont(ofSize: 11)
        fileLabel.textColor = .secondaryLabelColor
        fileLabel.lineBreakMode = .byTruncatingMiddle

        for label in [elapsedLabel, remainingLabel] {
            label.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
            label.textColor = .secondaryLabelColor
        }

        let elapsedRow = labelledRow("Elapsed time", elapsedLabel)
        let remainingRow = labelledRow("Time left", remainingLabel)

        cancelButton.target = self
        cancelButton.action = #selector(cancelPressed)
        cancelButton.keyEquivalent = "\u{1b}"

        let barRow = NSStackView(views: [bar, percentLabel])
        barRow.orientation = .horizontal
        barRow.spacing = 8
        percentLabel.setContentHuggingPriority(.required, for: .horizontal)
        percentLabel.widthAnchor.constraint(equalToConstant: 38).isActive = true

        let buttonRow = NSStackView(views: [NSView(), cancelButton])
        buttonRow.orientation = .horizontal

        let stack = NSStackView(views: [titleLabel, barRow, elapsedRow, remainingRow, fileLabel, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
            barRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttonRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            titleLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
            fileLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    private func labelledRow(_ caption: String, _ value: NSTextField) -> NSStackView {
        let captionLabel = NSTextField(labelWithString: caption)
        captionLabel.font = .systemFont(ofSize: 11)
        captionLabel.textColor = .secondaryLabelColor
        captionLabel.widthAnchor.constraint(equalToConstant: 90).isActive = true
        let row = NSStackView(views: [captionLabel, value])
        row.orientation = .horizontal
        row.spacing = 8
        return row
    }

    private func startTicking() {
        ticker = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshTimes() }
        }
    }

    private func refreshTimes() {
        let elapsed = Date().timeIntervalSince(startDate)
        elapsedLabel.stringValue = Formatting.duration(elapsed)
        if lastFraction > 0.02, elapsed > 1 {
            let total = elapsed / lastFraction
            remainingLabel.stringValue = Formatting.duration(max(total - elapsed, 0))
        }
    }

    func update(_ progress: ArchiveProgress) {
        if let fraction = progress.fraction {
            if bar.isIndeterminate {
                bar.stopAnimation(nil)
                bar.isIndeterminate = false
            }
            lastFraction = fraction
            bar.doubleValue = fraction
            percentLabel.stringValue = Formatting.percent(fraction)
        }
        if let file = progress.currentFile {
            fileLabel.stringValue = file
        }
    }

    func setTitle(_ text: String) {
        titleLabel.stringValue = text
    }

    @objc private func cancelPressed() {
        cancelButton.isEnabled = false
        cancelButton.title = "Cancelling…"
        cancellation.cancel()
        onCancel?()
    }

    func finish() {
        ticker?.invalidate()
        ticker = nil
        close()
    }
}
