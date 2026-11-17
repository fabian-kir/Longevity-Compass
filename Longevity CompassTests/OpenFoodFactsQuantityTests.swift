import XCTest
@testable import Longevity_Compass

@MainActor
final class OpenFoodFactsQuantityTests: XCTestCase {
    private typealias Q = OpenFoodFactsClient.Quantity

    func testLabelWithLeadingCountUsesParenthesisedWeight() {
        XCTAssertEqual(
            OpenFoodFactsClient.quantity(amount: nil, unit: nil, label: "1 biscuit (10 g)"),
            Q(value: 10, unit: "g")
        )
        XCTAssertEqual(
            OpenFoodFactsClient.quantity(amount: nil, unit: nil, label: "1 portion (330 ml)"),
            Q(value: 330, unit: "ml")
        )
    }

    func testNumericFieldWinsOverLabel() {
        XCTAssertEqual(
            OpenFoodFactsClient.quantity(amount: 6, unit: "g", label: "2 pieces (12 g)"),
            Q(value: 6, unit: "g")
        )
        XCTAssertEqual(
            OpenFoodFactsClient.quantity(amount: "37,5", unit: "g", label: nil),
            Q(value: 37.5, unit: "g")
        )
    }

    func testLargerUnitsAreNormalised() {
        XCTAssertEqual(
            OpenFoodFactsClient.quantity(amount: nil, unit: nil, label: "33 cl"),
            Q(value: 330, unit: "ml")
        )
        XCTAssertEqual(
            OpenFoodFactsClient.quantity(amount: nil, unit: nil, label: "1,5 kg"),
            Q(value: 1500, unit: "g")
        )
    }

    func testLabelWithoutWeightGivesNoQuantity() {
        XCTAssertNil(OpenFoodFactsClient.quantity(amount: nil, unit: nil, label: "2 Stück"))
        XCTAssertNil(OpenFoodFactsClient.quantity(amount: 0, unit: "g", label: nil))
    }
}
