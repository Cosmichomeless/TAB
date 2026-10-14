import Foundation

/// How someone can be paid outside TAB. Kept on this iPhone only: it is never part of a shared group, a backup
/// or a sync, so a phone number or an IBAN does not travel with a QR code.
public struct PaymentHandles: Codable, Equatable, Sendable {
    public var bizumPhone: String?
    public var payPalMe: String?
    public var revolutTag: String?
    public var iban: String?

    public init(bizumPhone: String? = nil, payPalMe: String? = nil, revolutTag: String? = nil, iban: String? = nil) {
        self.bizumPhone = bizumPhone
        self.payPalMe = payPalMe
        self.revolutTag = revolutTag
        self.iban = iban
    }

    public var isEmpty: Bool { [bizumPhone, payPalMe, revolutTag, iban].allSatisfy { ($0 ?? "").isEmpty } }
}

/// Links that open another app or website with the payment prepared. TAB never moves money itself.
public enum PaymentLinks {
    /// `https://paypal.me/<name>/<amount><currency>`, which opens the PayPal app when it is installed.
    public static func payPal(handle: String, amountMinor: Int64, currency: Currency) -> URL? {
        guard let name = cleanHandle(handle, hosts: ["paypal.me"]), amountMinor > 0 else { return nil }
        let amount = currency.input(minorUnits: amountMinor)
        return URL(string: "https://paypal.me/\(name)/\(amount)\(currency.code)")
    }

    /// `https://revolut.me/<tag>`. Revolut does not document an amount in the link, so the payer types it.
    public static func revolut(tag: String) -> URL? {
        guard let name = cleanHandle(tag, hosts: ["revolut.me"]) else { return nil }
        return URL(string: "https://revolut.me/\(name)")
    }

    /// An IBAN as people write it, without spaces and in capitals. `nil` when it cannot be an IBAN.
    public static func normalizedIBAN(_ text: String) -> String? {
        let iban = text.filter { !$0.isWhitespace }.uppercased()
        guard (15...34).contains(iban.count), iban.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }),
              iban.prefix(2).allSatisfy(\.isLetter), iban.dropFirst(2).prefix(2).allSatisfy(\.isNumber) else { return nil }
        // ISO 7064 mod 97-10: move the first four characters to the end, turn letters into numbers.
        var remainder = 0
        for character in iban.dropFirst(4) + iban.prefix(4) {
            guard let digits = character.isLetter
                ? character.asciiValue.map({ String(Int($0) - 55) })
                : String(character) else { return nil }
            for digit in digits { remainder = (remainder * 10 + Int(String(digit))!) % 97 }
        }
        return remainder == 1 ? iban : nil
    }

    /// The IBAN in groups of four, which is how banks print it.
    public static func spacedIBAN(_ iban: String) -> String {
        stride(from: 0, to: iban.count, by: 4).map { start in
            String(iban.dropFirst(start).prefix(4))
        }.joined(separator: " ")
    }

    /// Accepts "name", "@name" or a pasted link and returns just the name, or `nil` if it is not a safe one.
    static func cleanHandle(_ text: String, hosts: [String]) -> String? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["https://", "http://"] where value.lowercased().hasPrefix(prefix) {
            value.removeFirst(prefix.count)
        }
        for host in hosts {
            for candidate in [host, "www." + host] where value.lowercased().hasPrefix(candidate + "/") {
                value.removeFirst(candidate.count + 1)
            }
        }
        value = String(value.drop { $0 == "@" })
        if let slash = value.firstIndex(of: "/") { value = String(value[..<slash]) }
        guard !value.isEmpty, value.count <= 64,
              value.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "." || $0 == "_" || $0 == "-") })
        else { return nil }
        return value
    }
}
