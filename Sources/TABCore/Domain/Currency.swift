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

    /// Parses user input such as "12.5" or "12,50" into minor units. Returns `nil` for anything that is
    /// not a plain positive decimal with at most `minorUnitDigits` decimals.
    public func parse(minorUnits text: String) -> Int64? {
        let normalized = text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let parts = normalized.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count <= 2, let whole = parts.first, !whole.isEmpty,
              whole.allSatisfy(\.isASCII), whole.allSatisfy(\.isNumber) else { return nil }
        let fraction = parts.count == 2 ? String(parts[1]) : ""
        guard fraction.count <= minorUnitDigits, fraction.allSatisfy(\.isASCII), fraction.allSatisfy(\.isNumber) else {
            return nil
        }
        let padded = fraction.padding(toLength: minorUnitDigits, withPad: "0", startingAt: 0)
        guard let value = Int64(whole + padded) else { return nil }
        return value
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
