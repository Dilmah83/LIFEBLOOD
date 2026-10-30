import XCTest
#if canImport(Lifeblood)
@testable import Lifeblood
#else
@testable import PrescriptionCore
#endif

final class SupplementTests: XCTestCase {
    func read(_ text: String, confidence: Float = 0.99) -> PrescriptionParseResult {
        SupplementParser.parse(text.components(separatedBy: "\n").map { PrescriptionLine(text: $0, confidence: confidence) })
    }
    func testMultivitaminIngredientsShareExplicitServingBasis() {
        let result = read("Product: Fixture multivitamin\nServing size: 2 capsules\nAmount per serving\nVitamin C 500 mg 556%\nVitamin D3 25 micrograms\nDirections\nTake 1 capsule daily")
        XCTAssertEqual(result.drafts.count, 1)
        let draft = result.drafts[0]
        XCTAssertTrue(draft.isSupplement)
        XCTAssertFalse(draft.reviewed)
        XCTAssertEqual(draft.name, "Fixture multivitamin")
        XCTAssertEqual(draft.labelIngredients.count, 2)
        XCTAssertTrue(draft.labelIngredients.allSatisfy { $0.per == 2 && $0.productUnit == .capsule })
        XCTAssertEqual(draft.labelIngredients[0].delivered(quantity: 1, unit: .capsule), 250)
        XCTAssertEqual(draft.labelIngredients[1].unit, .microgram)
        XCTAssertEqual(draft.quantity, "1")
    }
    func testEachTabletLabelSupportsAUStyle() {
        let draft = read("Product: Fixture mineral\nEach tablet contains:\nMagnesium 150 mg").drafts[0]
        XCTAssertEqual(draft.labelIngredients.first?.per, 1)
        XCTAssertEqual(draft.labelIngredients.first?.productUnit, .tablet)
        XCTAssertEqual(draft.quantity, "") // Serving is not a recommended dose.
    }
    func testIUIsRetainedWithoutConversion() {
        let draft = read("Product: Fixture vitamin\nEach softgel contains:\nVitamin D3 1000 IU").drafts[0]
        XCTAssertEqual(draft.labelIngredients.first?.unit, .IU)
        XCTAssertNil(draft.labelIngredients.first?.unit.massInMg)
        XCTAssertEqual(draft.formulation, "Softgel")
    }
    func testFrontPhotoWithoutServingDoesNotInventIngredients() {
        let draft = read("Fixture Brand\nVitamin C 1000 mg\n100 tablets").drafts[0]
        XCTAssertTrue(draft.labelIngredients.isEmpty)
        XCTAssertTrue(draft.warnings.contains { $0.contains("No single explicit serving") })
    }
    func testEquivalentAndComplexRowsBlockPartialComposition() {
        for row in ["Pyridoxine hydrochloride 27.4 mg equiv pyridoxine 25 mg", "Folate 400 micrograms DFE", "Proprietary blend 500 mg"] {
            let draft = read("Product: Fixture blend\nEach tablet contains:\nVitamin C 10 mg\n" + row).drafts[0]
            XCTAssertTrue(draft.labelIngredients.isEmpty)
            XCTAssertTrue(draft.warnings.contains { $0.contains("No partial ingredient list") })
        }
    }
    func testConflictingBasesAreNotResolvedByGuessing() {
        let draft = read("Product: Fixture\nServing size: 2 capsules\nEach capsule contains:\nVitamin C 500 mg").drafts[0]
        XCTAssertTrue(draft.labelIngredients.isEmpty)
        XCTAssertTrue(draft.warnings.contains { $0.contains("Conflicting") })
    }
    func testSeparatedColumnsRemainManual() {
        let draft = read("Product: Fixture\nServing size: 1 tablet\nVitamin C\n500 mg\nVitamin D3\n25 micrograms").drafts[0]
        XCTAssertTrue(draft.labelIngredients.isEmpty)
        XCTAssertTrue(draft.warnings.contains { $0.contains("Separated") })
    }
    func testLowConfidenceIngredientIsNotUsedAsAmount() {
        var lines = [PrescriptionLine(text: "Product: Fixture", confidence: 1), PrescriptionLine(text: "Each tablet contains:", confidence: 1)]
        lines.append(PrescriptionLine(text: "Vitamin C 500 mg", confidence: 0.6))
        let draft = SupplementParser.parse(lines).drafts[0]
        XCTAssertTrue(draft.labelIngredients.isEmpty)
    }
    func testInactiveIngredientsAreNotAddedAsActives() {
        let draft = read("Product: Fixture\nEach tablet contains:\nVitamin C 500 mg\nOther ingredients:\nCellulose 50 mg").drafts[0]
        XCTAssertEqual(draft.labelIngredients.count, 1)
        XCTAssertEqual(draft.labelIngredients.first?.name, "Vitamin C")
    }
    func testUnsupportedOrMissingAmountsDoNotHideAnIngredient() {
        for row in ["Selenium 55 unknown-units", "Selenium", "Selenium OO micrograms"] {
            let draft = read("Product: Fixture\nEach tablet contains:\nVitamin C 500 mg\n" + row).drafts[0]
            XCTAssertTrue(draft.labelIngredients.isEmpty)
            XCTAssertTrue(draft.warnings.contains { $0.contains("No partial ingredient list") })
        }
    }
    func testLoosePillImageWithoutTextCannotIdentifyVitamin() {
        let result = SupplementParser.parse([])
        XCTAssertTrue(result.drafts.isEmpty)
        XCTAssertTrue(result.warnings.contains { $0.contains("loose pill") })
    }
}
