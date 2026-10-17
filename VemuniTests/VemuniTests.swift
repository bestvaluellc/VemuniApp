import XCTest
@testable import Vemuni

final class VemuniTests: XCTestCase {
    func testTipCalculationUsesPretaxBase() {
        let receipt = ReceiptAnalysis(
            subtotal: 100, tax: 8.25, serviceCharge: nil,
            serviceChargeLabel: nil, statedTip: nil, total: 108.25,
            tipBase: 100, tipAlreadyIncluded: false,
            possibleDuplicateTipRisk: false, lineItems: []
        )
        XCTAssertEqual(receipt.tipAmount(percent: 20), 20)
        XCTAssertEqual(receipt.totalWithTip(percent: 20), 128.25)
    }

    func testIncludedTipDoesNotIncreaseTotal() {
        let receipt = ReceiptAnalysis(
            subtotal: 100, tax: 8.25, serviceCharge: 20,
            serviceChargeLabel: "Gratuity", statedTip: nil, total: 128.25,
            tipBase: 100, tipAlreadyIncluded: true,
            possibleDuplicateTipRisk: true, lineItems: []
        )
        XCTAssertEqual(receipt.totalWithTip(percent: 20), 128.25)
    }
}
