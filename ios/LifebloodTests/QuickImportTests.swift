import XCTest
#if canImport(Lifeblood)
@testable import Lifeblood
#else
@testable import PrescriptionCore
#endif

final class QuickImportTests: XCTestCase {
    func testAcceptPhotoCreatesOneRecordWithoutInventingDoseOrSchedule() throws {
        var draft = PrescriptionDraft(name: "Fixture medicine")
        draft.strength = "5 mg"
        let item = try PhotoImport.item(from: draft)
        XCTAssertEqual(item.product.brand, "Fixture medicine")
        XCTAssertEqual(item.quantity, 0)
        XCTAssertEqual(item.legacyDose, "Dose not confirmed")
        XCTAssertTrue(item.times.isEmpty)
        XCTAssertTrue(item.weekdays.isEmpty)
        XCTAssertFalse(item.scheduled(on: Date()))
        XCTAssertFalse(item.product.verified)
    }
    func testBrandOnlyVitaminPhotoCannotBeAcceptedAsComposition() {
        var draft = PrescriptionDraft(name: "Fixture brand")
        draft.isSupplement = true
        XCTAssertThrowsError(try PhotoImport.item(from: draft))
    }
    func testAcceptedVitaminKeepsEveryIngredientAndServingBasis() throws {
        var draft = PrescriptionDraft(name: "Fixture vitamin")
        draft.isSupplement = true; draft.quantity = "1"; draft.unit = .capsule
        draft.labelIngredients = [Ingredient(id: "a", name: "Vitamin C", amount: 500, unit: .mg, per: 2, productUnit: .capsule), Ingredient(id: "b", name: "Vitamin D3", amount: 25, unit: .microgram, per: 2, productUnit: .capsule)]
        let item = try PhotoImport.item(from: draft)
        XCTAssertEqual(item.product.ingredients.count, 2)
        XCTAssertEqual(item.product.ingredients[0].delivered(quantity: item.quantity, unit: item.unit), 250)
        XCTAssertTrue(item.times.isEmpty)
    }
    func testComplexIngredientPanelCanBeAcceptedAsTextWithoutFalseTotals() throws {
        let parsed = SupplementParser.parse([PrescriptionLine(text: "Each tablet contains:", confidence: 1), PrescriptionLine(text: "Magnesium oxide 500 mg equiv magnesium 300 mg", confidence: 1)])
        let draft = try XCTUnwrap(parsed.drafts.first)
        XCTAssertTrue(draft.labelIngredients.isEmpty)
        XCTAssertFalse(draft.ingredientPanelText.isEmpty)
        let item = try PhotoImport.item(from: draft)
        XCTAssertTrue(item.product.ingredients.isEmpty)
        XCTAssertTrue(item.product.sections["Label information"]!.contains("magnesium 300 mg"))
        XCTAssertTrue(item.product.missing.contains { $0.contains("totals") })
    }
    func testRangeOrOCRGarbageIsNotSilentlyParsedAsOneDose() {
        for text in ["1-2", "1/2", "1O", "0", "-1", "1 tablet"] { XCTAssertThrowsError(try PhotoImport.quantity(text)) }
        XCTAssertEqual(try PhotoImport.quantity("0.5"), Decimal(string: "0.5"))
    }
    func testSamePhysicalRowCanPairIngredientAndAmount() {
        let lines = [PrescriptionLine(text: "Each film-coated tablet contains:", confidence: 1, minX: 0.1, midY: 0.9, height: 0.02), PrescriptionLine(text: "Vitamin C", confidence: 1, minX: 0.1, midY: 0.8, height: 0.02), PrescriptionLine(text: "500 mg", confidence: 1, minX: 0.7, midY: 0.802, height: 0.02)]
        let result = SupplementParser.parse(lines)
        XCTAssertEqual(result.drafts.first?.labelIngredients.first?.name, "Vitamin C")
        XCTAssertEqual(result.drafts.first?.labelIngredients.first?.amount, 500)
        XCTAssertEqual(result.drafts.first?.name, "Vitamin C") // Brand not required to read a panel.
    }
    func testDifferentRowsOrPagesNeverBorrowAmounts() {
        let name = PrescriptionLine(text: "Vitamin C", confidence: 1, minX: 0.1, midY: 0.8, height: 0.02)
        let otherRow = PrescriptionLine(text: "500 mg", confidence: 1, minX: 0.7, midY: 0.75, height: 0.02)
        var otherPage = otherRow; otherPage.midY = 0.8; otherPage.page = 1
        XCTAssertEqual(LabelRows.assemble([name, otherRow]).count, 2)
        XCTAssertEqual(LabelRows.assemble([name, otherPage]).count, 2)
    }
    func testSearchHandlesPartialNamesAndStrengthWithoutExactPhrase() {
        let query = MedicineSearch("Metfor 500 mg")
        XCTAssertEqual(query.name, "metfor")
        XCTAssertEqual(query.strength, "500 mg")
        XCTAssertTrue(query.expression().contains("metfor*"))
        XCTAssertFalse(query.expression().contains("500"))
        XCTAssertTrue(query.expression().contains("finished:true"))
    }
    func testSearchKeepsReleaseFormAndRemovesQueryOperators() {
        let query = MedicineSearch("Metformin XR 500mg\" OR :")
        XCTAssertTrue(query.terms.contains("xr"))
        XCTAssertFalse(query.expression().contains("\""))
        XCTAssertFalse(query.expression().contains(":*"))
    }
    func testRequestedStrengthRanksAheadOfOtherStrength() {
        func p(_ strength: String) -> Product { Product(id: strength, brand: "Metformin", generic: "metformin", strength: strength, formulation: "Tablet", route: "Oral", ingredients: [Ingredient(id: "m", name: "metformin", amount: 1, unit: .mg)]) }
        let query = MedicineSearch("metformin 500mg")
        XCTAssertGreaterThan(query.rank(p("500 mg")), query.rank(p("1000 mg")))
    }
}
