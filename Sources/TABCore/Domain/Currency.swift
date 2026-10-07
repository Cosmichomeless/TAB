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
