import XCTest
#if canImport(UIKit)
import UIKit
#endif
#if canImport(Lifeblood)
@testable import Lifeblood
#else
@testable import PrescriptionCore
#endif

final class PrescriptionTests: XCTestCase {
    func read(_ text: String, confidence: Float = 0.99) -> PrescriptionParseResult {
        PrescriptionParser.parse(text.components(separatedBy: "\n").map { PrescriptionLine(text: $0, confidence: confidence) })
    }
    func testPrintedMedicineStrengthAndExplicitDosePopulateDraftOnly() {
        let result = read("AMOXICILLIN 500 mg capsules\nTake 1 capsule three times a day by mouth")
        XCTAssertEqual(result.drafts.count, 1)
        let draft = result.drafts[0]
        XCTAssertEqual(draft.name, "AMOXICILLIN")
        XCTAssertEqual(draft.strength, "500 mg")
        XCTAssertEqual(draft.formulation, "Capsule")
        XCTAssertEqual(draft.quantity, "1")
        XCTAssertEqual(draft.unit, .capsule)
        XCTAssertEqual(draft.route, "Oral")
        XCTAssertFalse(draft.reviewed)
        XCTAssertTrue(draft.warnings.contains { $0.contains("No schedule was inferred") })
    }
    func testMicrogramsAreNotChangedIntoMilligrams() {
        let result = read("LEVOTHYROXINE 50 micrograms tablets\nTake 1 tablet daily")
        XCTAssertEqual(result.drafts.first?.strength, "50 micrograms")
        XCTAssertFalse(result.drafts[0].strength.contains("mg"))
    }
    func testCombinationLineRetainedWithoutInventingIngredients() {
        let result = read("AMOXICILLIN 500 mg / CLAVULANIC ACID 125 mg tablets")
        XCTAssertEqual(result.drafts.count, 1)
        XCTAssertTrue(result.drafts[0].name.contains("CLAVULANIC ACID"))
        XCTAssertEqual(result.drafts[0].strength, "500 mg + 125 mg")
        XCTAssertTrue(result.drafts[0].warnings.contains { $0.contains("combination") })
    }
    func testInjectionVolumeAndConcentrationStayTextUntilConfirmed() {
        let result = read("Medicine: Fixture 10 mg/mL injection\nInject 0.5 mL subcutaneously once weekly")
        XCTAssertEqual(result.drafts.first?.strength, "10 mg/mL")
        XCTAssertEqual(result.drafts.first?.quantity, "0.5")
        XCTAssertEqual(result.drafts.first?.unit, .mL)
        XCTAssertEqual(result.drafts.first?.route, "Subcutaneous")
        XCTAssertTrue(result.drafts[0].directions.contains("weekly"))
        // Drafts have no ingredient concentrations or recurrence model: review is mandatory.
        XCTAssertFalse(result.drafts[0].reviewed)
    }
    func testAsNeededExplicitlyDetectedButNotSaved() {
        let result = read("Fixture 5 mg tablets\nTake 1 tablet as needed by mouth")
        XCTAssertTrue(result.drafts[0].asNeeded)
        XCTAssertFalse(result.drafts[0].reviewed)
    }
    func testMultipleMedicinesDoNotBorrowEachOthersDirections() {
        let result = read("Fixture A 5 mg tablets\nTake 1 tablet daily\nFixture B 10 mg capsules\nTake 2 capsules once weekly")
        XCTAssertEqual(result.drafts.count, 2)
        XCTAssertTrue(result.drafts.allSatisfy { $0.quantity.isEmpty && $0.directions.isEmpty && !$0.asNeeded })
        XCTAssertTrue(result.warnings.contains { $0.contains("not been assigned") })
    }
    func testTaperRangesAndFractionsDoNotBecomeFixedDoses() {
        for directions in ["Take 1-2 tablets daily", "Take 1/2 tablet daily", "Take 2 tablets then decrease to 1", "Take half a tablet daily"] {
            let result = read("Fixture 5 mg tablets\n" + directions)
            XCTAssertTrue(result.drafts[0].quantity.isEmpty)
            XCTAssertTrue(result.drafts[0].warnings.contains { $0.contains("Variable") })
            XCTAssertEqual(result.drafts[0].directions, directions)
        }
    }
    func testLowConfidenceDoesNotPopulateDoseOrPRN() {
        let result = read("Fixture 5 mg tablets\nTake 1 tablet as needed by mouth", confidence: 0.6)
        XCTAssertTrue(result.drafts[0].quantity.isEmpty)
        XCTAssertFalse(result.drafts[0].asNeeded)
        XCTAssertTrue(result.drafts[0].route.isEmpty)
        XCTAssertTrue(result.drafts[0].warnings.contains { $0.contains("Low-confidence") })
    }
    func testIdentityHeadersNeverBecomeMedicineDraftsOrDirections() {
        let result = read("Patient: Jane Example\nDOB: 01/01/1970\nAddress: 25 Example Street\nMedicare: 123456789\nFixture 5 mg tablets\nTake 1 tablet daily")
        XCTAssertEqual(result.drafts.count, 1)
        XCTAssertEqual(result.drafts[0].name, "Fixture")
        XCTAssertFalse(result.drafts[0].directions.contains("Jane"))
        XCTAssertFalse(result.drafts[0].directions.contains("123456789"))
    }
    func testNoReadableMedicineOffersManualEntryRatherThanGuess() {
        let result = read("Prescription\nPatient: Jane Example\nUnreadable handwriting")
        XCTAssertTrue(result.drafts.isEmpty)
        XCTAssertTrue(result.warnings.contains { $0.contains("No clear medicine") })
    }
    func testNameWithoutStrengthRequiresExplicitMedicineLabel() {
        XCTAssertTrue(read("Unlabelled ambiguous brand").drafts.isEmpty)
        let result = read("Medicine: Unclear brand")
        XCTAssertEqual(result.drafts.first?.name, "Unclear brand")
        XCTAssertTrue(result.drafts[0].strength.isEmpty)
        XCTAssertTrue(result.drafts[0].warnings.contains { $0.contains("No readable strength") })
    }
    func testMultipleDirectionsRemainUnassigned() {
        let result = read("Fixture 5 mg tablets\nTake 1 tablet in morning\nTake 2 tablets at night")
        XCTAssertTrue(result.drafts[0].quantity.isEmpty)
        XCTAssertTrue(result.drafts[0].directions.isEmpty)
    }
    func testTooManyCandidatesOrTooMuchTextRequiresSmallerScan() {
        let many = (1...11).map { "Fixture \($0) 5 mg tablets" }.joined(separator: "\n")
        XCTAssertTrue(read(many).drafts.isEmpty)
        let huge = (1...501).map { _ in PrescriptionLine(text: "Fixture 5 mg tablet", confidence: 1) }
        XCTAssertTrue(PrescriptionParser.parse(huge).drafts.isEmpty)
    }
    #if canImport(UIKit)
    func testOCRRejectsMissingPagesAndInvalidImage() {
        XCTAssertThrowsError(try PrescriptionOCR.recognise([]))
        XCTAssertThrowsError(try PrescriptionOCR.recognise([Data("not an image".utf8)]))
        XCTAssertThrowsError(try PrescriptionOCR.recognise(Array(repeating: Data(), count: 6)))
    }
    func testBlankPhotoReportsNoText() {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 300, height: 300))
        let image = renderer.image { context in UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 300, height: 300)) }
        XCTAssertThrowsError(try PrescriptionOCR.recognise([image.jpegData(compressionQuality: 1)!]))
    }
    #endif
}
