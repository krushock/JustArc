import Foundation

/// Puts what the 7-Zip bridge reports into the app's language.
///
/// The bridge is C++ and reports in English, in a handful of fixed shapes. The
/// English originals appear here as the keys they are matched by, never as text
/// anyone is shown, which is why the strings script does not lint this file.
extension BridgeError {

    /// The bridge reports in English, in a handful of fixed shapes. This puts them
    /// into the app's language; anything it does not recognise passes through.
    static func localized(_ message: String) -> String {
        if let whole = sentences[message] { return whole }

        // What the bridge says of its own accord, with the reason after the colon.
        let statements: [(prefix: String, format: (String) -> String)] = [
            ("7-Zip could not write the archive: ", { why in L("The archive could not be written: %@.", reason(why)) }),
            ("The format rejected a setting: ", { why in L("The format rejected a setting: %@.", reason(why)) }),
        ]
        for statement in statements where message.hasPrefix(statement.prefix) {
            return statement.format(String(message.dropFirst(statement.prefix.count)))
        }

        // "path/in/archive: what went wrong", from an item that failed. Looked for
        // before the shapes below, because an item can be called anything, "Cannot
        // open the door.txt" included, and what gives it away is the reason, which
        // is always one of a few. The name may hold a colon of its own, so every
        // colon is tried, and the first with a reason after it is the one.
        var search = message.startIndex..<message.endIndex
        while let colon = message.range(of: ": ", range: search) {
            let why = String(message[colon.upperBound...])
            if reasons[why] != nil || reasons.keys.contains(where: { why.hasPrefix($0 + ": ") }) {
                return L("%@ could not be extracted: %@.", String(message[..<colon.lowerBound]), reason(why))
            }
            search = colon.upperBound..<message.endIndex
        }

        let shapes: [(prefix: String, format: (String, String) -> String)] = [
            ("Is not an archive: ", { path, _ in L("%@ is not an archive JustArc can read.", name(path)) }),
            ("Cannot open ", { path, why in L("%@ could not be opened. %@", name(path), sentence(why)) }),
            ("Cannot read the link ", { path, _ in L("The link %@ could not be read.", name(path)) }),
            ("Cannot read ", { path, why in L("%@ could not be read. %@", name(path), sentence(why)) }),
            ("Cannot create ", { path, why in L("%@ could not be created. %@", name(path), sentence(why)) }),
        ]
        for shape in shapes where message.hasPrefix(shape.prefix) {
            let rest = String(message.dropFirst(shape.prefix.count))
            // "path: reason", split at the last colon since a path may hold one.
            if let colon = rest.range(of: ": ", options: .backwards) {
                return shape.format(String(rest[..<colon.lowerBound]), String(rest[colon.upperBound...]))
            }
            return shape.format(rest, "")
        }
        return reasons[message] ?? message
    }

    private static func name(_ path: String) -> String {
        (path as NSString).lastPathComponent
    }

    /// A system error text, made a sentence of.
    private static func sentence(_ text: String) -> String {
        guard let first = text.first else { return "" }
        let capitalised = first.uppercased() + text.dropFirst()
        return capitalised.hasSuffix(".") ? capitalised : capitalised + "."
    }

    /// A reason clause, which may end in the system's own words after a colon.
    private static func reason(_ text: String) -> String {
        if let known = reasons[text] { return known }
        if let colon = text.range(of: ": "), let known = reasons[String(text[..<colon.lowerBound])] {
            return known + ": " + text[colon.upperBound...]
        }
        return text
    }

    private static let sentences: [String: String] = [
        "The operation was cancelled.": L("The operation was cancelled."),
        "Nothing to extract from.": L("There is nothing to extract from."),
        "Nowhere to write the archive.": L("There is nowhere to write the archive."),
        "The 7-Zip library is missing its entry points.": L("The 7-Zip library is damaged. Reinstall JustArc."),
        "The 7-Zip library is not loaded.": L("The 7-Zip library is not loaded."),
        "This archive is password protected.": L("This archive is password protected."),
        "The password is incorrect.": L("The password is incorrect."),
        "7-Zip could not create a writer for this format.": L("7-Zip cannot write this format."),
        "This format takes no settings.": L("This format takes no settings."),
        "The archive could not be finished on disk.": L("The archive could not be finished on disk."),
        "The destination folder could not be created.": L("The destination folder could not be created."),
        "The disk could not take the file being written. It may be full.":
            L("The disk could not take the file being written. It may be full."),
    ]

    private static let reasons: [String: String] = [
        "the data is damaged": L("the data is damaged"),
        "its checksum does not match": L("its checksum does not match"),
        "the archive ends too soon": L("the archive ends too soon"),
        "the archive's headers are damaged": L("the archive's headers are damaged"),
        "part of its data is missing": L("part of its data is missing"),
        "it uses a compression method 7-Zip cannot decode": L("it uses a compression method 7-Zip cannot decode"),
        "could not finish writing the file": L("the file could not be finished"),
        "its path is longer than macOS allows": L("its path is longer than macOS allows"),
        "could not create a folder": L("a folder could not be created"),
        "could not create a hard link": L("a hard link could not be created"),
        "could not create a link": L("a link could not be created"),
        "could not create the file": L("the file could not be created"),
        "could not move the file into place": L("the file could not be moved into place"),
        "could not rename the existing item": L("the existing item could not be renamed"),
        "could not replace the existing file": L("the existing file could not be replaced"),
        "no error": L("no error"),
        "the data is not in this format": L("the data is not in this format"),
        "the operation was stopped": L("the operation was stopped"),
        "there was not enough memory": L("there was not enough memory"),
        "the format does not support this": L("the format does not support this"),
        "the format rejected a setting": L("the format rejected a setting"),
    ]
}
