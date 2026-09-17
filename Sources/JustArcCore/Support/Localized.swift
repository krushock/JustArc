import Foundation

/// Looks a string up in the app bundle, using the English text as the key so an
/// untranslated string still reads correctly rather than showing a token.
///
/// Explicit arities are used instead of a variadic so that `L("plain text")` is never
/// ambiguous with the formatting overloads.
public func L(_ key: String) -> String {
    LocalizationBundle.current.localizedString(forKey: key, value: key, table: nil)
}

public func L(_ key: String, _ first: CVarArg) -> String {
    String(format: L(key), arguments: [first])
}

public func L(_ key: String, _ first: CVarArg, _ second: CVarArg) -> String {
    String(format: L(key), arguments: [first, second])
}

public func L(_ key: String, _ first: CVarArg, _ second: CVarArg, _ third: CVarArg) -> String {
    String(format: L(key), arguments: [first, second, third])
}

public enum LocalizationBundle {
    /// The main bundle when running inside JustArc.app. Tests run without one, and
    /// then every lookup falls through to the key, which is the English text.
    public static var current: Bundle = .main
}
