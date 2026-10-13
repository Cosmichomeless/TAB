import Foundation

/// The ways the expense form offers to divide an amount.
public enum SplitMode: String, CaseIterable, Hashable, Sendable {
    case equal, shares, percentages, exact
}

/// Converts what a person types in the split form into a `SplitMethod`, and the stored shares back into
/// text for editing. Kept out of the views so it can be tested.
public enum SplitInput {
    /// Percentages are typed with up to two decimals and kept as hundredths of a percent.
    private static let percentageParser = Currency.eur

    /// Builds the method for `mode`. In every mode but `equal`, a person whose field is empty or zero is
    /// not taking part; text that is not a number throws `invalidSplitWeight` for that person.
    public static func method(
        mode: SplitMode, participants: [UUID], entries: [UUID: String], currency: Currency
    ) throws -> SplitMethod {
        switch mode {
        case .equal:
            return .equal(among: participants)
        case .shares:
            return .shares(try values(participants, entries) { Int64($0.trimmingCharacters(in: .whitespaces)) })
        case .percentages:
            return .percentages(try values(participants, entries) { percentageParser.parse(minorUnits: $0) })
        case .exact:
            return .exact(try values(participants, entries) { currency.parse(minorUnits: $0) })
        }
    }

    private static func values(
        _ participants: [UUID], _ entries: [UUID: String], parse: (String) -> Int64?
    ) throws -> [UUID: Int64] {
        var result: [UUID: Int64] = [:]
        for id in participants {
            let text = (entries[id] ?? "").trimmingCharacters(in: .whitespaces)
            if text.isEmpty { continue }
            guard let value = parse(text), value >= 0 else { throw DomainError.invalidSplitWeight(id) }
            if value > 0 { result[id] = value }
        }
        return result
    }

    /// `true` when `splits` is what an equal split of `amountMinor` among the same people would store.
    public static func isEqual(_ splits: [ExpenseSplit], amountMinor: Int64) -> Bool {
        guard let equal = try? SplitCalculator.shares(amountMinor: amountMinor, method: .equal(among: splits.map(\.userID)))
        else { return false }
        let stored = Dictionary(uniqueKeysWithValues: splits.map { ($0.userID, $0.amountMinor) })
        return equal.allSatisfy { stored[$0.userID] == $0.amountMinor } && stored.count == equal.count
    }

    /// Text for each field when an existing split is opened in `exact` mode.
    public static func exactEntries(for splits: [ExpenseSplit], currency: Currency) -> [UUID: String] {
        Dictionary(uniqueKeysWithValues: splits.map { ($0.userID, currency.input(minorUnits: $0.amountMinor)) })
    }

    /// What is left to assign, in the unit of `mode`: minor units for `exact`, hundredths of a percent for
    /// `percentages`. `nil` for modes without a fixed total. Invalid fields count as zero.
    public static func remaining(
        mode: SplitMode, amountMinor: Int64, participants: [UUID], entries: [UUID: String], currency: Currency
    ) -> Int64? {
        let parser: Currency
        let target: Int64
        switch mode {
        case .exact: parser = currency; target = amountMinor
        case .percentages: parser = percentageParser; target = SplitMethod.fullPercentage
        case .equal, .shares: return nil
        }
        let assigned = participants.reduce(Int64(0)) { sum, id in
            sum + (parser.parse(minorUnits: entries[id] ?? "") ?? 0)
        }
        return target - assigned
    }
}
