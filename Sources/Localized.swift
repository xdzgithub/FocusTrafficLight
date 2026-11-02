import Foundation

/// Menu and alert text, resolved against the user's language.
///
/// A menu-bar app has no nib to localise, so the strings live in
/// `Resources/<lang>.lproj/Localizable.strings` and are looked up here. Chinese
/// is bundled because the app's users are, but English stays the development
/// region so a machine set to any other language still gets readable text
/// rather than raw keys.
///
/// The comment format matters: `NSLocalizedString` only finds a string when the
/// key exists in the table for the active language, and the table name is
/// inferred from the calling code's module. Passing `comment` alone is enough
/// here because the keys carry their own meaning.
enum Localized {

    /// The table every lookup uses. Kept in one place so a missing file fails
    /// loudly at the first menu build rather than halfway through the menu.
    private static let table = "Localizable"

    static func string(_ key: String, _ arguments: CVarArg...) -> String {
        let format = Bundle.main.localizedString(forKey: key, value: nil, table: table)
        guard !arguments.isEmpty else { return format }
        return String(format: format, locale: Locale.current, arguments: arguments)
    }
}
