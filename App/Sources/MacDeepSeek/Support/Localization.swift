import Foundation

/// The languages of the interface. The texts in the code are Dutch; `Translations` has the others.
enum AppLanguage: String, CaseIterable, Identifiable {
    case nl, en, de, fr
    var id: String { rawValue }
    var name: String {
        switch self {
        case .nl: return "Nederlands"
        case .en: return "English"
        case .de: return "Deutsch"
        case .fr: return "Français"
        }
    }

    /// The first of the Mac's preferred languages that the app has, else English.
    static var system: AppLanguage {
        for id in Locale.preferredLanguages {
            if let l = AppLanguage(rawValue: String(id.prefix(2))) { return l }
        }
        return .en
    }

    static var current: AppLanguage { AppLanguage(rawValue: Settings.shared.language) ?? .system }
}

/// A text with its values: the key is the Dutch text with %@ for each value ("\(n) lagen" -> "%@ lagen").
struct Loc: ExpressibleByStringInterpolation {
    var key = ""
    var args: [String] = []

    init(stringLiteral value: String) { key = value }
    init(stringInterpolation i: Interpolation) { key = i.key; args = i.args }

    struct Interpolation: StringInterpolationProtocol {
        var key = ""
        var args: [String] = []
        init(literalCapacity: Int, interpolationCount: Int) {}
        mutating func appendLiteral(_ literal: String) { key += literal.replacingOccurrences(of: "%", with: "%%") }
        mutating func appendInterpolation<T>(_ value: T) { key += "%@"; args.append(String(describing: value)) }
        mutating func appendInterpolation(_ value: Double, specifier: String) { key += "%@"; args.append(String(format: specifier, value)) }
        mutating func appendInterpolation(_ value: Int, specifier: String) { key += "%@"; args.append(String(format: specifier, value)) }
    }
}

/// The text in the chosen language. A translation may reorder the values with %1$@, %2$@.
func L(_ text: Loc) -> String {
    let lang = AppLanguage.current
    let template = lang == .nl ? text.key : (Translations.table[lang.rawValue]?[text.key] ?? text.key)
    var out = ""
    var next = 0
    var i = template.startIndex
    while i < template.endIndex {
        let c = template[i]
        guard c == "%" else { out.append(c); i = template.index(after: i); continue }
        let rest = template[template.index(after: i)...]
        if rest.hasPrefix("%") {
            out.append("%")
            i = template.index(i, offsetBy: 2)
        } else if rest.hasPrefix("@") {
            out += next < text.args.count ? text.args[next] : ""
            next += 1
            i = template.index(i, offsetBy: 2)
        } else if let d = rest.first, d.isNumber, rest.dropFirst().hasPrefix("$@"), let n = Int(String(d)) {
            out += n - 1 < text.args.count ? text.args[n - 1] : ""
            i = template.index(i, offsetBy: 4)
        } else {
            out.append(c)
            i = template.index(after: i)
        }
    }
    return out
}

/// A text that is only known at run time (a model's summary from models.json, a stored default title).
func L(key: String) -> String {
    let lang = AppLanguage.current
    return lang == .nl ? key : (Translations.table[lang.rawValue]?[key.replacingOccurrences(of: "%", with: "%%")]?.replacingOccurrences(of: "%%", with: "%") ?? key)
}
