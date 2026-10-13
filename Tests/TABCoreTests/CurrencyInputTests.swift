import Foundation
import Testing
@testable import TABCore

@Suite("Editable amounts")
struct CurrencyInputTests {
    @Test func editedAmountCanBeShownInAnEditableFieldWithoutCurrencySymbols() {
        #expect(Currency.eur.input(minorUnits: 1234) == "12.34")
        #expect(Currency.eur.input(minorUnits: 1200) == "12.00")
        #expect(Currency.jpy.input(minorUnits: 1234) == "1234")
        #expect(Currency.eur.parse(minorUnits: Currency.eur.input(minorUnits: 1234)) == 1234)
    }
}
