import XCTest
@testable import Lifeblood

// Network fixtures exist only in the XCTest bundle, never as a live fallback.
final class FixtureProtocol: URLProtocol {
    static var reply: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            let (status, data) = try Self.reply!(request)
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
final class ProviderTests: XCTestCase {
    var service: ProductService {
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [FixtureProtocol.self]
        return ProductService(configuration: config)
    }
    func product(_ name: String, amount: Decimal = 5) -> Product {
        Product(id: "provider:" + name, brand: name, generic: "Fictional test ingredient", strength: "\(amount) mg", formulation: "tablet", route: "Oral", ingredients: [Ingredient(id: "fixture-substance", name: "Fictional test ingredient", amount: amount, unit: .mg)], verified: true, sources: [EvidenceSource(id: name + "source", title: "Fictional fixture source — not clinical data", url: URL(string: "https://example.org/test")!, checked: Date(), jurisdiction: "AU")])
    }
    func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }
    override func tearDown() { FixtureProtocol.reply = nil }
    @MainActor func testSearchConfirmationDoseSaveSafetySourcesFlow() async throws {
        let data = try encoded([product("Fixture A"), product("Fixture B", amount: 10)])
        FixtureProtocol.reply = { request in
            XCTAssertEqual(request.url?.path, "/products")
            XCTAssertNil(request.httpBody)
            XCTAssertTrue(request.url!.query!.contains("jurisdiction=AU"))
            XCTAssertFalse(request.url!.absoluteString.contains("patient"))
            return (200, data)
        }
        let results = try await service.search("Fixture", endpoint: "https://medical.example.org")
        XCTAssertEqual(results.count, 2)
        // Simulates the explicit exact-product selection; both distinct strengths remain selectable.
        let selected = results[1]
        XCTAssertEqual(selected.strength, "10 mg")
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = Store(directory: folder)
        var first = RegimenItem(product: results[0]); first.quantity = 1
        var confirmed = RegimenItem(product: selected); confirmed.quantity = 2
        store.upsert(first); store.upsert(confirmed)
        XCTAssertEqual(store.archive.items.count, 2)
        XCTAssertTrue(SafetyEngine.findings(items: store.archive.items).contains { $0.id == "duplicate:fixture-substance" })
        XCTAssertEqual(SafetyEngine.scheduledTotals(items: store.archive.items, on: Date()).totals.first?.amount, 25)
        XCTAssertEqual(store.archive.items[1].product.sources.first?.url.host, "example.org")
        XCTAssertTrue(store.summary.contains("Fictional fixture source"))
    }
    func test429AndFailedLookupsNeverReturnMockOrCachedResults() async {
        for status in [429, 503, 404] {
            FixtureProtocol.reply = { _ in (status, Data()) }
            do { _ = try await service.search("Fixture", endpoint: "https://medical.example.org"); XCTFail("Must fail") }
            catch { XCTAssertTrue(error.localizedDescription.contains("unavailable or rate limited")) }
        }
        FixtureProtocol.reply = { _ in throw URLError(.notConnectedToInternet) }
        do { _ = try await service.search("Fixture", endpoint: "https://medical.example.org"); XCTFail("Must fail offline") } catch {}
    }
    func testConflictingVerifiedSearchDataRejected() async throws {
        var p = product("Conflict"); p.conflicts = ["Source strength mismatch"]
        let data = try encoded([p]); FixtureProtocol.reply = { _ in (200, data) }
        do { _ = try await service.search("Conflict", endpoint: "https://medical.example.org"); XCTFail("Must reject conflicting verified data") } catch {}
    }
    func testDocumentedAndTheoreticalFindingsHaveSeparateEvidence() async throws {
        let p = product("Fixture")
        let source = p.sources[0]
        let findings = ["Documented", "Theoretical"].map { strength in
            Finding(id: strength, title: "Fictional finding", products: [p.brand], ingredients: ["Fixture"], consequence: "Test consequence", severity: "Review", evidence: strength, advice: "Professional review", spacing: "Not established", sources: [source])
        }
        let result = ClinicalResult(coverage: "Fixture-only test; food and supplement coverage unavailable", complete: false, findings: findings, checked: Date())
        let data = try encoded(result)
        FixtureProtocol.reply = { request in
            XCTAssertEqual(request.url?.path, "/check")
            XCTAssertEqual(request.httpMethod, "POST")
            return (200, data)
        }
        let checked = try await service.check([RegimenItem(product: p)], endpoint: "https://medical.example.org")
        XCTAssertFalse(checked.complete)
        XCTAssertEqual(checked.findings.map(\.evidence), ["Documented", "Theoretical"])
    }
    func testUnverifiedRegimenNeverSentAsCompleteCheck() async {
        var p = product("Fixture"); p.verified = false
        FixtureProtocol.reply = { _ in XCTFail("Do not send an incomplete regimen"); return (200, Data()) }
        do { _ = try await service.check([RegimenItem(product: p)], endpoint: "https://medical.example.org"); XCTFail("Must report incomplete coverage") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Full regimen checking unavailable")) }
    }
    func testStaleProviderResultRejected() async throws {
        let result = ClinicalResult(coverage: "Fictional fixture", complete: false, findings: [], checked: Date().addingTimeInterval(-90000))
        let data = try encoded(result); FixtureProtocol.reply = { _ in (200, data) }
        do { _ = try await service.check([RegimenItem(product: product("Fixture"))], endpoint: "https://medical.example.org"); XCTFail("Stale check must not be presented as current") } catch {}
    }
    func testDefaultSearchWorksWithoutBackendAndKeepsFormulationsDistinct() async throws {
        let fixture = #"{"results":[{"finished":false,"product_ndc":"raw-material","generic_name":"Fixture raw material","dosage_form":"GRANULE"},{"finished":true,"product_ndc":"test-tablet","brand_name":"Fixture Brand","generic_name":"Fixture ingredient","dosage_form":"TABLET, FILM COATED","route":["ORAL"],"active_ingredients":[{"name":"FIXTURE A","strength":"500 mg/1"},{"name":"FIXTURE B","strength":"5 mg/1"}]},{"finished":true,"product_ndc":"test-injection","brand_name":"Fixture Brand","generic_name":"Fixture ingredient","dosage_form":"INJECTION, SOLUTION","route":["SUBCUTANEOUS"],"active_ingredients":[{"name":"FIXTURE A","strength":"10 mg/mL"}]}]}"#
        FixtureProtocol.reply = { request in
            XCTAssertEqual(request.url?.host, "api.fda.gov")
            XCTAssertEqual(request.url?.path, "/drug/ndc.json")
            XCTAssertNil(request.httpBody)
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            return (200, Data(fixture.utf8))
        }
        let products = try await service.search("Fixture Brand", endpoint: "")
        XCTAssertEqual(products.count, 2)
        XCTAssertEqual(products[0].ingredients.count, 2)
        XCTAssertEqual(products[0].ingredients[0].amount, 500)
        XCTAssertEqual(products[0].ingredients[0].productUnit, .tablet)
        XCTAssertEqual(products[1].ingredients[0].productUnit, .mL)
        XCTAssertEqual(products[1].ingredients[0].delivered(quantity: Decimal(string: "0.5")!, unit: .mL), 5)
        XCTAssertNotEqual(products[0].id, products[1].id)
        XCTAssertTrue(products.allSatisfy { !$0.verified && $0.sources.first?.jurisdiction == "US" })
    }
    func testUnknownStrengthDoesNotProducePartialCombinationTotals() async throws {
        let fixture = #"{"results":[{"finished":true,"product_ndc":"test","brand_name":"Fixture","dosage_form":"TABLET","route":["ORAL"],"active_ingredients":[{"name":"FIXTURE A","strength":"5 mg/1"},{"name":"FIXTURE B","strength":"1 %"}]}]}"#
        FixtureProtocol.reply = { _ in (200, Data(fixture.utf8)) }
        let products = try await service.search("Fixture", endpoint: "")
        XCTAssertEqual(products.count, 1)
        XCTAssertTrue(products[0].ingredients.isEmpty)
        XCTAssertTrue(products[0].strength.contains("FIXTURE B: 1 %"))
        XCTAssertTrue(products[0].missing.contains { $0.contains("fully interpreted") })
    }
    func testPublicNoResultsAndRateLimitAreDifferent() async throws {
        FixtureProtocol.reply = { _ in (404, Data()) }
        let products = try await service.search("Missing Fixture", endpoint: "")
        XCTAssertTrue(products.isEmpty)
        FixtureProtocol.reply = { _ in (429, Data()) }
        do { _ = try await service.search("Fixture", endpoint: ""); XCTFail("Rate limit must be an error, not an empty result") }
        catch { XCTAssertTrue(error.localizedDescription.contains("rate limited")) }
    }
    func testConfiguredProviderFailureNeverSilentlySearchesUSDirectory() async {
        FixtureProtocol.reply = { request in
            XCTAssertEqual(request.url?.host, "medical.example.org")
            return (503, Data())
        }
        do { _ = try await service.search("Fixture", endpoint: "https://medical.example.org"); XCTFail("Must preserve provider failure") } catch {}
    }
    func testDirectoryStrengthParserDoesNotInventConcentrationOrConvertIU() {
        XCTAssertNil(ProductService.directoryIngredient(.init(name: "Fixture", strength: "500 mg"), formulation: "INJECTION"))
        XCTAssertNil(ProductService.directoryIngredient(.init(name: "Fixture", strength: "100 IU/1"), formulation: "TABLET"))
        XCTAssertNil(ProductService.directoryIngredient(.init(name: "Fixture", strength: "5 mg/1"), formulation: "INJECTION"))
        let micrograms = ProductService.directoryIngredient(.init(name: "Fixture", strength: "250 mcg/1"), formulation: "CAPSULE")
        XCTAssertEqual(micrograms?.unit, .microgram)
        XCTAssertEqual(micrograms?.productUnit, .capsule)
    }

}
