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

@Suite("Amounts with thousands separators")
struct ThousandsSeparatorTests {
    private static let english = Locale(identifier: "en_US")
    private static let spanish = Locale(identifier: "es_ES")
    private static let german = Locale(identifier: "de_DE")
    private static let french = Locale(identifier: "fr_FR")

    @Test func bothSeparatorsMeanTheLastOneIsDecimalWhateverTheLocale() {
        for locale in [Self.english, Self.spanish, Self.german, Self.french] {
            #expect(Currency.eur.parse(minorUnits: "1.234,50", locale: locale) == 123_450)
            #expect(Currency.eur.parse(minorUnits: "1,234.50", locale: locale) == 123_450)
            #expect(Currency.eur.parse(minorUnits: "1.234.567,89", locale: locale) == 123_456_789)
            #expect(Currency.usd.parse(minorUnits: "1,234,567.89", locale: locale) == 123_456_789)
        }
    }

    @Test func aRepeatedSeparatorCanOnlyBeGrouping() {
        for locale in [Self.english, Self.spanish] {
            #expect(Currency.eur.parse(minorUnits: "1.234.567", locale: locale) == 123_456_700)
            #expect(Currency.eur.parse(minorUnits: "1,234,567", locale: locale) == 123_456_700)
            #expect(Currency.jpy.parse(minorUnits: "1,234,567", locale: locale) == 1_234_567)
        }
    }

    @Test func aSingleSeparatorBeforeThreeDigitsGroupsOnlyWhenItIsTheLocalesGroupingSeparator() {
        #expect(Currency.eur.parse(minorUnits: "1.234", locale: Self.spanish) == 123_400)
        #expect(Currency.eur.parse(minorUnits: "1.234", locale: Self.german) == 123_400)
        #expect(Currency.eur.parse(minorUnits: "1,234", locale: Self.english) == 123_400)
        #expect(Currency.jpy.parse(minorUnits: "1.234", locale: Self.spanish) == 1_234)
        #expect(Currency.jpy.parse(minorUnits: "1,234", locale: Self.english) == 1_234)
    }

    @Test func anAmbiguousSeparatorIsRejectedInsteadOfGuessed() {
        // "1.234" on an English keyboard is not 1 234 euros: it is a decimal with too many digits.
        #expect(Currency.eur.parse(minorUnits: "1.234", locale: Self.english) == nil)
        #expect(Currency.eur.parse(minorUnits: "1,234", locale: Self.spanish) == nil)
        #expect(Currency.eur.parse(minorUnits: "1,234", locale: Self.german) == nil)
        #expect(Currency.jpy.parse(minorUnits: "1.234", locale: Self.english) == nil)
        #expect(Currency.eur.parse(minorUnits: "1.234", locale: Self.french) == nil)
    }

    @Test func decimalsStillWorkWithTwoDigitsInAnyLocale() {
        for locale in [Self.english, Self.spanish, Self.german, Self.french] {
            #expect(Currency.eur.parse(minorUnits: "12.50", locale: locale) == 1_250)
            #expect(Currency.eur.parse(minorUnits: "12,50", locale: locale) == 1_250)
            #expect(Currency.eur.parse(minorUnits: "0,05", locale: locale) == 5)
            #expect(Currency.eur.parse(minorUnits: "999.99", locale: locale) == 99_999)
        }
    }

    @Test(arguments: [" ", "\u{00A0}", "\u{202F}", "\u{2009}", "'", "\u{2019}"])
    func spacesAndApostrophesGroupThousands(separator: String) {
        #expect(Currency.eur.parse(minorUnits: "1\(separator)234,50", locale: Self.french) == 123_450)
        #expect(Currency.eur.parse(minorUnits: "1\(separator)234.50", locale: Self.english) == 123_450)
        #expect(Currency.eur.parse(minorUnits: "12\(separator)345\(separator)678", locale: Self.english) == 1_234_567_800)
        #expect(Currency.jpy.parse(minorUnits: "1\(separator)234", locale: Self.english) == 1_234)
    }

    @Test(arguments: [
        "1.23.456", "12.345.67", "1,2345", "01.234", "0.123", "1.234,5.6", "1,.5", ".,5", "1 2 3", "1  234",
        "1,234,", "1.234.", ",", "1 234 56", "1.2345.678", "1.234,567", "12 345,678", "-1.234,50", "1.234,50 €",
        "1.234,5e1", "1,234.50.60", "١٢٣"
    ])
    func rejectsMalformedGrouping(text: String) {
        for locale in [Self.english, Self.spanish] {
            #expect(Currency.eur.parse(minorUnits: text, locale: locale) == nil)
        }
    }

    @Test func theEditableTextOfAnAmountAlwaysParsesBackWhateverTheLocale() {
        for locale in [Self.english, Self.spanish, Self.german, Self.french] {
            for minor in [Int64(0), 5, 100, 123_456, 100_000_000, 123_456_789] {
                #expect(Currency.eur.parse(minorUnits: Currency.eur.input(minorUnits: minor), locale: locale) == minor)
                #expect(Currency.jpy.parse(minorUnits: Currency.jpy.input(minorUnits: minor), locale: locale) == minor)
            }
        }
    }

    @Test func overflowIsRejected() {
        #expect(Currency.eur.parse(minorUnits: "99.999.999.999.999.999.999", locale: Self.spanish) == nil)
    }
}
