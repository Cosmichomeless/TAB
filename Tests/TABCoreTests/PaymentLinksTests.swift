import Foundation
import Testing
@testable import TABCore

@Suite("Payment links")
struct PaymentLinksTests {
    @Test func payPalLinkCarriesTheAmountAndCurrency() {
        let url = PaymentLinks.payPal(handle: "ana.lopez", amountMinor: 1250, currency: .eur)
        #expect(url?.absoluteString == "https://paypal.me/ana.lopez/12.50EUR")
        #expect(PaymentLinks.payPal(handle: "ana", amountMinor: 3000, currency: .jpy)?.absoluteString == "https://paypal.me/ana/3000JPY")
    }

    @Test func handlesAcceptPastedLinksAndAtSigns() {
        #expect(PaymentLinks.payPal(handle: "https://www.paypal.me/ana", amountMinor: 100, currency: .usd)?.absoluteString
                == "https://paypal.me/ana/1.00USD")
        #expect(PaymentLinks.payPal(handle: "@ana", amountMinor: 100, currency: .usd)?.absoluteString == "https://paypal.me/ana/1.00USD")
        #expect(PaymentLinks.revolut(tag: "@ana1")?.absoluteString == "https://revolut.me/ana1")
        #expect(PaymentLinks.revolut(tag: "https://revolut.me/ana1/")?.absoluteString == "https://revolut.me/ana1")
    }

    @Test func unsafeOrEmptyHandlesProduceNoLink() {
        #expect(PaymentLinks.payPal(handle: "", amountMinor: 100, currency: .eur) == nil)
        #expect(PaymentLinks.payPal(handle: "ana?x=1", amountMinor: 100, currency: .eur) == nil)
        #expect(PaymentLinks.payPal(handle: "a b", amountMinor: 100, currency: .eur) == nil)
        #expect(PaymentLinks.payPal(handle: "ana", amountMinor: 0, currency: .eur) == nil)
        #expect(PaymentLinks.revolut(tag: "  ") == nil)
    }

    @Test func ibanIsCheckedAndFormatted() {
        #expect(PaymentLinks.normalizedIBAN("es91 2100 0418 4502 0005 1332") == "ES9121000418450200051332")
        #expect(PaymentLinks.normalizedIBAN("ES9121000418450200051333") == nil)
        #expect(PaymentLinks.normalizedIBAN("hello") == nil)
        #expect(PaymentLinks.spacedIBAN("ES9121000418450200051332") == "ES91 2100 0418 4502 0005 1332")
    }

    @Test func emptyHandlesAreEmpty() {
        #expect(PaymentHandles().isEmpty)
        #expect(PaymentHandles(bizumPhone: "").isEmpty)
        #expect(!PaymentHandles(iban: "ES91").isEmpty)
    }
}
