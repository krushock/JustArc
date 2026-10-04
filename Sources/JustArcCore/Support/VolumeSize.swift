import Foundation

/// Parses the split-volume sizes people type into the Save panel into the spec
/// 7-Zip and RAR both understand: a number followed by b, k, m or g.
public enum VolumeSize {
    public struct Preset: Sendable, Hashable {
        public let title: String
        /// nil means "do not split".
        public let spec: String?

        public init(title: String, spec: String?) {
            self.title = title
            self.spec = spec
        }
    }

    public static let presets: [Preset] = [
        Preset(title: L("Do not split"), spec: nil),
        Preset(title: L("100 MB"), spec: "100m"),
        Preset(title: L("700 MB (CD)"), spec: "700m"),
        Preset(title: L("1 GB"), spec: "1g"),
        Preset(title: L("4480 MB (DVD)"), spec: "4480m"),
    ]

    /// Accepts "100m", "100 MB", "1.5 GB", "700" and so on. Returns nil when the text
    /// means "do not split" and throws nothing: unparseable input is simply nil.
    public static func normalize(_ raw: String) -> String? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !text.isEmpty else { return nil }
        if let preset = presets.first(where: { $0.title.lowercased() == text }) { return preset.spec }
        if text == "none" || text == "no" { return nil }

        var digits = ""
        var unit = ""
        for character in text {
            if character.isNumber || character == "." {
                guard unit.isEmpty else { return nil }
                digits.append(character)
            } else if character.isLetter {
                unit.append(character)
            } else if character == " " {
                continue
            } else {
                return nil
            }
        }

        // No volume is an exabyte; larger numbers are typing accidents, and would
        // not fit the integer the spec is written with.
        guard let value = Double(digits), value > 0, value < 1e15 else { return nil }

        let suffix: String
        switch unit {
        case "", "b": suffix = "b"
        case "k", "kb", "kib": suffix = "k"
        case "m", "mb", "mib": suffix = "m"
        case "g", "gb", "gib": suffix = "g"
        default: return nil
        }

        // Fractional sizes are scaled down a unit so the spec stays an integer.
        if value != value.rounded() {
            switch suffix {
            case "g": return "\(Int((value * 1024).rounded()))m"
            case "m": return "\(Int((value * 1024).rounded()))k"
            case "k": return "\(Int((value * 1024).rounded()))b"
            default: return "\(Int(value.rounded()))b"
            }
        }
        return "\(Int(value))\(suffix)"
    }
}
