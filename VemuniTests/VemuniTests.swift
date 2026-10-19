import XCTest
@testable import Vemuni

final class VemuniTests: XCTestCase {
    func testScanResultDecodesWithoutLegacyAIUsage() throws {
        let json = #"{"kind":"menu","menuType":"food","detectedLanguage":"English","notice":"","restaurantName":null,"currencyCode":"USD","menuSections":[],"receipt":null,"warnings":[]}"#
        let result = try JSONDecoder().decode(VemuniScanResult.self, from: Data(json.utf8))

        XCTAssertNil(result.aiUsage)
    }

    func testScanResultDecodesAIUsage() throws {
        let json = #"{"kind":"menu","menuType":"food","detectedLanguage":"English","notice":"","restaurantName":null,"currencyCode":"USD","menuSections":[],"receipt":null,"warnings":[],"aiUsage":{"model":"gpt-5.4-mini","inputTokens":1200,"cachedInputTokens":0,"outputTokens":300,"reasoningTokens":20,"totalTokens":1500}}"#
        let result = try JSONDecoder().decode(VemuniScanResult.self, from: Data(json.utf8))

        XCTAssertEqual(result.aiUsage?.totalTokens, 1500)
    }

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

    func testMenuItemExtractsNumericPrice() {
        let item = MenuItem(
            originalName: "Soup", englishName: "Soup", explanation: "",
            price: "$12.50", itemType: "food", dietary: [], allergens: [],
            spiceLevel: nil, wineDetails: nil, drinkDetails: nil
        )

        XCTAssertEqual(item.numericPrice, 12.50)
    }

    func testMenuItemSupportsDecimalCommaPrice() {
        let item = MenuItem(
            originalName: "Salade", englishName: "Salad", explanation: "",
            price: "€9,50", itemType: "food", dietary: [], allergens: [],
            spiceLevel: nil, wineDetails: nil, drinkDetails: nil
        )

        XCTAssertEqual(item.numericPrice, 9.50)
    }

    func testPerOuncePriceIsNotTreatedAsFixedTotal() {
        let item = MenuItem(
            originalName: "Kagoshima A5", englishName: "Kagoshima A5", explanation: "",
            price: "36oz", itemType: "food", dietary: [], allergens: [],
            spiceLevel: nil, wineDetails: nil, drinkDetails: nil
        )

        XCTAssertNil(item.numericPrice)
        XCTAssertNil(item.filterPrice)
        XCTAssertEqual(item.displayPrice, "36/oz")
    }

    func testMarketPriceIsNotTreatedAsNumeric() {
        let item = MenuItem(
            originalName: "Lobster", englishName: "Lobster", explanation: "",
            price: "MP", itemType: "food", dietary: [], allergens: [],
            spiceLevel: nil, wineDetails: nil, drinkDetails: nil
        )

        XCTAssertNil(item.numericPrice)
        XCTAssertNil(item.filterPrice)
    }

    func testMultiplePricesUseLowestForFilteringButNotSubtotal() {
        let item = MenuItem(
            originalName: "Pinot Noir", englishName: "Pinot Noir", explanation: "",
            price: "24/96", itemType: "wine", dietary: [], allergens: [],
            spiceLevel: nil, wineDetails: nil, drinkDetails: nil
        )

        XCTAssertNil(item.numericPrice)
        XCTAssertEqual(item.filterPrice, 24)
    }

    func testLabeledPriceChoicesAreNotTreatedAsFixedTotal() {
        let item = MenuItem(
            originalName: "Mac N Cheese", englishName: "Mac and cheese", explanation: "",
            price: "original 16 / truffle 34 / lobster 42", itemType: "food", dietary: [], allergens: [],
            spiceLevel: nil, wineDetails: nil, drinkDetails: nil
        )

        XCTAssertNil(item.numericPrice)
        XCTAssertEqual(item.filterPrice, 16)
    }

    func testEnglishTitleIgnoresCosmeticDifferences() {
        let item = MenuItem(
            originalName: "Parker House Rolls", englishName: "Parker house rolls!", explanation: "",
            price: "11", itemType: "food", dietary: [], allergens: [],
            spiceLevel: nil, wineDetails: nil, drinkDetails: nil
        )

        XCTAssertFalse(item.hasDistinctEnglishName)
    }

    func testEnglishTitleIgnoresEquivalentConnectorWords() {
        let item = MenuItem(
            originalName: "Burrata and Heirloom Tomatoes",
            englishName: "Burrata with heirloom tomatoes",
            explanation: "",
            price: "24", itemType: "food", dietary: [], allergens: [],
            spiceLevel: nil, wineDetails: nil, drinkDetails: nil
        )

        XCTAssertFalse(item.hasDistinctEnglishName)
    }

    func testEnglishTitleIgnoresAddedGenericCategory() {
        let chopChop = MenuItem(
            originalName: "Boa Chop Chop", englishName: "Boa Chop Chop salad", explanation: "",
            price: "19", itemType: "food", dietary: [], allergens: [],
            spiceLevel: nil, wineDetails: nil, drinkDetails: nil
        )
        let wedge = MenuItem(
            originalName: "The Classic Wedge", englishName: "Classic wedge salad", explanation: "",
            price: "18", itemType: "food", dietary: [], allergens: [],
            spiceLevel: nil, wineDetails: nil, drinkDetails: nil
        )

        XCTAssertFalse(chopChop.hasDistinctEnglishName)
        XCTAssertFalse(wedge.hasDistinctEnglishName)
    }

    func testEnglishTitleIgnoresCompoundWordSpacing() {
        let item = MenuItem(
            originalName: "Chilean Seabass", englishName: "chilean sea bass", explanation: "",
            price: "52", itemType: "food", dietary: [], allergens: [],
            spiceLevel: nil, wineDetails: nil, drinkDetails: nil
        )

        XCTAssertFalse(item.hasDistinctEnglishName)
    }

    func testEnglishTitleShowsRealTranslation() {
        let item = MenuItem(
            originalName: "Loup de Mer", englishName: "Sea Bass", explanation: "",
            price: "42", itemType: "food", dietary: [], allergens: [],
            spiceLevel: nil, wineDetails: nil, drinkDetails: nil
        )

        XCTAssertTrue(item.hasDistinctEnglishName)
    }

    func testMenuSearchMatchesAcrossNameSectionAndDescription() {
        let item = MenuItem(
            originalName: "Loup de Mer",
            englishName: "Sea Bass",
            explanation: "Served with saffron and roasted tomatoes.",
            price: "42", itemType: "food", dietary: ["Gluten free"], allergens: ["Fish"],
            spiceLevel: nil, wineDetails: nil, drinkDetails: nil
        )

        XCTAssertTrue(item.matchesSearch("sea bass", sectionName: "From the Sea"))
        XCTAssertTrue(item.matchesSearch("saffron tomatoes", sectionName: "From the Sea"))
        XCTAssertTrue(item.matchesSearch("gluten", sectionName: "From the Sea"))
        XCTAssertTrue(item.matchesSearch("from sea", sectionName: "From the Sea"))
        XCTAssertFalse(item.matchesSearch("steak", sectionName: "From the Sea"))
    }

    func testMenuSearchIgnoresCaseAndAccents() {
        let item = MenuItem(
            originalName: "Rosé de Provence",
            englishName: "Provence Rosé",
            explanation: "Dry and crisp.",
            price: "17", itemType: "wine", dietary: [], allergens: [],
            spiceLevel: nil, wineDetails: nil, drinkDetails: nil
        )

        XCTAssertTrue(item.matchesSearch("ROSE", sectionName: "Wines"))
        XCTAssertTrue(item.matchesSearch("provence rose", sectionName: "Wines"))
    }
}
