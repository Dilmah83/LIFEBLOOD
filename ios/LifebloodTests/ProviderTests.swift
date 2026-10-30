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
}
