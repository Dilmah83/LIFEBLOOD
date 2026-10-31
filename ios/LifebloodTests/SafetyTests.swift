import XCTest
@testable import Lifeblood

final class SafetyTests: XCTestCase {
    func ingredient(_ id: String = "b6", amount: Decimal = 10, unit: DoseUnit = .mg, per: Decimal = 1, productUnit: DoseUnit = .tablet) -> Ingredient {
        Ingredient(id: id, name: id, amount: amount, unit: unit, per: per, productUnit: productUnit)
    }
    func product(_ brand: String = "Combination", ingredients: [Ingredient]) -> Product {
        Product(id: brand, brand: brand, generic: "", strength: "Confirmed test strength", formulation: "tablet", route: "Oral", ingredients: ingredients)
    }
    func testCombinationAndMultivitaminOverlap() {
        let a = product("Combination A", ingredients: [ingredient(), ingredient("zinc", amount: 5)])
        let b = product("Multivitamin B", ingredients: [ingredient(amount: 20), ingredient("folate", amount: 400, unit: .microgram)])
        let totals = SafetyEngine.totals([(a, 1, .tablet), (b, 1, .tablet)])
        XCTAssertEqual(totals.totals.first { $0.name == "b6" }?.amount, 30)
        XCTAssertEqual(totals.totals.first { $0.name == "folate" }?.amount, Decimal(string: "0.4"))
        XCTAssertEqual(totals.totals.first { $0.name == "b6" }?.contributions.count, 2)
        let warnings = SafetyEngine.findings(items: [RegimenItem(product: a), RegimenItem(product: b)])
        XCTAssertTrue(warnings.contains { $0.id == "duplicate:b6" })
        XCTAssertTrue(warnings.first { $0.id == "duplicate:b6" }!.spacing.contains("does not"))
    }
    func testMilligramMicrogramGramConversionAndIUSeparation() {
        let p = product(ingredients: [ingredient(amount: 1000, unit: .microgram), ingredient(amount: 1, unit: .mg), ingredient(amount: Decimal(string: "0.001")!, unit: .g), ingredient(amount: 100, unit: .IU)])
        let totals = SafetyEngine.totals([(p, 1, .tablet)]).totals
        XCTAssertEqual(totals.first { $0.unit == .mg }?.amount, 3)
        XCTAssertEqual(totals.first { $0.unit == .IU }?.amount, 100)
    }
    func testInjectionRequiresMatchingConfirmedConcentrationAndVolume() {
        let p = product(ingredients: [ingredient("test", amount: 20, per: 1, productUnit: .mL)])
        XCTAssertEqual(SafetyEngine.totals([(p, Decimal(string: "0.25")!, .mL)]).totals.first?.amount, 5)
        XCTAssertTrue(SafetyEngine.totals([(p, 1, .tablet)]).totals.isEmpty)
        XCTAssertFalse(SafetyEngine.totals([(p, 1, .tablet)]).missing.isEmpty)
        let noConcentration = product(ingredients: [])
        XCTAssertTrue(SafetyEngine.totals([(noConcentration, 1, .mL)]).totals.isEmpty)
    }
    func testServingSize() {
        let p = product(ingredients: [ingredient(amount: 40, per: 2, productUnit: .capsule)])
        XCTAssertEqual(SafetyEngine.totals([(p, 3, .capsule)]).totals.first?.amount, 60)
    }
    func testWeeklyAndPRNAreNotDailyAverages() {
        var item = RegimenItem(product: product(ingredients: [ingredient()]))
        let monday = ISO8601DateFormatter().date(from: "2026-11-02T12:00:00Z")!
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        item.start = monday.addingTimeInterval(-86400); item.weekdays = [2]
        XCTAssertTrue(item.scheduled(on: monday, calendar: calendar))
        XCTAssertFalse(item.scheduled(on: monday.addingTimeInterval(86400), calendar: calendar))
        item.asNeeded = true
        XCTAssertFalse(item.scheduled(on: monday, calendar: calendar))
        let dose = TakenDose(itemID: item.id, product: item.product, quantity: 2, unit: .tablet, takenAt: monday)
        XCTAssertEqual(SafetyEngine.actualTotals(doses: [dose], on: monday).totals.first?.amount, 20)
    }
    func testStoppedAndExpiredSchedules() {
        var item = RegimenItem(product: product(ingredients: []))
        item.start = Date().addingTimeInterval(-86400 * 10)
        item.end = Date().addingTimeInterval(-86400 * 2)
        XCTAssertFalse(item.scheduled(on: Date()))
        item.end = nil; item.stopped = true
        XCTAssertFalse(item.scheduled(on: Date()))
    }
    func testUnsupportedCoverageNeverClaimsSafety() {
        XCTAssertTrue(SafetyEngine.coverage.contains("Limited mode"))
        XCTAssertTrue(SafetyEngine.coverage.contains("require a clinical provider"))
        XCTAssertTrue(SafetyEngine.coverage.contains("does not establish safety"))
        XCTAssertTrue(SafetyEngine.findings(items: []).isEmpty)
    }
    func testStaleAndConflictingSourcesAreFlagged() {
        var p = product(ingredients: [ingredient()]); p.verified = true
        p.sources = [EvidenceSource(id: "t", title: "Fixture, not clinical data", url: URL(string: "https://example.org/fixture")!, checked: Date().addingTimeInterval(-100 * 86400), jurisdiction: "AU")]
        p.conflicts = ["Strength differs between sources"]
        XCTAssertTrue(SafetyEngine.findings(items: [RegimenItem(product: p)]).contains { $0.id.hasPrefix("incomplete:") })
        XCTAssertThrowsError(try ProductService.validate(p))
    }
    func testUntrustedURLAndMalformedCompositionRejected() {
        var p = product(ingredients: [ingredient()])
        p.sources = [EvidenceSource(id: "bad", title: "Bad URL", url: URL(string: "javascript:alert(1)")!, checked: Date(), jurisdiction: "AU")]
        XCTAssertThrowsError(try ProductService.validate(p))
        p.sources = []; p.ingredients[0].per = 0
        XCTAssertThrowsError(try ProductService.validate(p))
    }
    func testAmbiguousProductsRemainDistinct() throws {
        let a = product("Brand 5 mg tablet", ingredients: [ingredient(amount: 5)])
        var b = product("Brand 10 mg injection", ingredients: [ingredient(amount: 10, productUnit: .mL)])
        b.formulation = "injection"; b.route = "Subcutaneous"
        let data = try JSONEncoder().encode([a, b])
        let decoded = try JSONDecoder().decode([Product].self, from: data)
        XCTAssertEqual(decoded.count, 2)
        XCTAssertNotEqual(decoded[0].id, decoded[1].id)
        XCTAssertNotEqual(decoded[0].route, decoded[1].route)
    }
    func testMissingPatientDataDoesNotInventSupplementNeed() {
        let suggestions = SafetyEngine.recommendations(profile: PatientProfile(), items: [])
        XCTAssertEqual(suggestions.first?.id, "none")
        XCTAssertTrue(suggestions[0].title.contains("No additional supplement indicated"))
    }
    func testExistingB12ChangesPromptAndDoesNotRecommendAnotherProduct() {
        var profile = PatientProfile(); profile.diet = "Vegan"
        let item = RegimenItem(product: product(ingredients: [ingredient("vitamin b12")]))
        let suggestion = SafetyEngine.recommendations(profile: profile, items: [item])[0]
        XCTAssertTrue(suggestion.nextStep.contains("do not add another product"))
        XCTAssertTrue(suggestion.missing.contains("No dose recommendation"))
    }
    func testInvalidProviderConfigurationFailsHonestly() async {
        do { _ = try await ProductService().search("Ambiguous brand", endpoint: "http://insecure.example.org"); XCTFail("Should not return mock products") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Manual entry remains unverified")) }
    }
    @MainActor func testLegacyMigrationPreservesCalendarScheduleAndOriginalArchive() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = Store(directory: dir)
        let data = Data(#"{"profile":{"name":"private"},"items":[{"id":"old1","name":"Weekly medicine","ingredient":"ambiguous compound","dose":"0.5 mL","days":[1,3],"times":["08:00","20:00"],"start":"2026-01-01","end":"2027-01-01","notes":"Keep original"}],"logs":{"old1|2026-10-26|08:00":{"status":"taken","at":"2026-10-26T08:03:00.000Z"},"deleted|2026-10-26|09:00":{"status":"skipped","at":"2026-10-26T09:00:00.000Z"}},"symptoms":[{"t":"Original note"}],"settings":{"private":true}}"#.utf8)
        try store.restore(data)
        XCTAssertEqual(store.archive.legacyJSON, data)
        XCTAssertEqual(store.archive.items.first?.weekdays, [2, 4])
        XCTAssertEqual(store.archive.items.first?.times, ["08:00", "20:00"])
        XCTAssertEqual(store.archive.doses.count, 1)
        XCTAssertNotNil(store.archive.doses[0].scheduledAt)
        XCTAssertEqual(store.archive.profile.name, "private")
        XCTAssertTrue(store.archive.items[0].product.ingredients.isEmpty)
        XCTAssertEqual(store.archive.items[0].legacyDose, "0.5 mL")
        XCTAssertThrowsError(try store.restore(data))
        let reopened = Store(directory: dir)
        XCTAssertEqual(reopened.archive.legacyJSON, data)
        XCTAssertEqual(reopened.archive.items.count, 1)
    }
    @MainActor func testActualDoseSnapshotAndDuplicateScheduledLogging() {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = Store(directory: dir)
        var item = RegimenItem(product: product(ingredients: [ingredient()]))
        let scheduled = Date()
        store.upsert(item)
        store.log(item, quantity: 1, unit: .tablet, at: Date(), scheduled: scheduled)
        store.log(item, quantity: 1, unit: .tablet, at: Date(), scheduled: scheduled)
        XCTAssertEqual(store.archive.doses.count, 1)
        item.product.ingredients[0].amount = 99; store.upsert(item)
        XCTAssertEqual(store.archive.doses[0].product.ingredients[0].amount, 10)
    }
}
