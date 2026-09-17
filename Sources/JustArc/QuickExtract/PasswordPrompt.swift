import AppKit
import JustArcCore

/// Modal password sheet used by both Quick Extract and the browser.
enum PasswordPrompt {
    struct Response {
        let password: String
        let rememberInKeychain: Bool
    }

    @MainActor
    static func ask(archiveName: String,
                    window: NSWindow?,
                    retry: Bool) -> Response? {
        let alert = NSAlert()
        alert.messageText = retry ? L("That password did not work.") : L("Enter the archive password")
        alert.informativeText = retry
            ? L("Check the password for %@ and try again.", archiveName)
            : L("%@ is protected. Enter its password to continue.", archiveName)
        alert.alertStyle = retry ? .warning : .informational
        alert.addButton(withTitle: L("Continue"))
        alert.addButton(withTitle: L("Cancel"))

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 56))

        let secureField = NSSecureTextField(frame: NSRect(x: 0, y: 30, width: 300, height: 22))
        secureField.placeholderString = L("Password")
        let plainField = NSTextField(frame: secureField.frame)
        plainField.placeholderString = L("Password")
        plainField.isHidden = true
        container.addSubview(secureField)
        container.addSubview(plainField)

        let showBox = NSButton(checkboxWithTitle: L("Show password"), target: nil, action: nil)
        showBox.frame = NSRect(x: 0, y: 6, width: 140, height: 18)
        let rememberBox = NSButton(checkboxWithTitle: L("Remember"), target: nil, action: nil)
        rememberBox.frame = NSRect(x: 150, y: 6, width: 150, height: 18)
        rememberBox.toolTip = L("Save this password in your login keychain.")
        container.addSubview(showBox)
        container.addSubview(rememberBox)

        let toggle = ShowPasswordToggle(secure: secureField, plain: plainField)
        showBox.target = toggle
        showBox.action = #selector(ShowPasswordToggle.toggled(_:))

        alert.accessoryView = container
        alert.window.initialFirstResponder = secureField

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return nil }
        let value = plainField.isHidden ? secureField.stringValue : plainField.stringValue
        guard !value.isEmpty else { return nil }
        return Response(password: value, rememberInKeychain: rememberBox.state == .on)
    }
}

/// Keeps the secure and plain fields in sync when "Show password" is toggled.
private final class ShowPasswordToggle: NSObject {
    private let secure: NSSecureTextField
    private let plain: NSTextField
    private static var retained: [ShowPasswordToggle] = []

    init(secure: NSSecureTextField, plain: NSTextField) {
        self.secure = secure
        self.plain = plain
        super.init()
        Self.retained.append(self)
    }

    @objc func toggled(_ sender: NSButton) {
        if sender.state == .on {
            plain.stringValue = secure.stringValue
            plain.isHidden = false
            secure.isHidden = true
            plain.window?.makeFirstResponder(plain)
        } else {
            secure.stringValue = plain.stringValue
            secure.isHidden = false
            plain.isHidden = true
            secure.window?.makeFirstResponder(secure)
        }
    }
}
