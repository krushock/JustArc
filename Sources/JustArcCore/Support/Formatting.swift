import Foundation

public enum Formatting {
    private static let byteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.countStyle = .file
        f.allowsNonnumericFormatting = false
        return f
    }()

    private static let decimalFormatter: NumberFormatter = {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        return f
    }()

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f
    }()

    public static func bytes(_ value: UInt64) -> String {
        byteFormatter.string(fromByteCount: Int64(clamping: value))
    }

    /// WinRAR shows exact byte counts in list columns, with thousands separators.
    public static func exactBytes(_ value: UInt64) -> String {
        decimalFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    public static func count(_ value: Int) -> String {
        decimalFormatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    public static func date(_ value: Date?) -> String {
        guard let value else { return "" }
        return dateFormatter.string(from: value)
    }

    public static func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    public static func ratio(size: UInt64, packed: UInt64) -> String {
        guard size > 0 else { return "" }
        return "\(Int((Double(packed) / Double(size) * 100).rounded()))%"
    }

    public static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "" }
        let total = Int(seconds.rounded())
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
        }
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
