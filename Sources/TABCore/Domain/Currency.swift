import Foundation

/// An ISO 4217 currency and the number of digits of its minor unit.
public struct Currency: Hashable, Sendable {
    public let code: String
    public let minorUnitDigits: Int

    public static let eur = Currency(uncheckedCode: "EUR", minorUnitDigits: 2)
    public static let usd = Currency(uncheckedCode: "USD", minorUnitDigits: 2)
    public static let gbp = Currency(uncheckedCode: "GBP", minorUnitDigits: 2)
    public static let jpy = Currency(uncheckedCode: "JPY", minorUnitDigits: 0)

    public static let supported: [Currency] = [.eur, .usd, .gbp, .jpy]

    /// Formats an amount in minor units, e.g. `1050` EUR becomes "€10.50".
    public func format(minorUnits: Int64) -> String {
        let amount = Decimal(minorUnits) / pow(10, minorUnitDigits)
        return amount.formatted(.currency(code: code))
    }

    /// Plain decimal for an editable amount field, independent of device locale.
    public func input(minorUnits: Int64) -> String {
        guard minorUnitDigits > 0 else { return String(minorUnits) }
        let scale = (0..<minorUnitDigits).reduce(Int64(1)) { value, _ in value * 10 }
        return String(minorUnits / scale) + "." + String(minorUnits % scale).leftPadded(to: minorUnitDigits)
    }

    /// Parses user input such as "12.5", "12,50", "1.234,50" or "1,234.50" into minor units. Returns `nil` for
    /// anything that is not a plain positive amount with at most `minorUnitDigits` decimals.
    ///
    /// - When both separators appear, the last one is the decimal separator and the other groups thousands.
    /// - A separator that appears more than once groups thousands ("1.234.567").
    /// - A single separator followed by exactly three digits ("1.234") is ambiguous. It groups thousands only
    ///   when it is the grouping separator of `locale`, and only for currencies with fewer than three
    ///   decimals; otherwise it is read as a decimal point, which these currencies cannot hold, so it is
    ///   rejected instead of guessed. That way "1.234" typed in an English keyboard never silently becomes 1 234.
    /// - Spaces (including no-break spaces) and apostrophes can group thousands too ("1 234,50").
    /// - Groups must be well formed: one to three digits, then groups of exactly three, no leading zero.
    public func parse(minorUnits text: String, locale: Locale = .current) -> Int64? {
        let text = text.trimmingCharacters(in: .whitespaces)
        let dots = text.filter { $0 == "." }.count
        let commas = text.filter { $0 == "," }.count
        var whole = text
        var fraction = ""

        if dots > 0 && commas > 0 {
            guard let last = text.lastIndex(where: { $0 == "." || $0 == "," }) else { return nil }
            let decimal = text[last]
            guard text.filter({ $0 == decimal }).count == 1 else { return nil }
            whole = String(text[..<last])
            fraction = String(text[text.index(after: last)...])
        } else if dots + commas > 0 {
            let separator: Character = dots > 0 ? "." : ","
            let parts = text.split(separator: separator, omittingEmptySubsequences: false)
            if parts.count > 2 {
                // Several of the same separator can only be grouping; the groups are checked below.
            } else if parts.count == 2 {
                let groupsThousands = parts[1].count == 3 && minorUnitDigits < 3
                    && locale.groupingSeparator == String(separator) && Currency.groupedDigits(text) != nil
                if !groupsThousands {
                    whole = String(parts[0])
                    fraction = String(parts[1])
                }
            }
        }

        guard let integer = Currency.groupedDigits(whole) else { return nil }
        guard fraction.count <= minorUnitDigits, fraction.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        let padded = fraction.padding(toLength: minorUnitDigits, withPad: "0", startingAt: 0)
        return Int64(integer + padded)
    }

    /// The digits of `text` when it is plain digits or digits grouped by one separator ("1.234.567",
    /// "1 234"), `nil` when it is empty, has stray characters or malformed groups.
    private static func groupedDigits(_ text: String) -> String? {
        let groupingCharacters: Set<Character> = [".", ",", " ", "\u{00A0}", "\u{202F}", "\u{2009}", "'", "\u{2019}"]
        let used = Set(text.filter { groupingCharacters.contains($0) })
        func isDigits(_ part: Substring) -> Bool { !part.isEmpty && part.allSatisfy { $0.isASCII && $0.isNumber } }
        guard let separator = used.first else { return isDigits(text[...]) ? text : nil }
        guard used.count == 1 else { return nil }
        let groups = text.split(separator: separator, omittingEmptySubsequences: false)
        guard groups.count > 1, groups.allSatisfy(isDigits),
              (1...3).contains(groups[0].count), groups[0].first != "0",
              groups.dropFirst().allSatisfy({ $0.count == 3 }) else { return nil }
        return groups.joined()
    }

    private init(uncheckedCode: String, minorUnitDigits: Int) {
        self.code = uncheckedCode
        self.minorUnitDigits = minorUnitDigits
    }

    /// Returns the supported currency with the given code, or `nil` when it is not supported.
    public init?(code: String) {
        guard let match = Currency.supported.first(where: { $0.code == code.uppercased() }) else {
            return nil
        }
        self = match
    }
}

private extension String {
    func leftPadded(to width: Int) -> String {
        String(repeating: "0", count: max(0, width - count)) + self
    }
}

extension Currency: Codable {
    public init(from decoder: Decoder) throws {
        let code = try decoder.singleValueContainer().decode(String.self)
        guard let currency = Currency(code: code) else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: decoder.codingPath, debugDescription: "Unsupported currency \(code)")
            )
        }
        self = currency
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(code)
    }
}
