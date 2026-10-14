import Foundation

/// A plain-text summary of who owes whom, to paste into a chat. It uses the same suggested payments as the
/// group screen (`BalanceCalculator.settlements`), so the message and the app never disagree.
public enum SettlementText {
    /// The wording around the names and amounts, so the app can pass localized text.
    public struct Phrases: Sendable {
        public var title: @Sendable (_ group: String) -> String
        public var payment: @Sendable (_ from: String, _ to: String, _ amount: String) -> String
        public var settled: String

        public init(
            title: @escaping @Sendable (String) -> String,
            payment: @escaping @Sendable (String, String, String) -> String,
            settled: String
        ) {
            self.title = title
            self.payment = payment
            self.settled = settled
        }

        public static let english = Phrases(
            title: { "\($0) – who owes whom" },
            payment: { "\($0) owes \($1) \($2)" },
            settled: "Everyone is settled up."
        )
    }

    public static func text(for snapshot: GroupSnapshot, phrases: Phrases = .english) -> String {
        let names = Dictionary(snapshot.participants.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let balances = snapshot.computedBalances().map { Balance(userID: $0.userID, netMinor: $0.netMinor) }
        let payments = BalanceCalculator.settlements(for: balances)

        var lines = [phrases.title(snapshot.group.name)]
        if payments.isEmpty {
            lines.append(phrases.settled)
        } else {
            for payment in payments {
                lines.append(phrases.payment(
                    names[payment.from] ?? "?", names[payment.to] ?? "?",
                    snapshot.group.currency.format(minorUnits: payment.amountMinor)
                ))
            }
        }
        return lines.joined(separator: "\n")
    }
}
