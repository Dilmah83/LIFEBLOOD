import Foundation

// The app has no provider secret. A configured HTTPS backend must use licensed structured
// product data; search transmits only the query, never a patient profile or regimen.
struct ProductService {
    enum LookupError: LocalizedError {
        case unavailable(String)
        var errorDescription: String? { if case .unavailable(let message) = self { return message }; return nil }
    }
    static let sectionNames = ["Main uses", "Common side effects", "Serious adverse effects", "Contraindications", "Precautions", "Monitoring", "Interactions", "Food and timing"]
    static func validate(_ product: Product) throws {
        guard !product.id.isEmpty, !product.brand.isEmpty, product.brand.count <= 500,
              !product.strength.isEmpty, !product.formulation.isEmpty, !product.route.isEmpty,
              product.ingredients.count <= 100, product.sections.values.allSatisfy({ $0.count <= 100_000 }),
              product.ingredients.allSatisfy({ !$0.id.isEmpty && !$0.name.isEmpty && $0.amount > 0 && $0.per > 0 }),
              product.sources.allSatisfy({ $0.url.scheme == "https" && $0.url.host != nil && $0.url.user == nil && $0.url.password == nil }),
              !product.verified || (!product.ingredients.isEmpty && !product.sources.isEmpty && product.conflicts.isEmpty) else {
            throw LookupError.unavailable("Product data was incomplete or invalid. Confirm manually with your pharmacist.")
        }
    }
    func search(_ query: String, endpoint: String) async throws -> [Product] {
        guard let base = URL(string: endpoint), base.scheme == "https", base.host != nil, base.user == nil, base.password == nil else {
            throw LookupError.unavailable("No secure product provider configured. Australian product research and autocomplete are unavailable. Manual entry remains unverified.")
        }
        var url = URLComponents(url: base.appendingPathComponent("products"), resolvingAgainstBaseURL: false)!
        url.queryItems = [URLQueryItem(name: "q", value: String(query.prefix(120))), URLQueryItem(name: "jurisdiction", value: "AU")]
        var request = URLRequest(url: url.url!); request.timeoutInterval = 15; request.cachePolicy = .reloadIgnoringLocalCacheData
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw LookupError.unavailable("Provider unavailable or rate limited. No live result was substituted; try again or enter manually.")
        }
        guard data.count < 2_000_000 else { throw LookupError.unavailable("Provider response was too large.") }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let products = try decoder.decode([Product].self, from: data)
        guard products.count <= 20 else { throw LookupError.unavailable("Too many results; refine the product name.") }
        try products.forEach(Self.validate)
        return products.sorted { ($0.sources.contains { $0.jurisdiction == "AU" } ? 0 : 1) < ($1.sources.contains { $0.jurisdiction == "AU" } ? 0 : 1) }
    }
}

extension ProductService {
    struct ClinicalProduct: Encodable {
        let id: String
        let quantity: Decimal
        let unit: DoseUnit
        let weekdays: [Int]
        let times: [String]
        let asNeeded: Bool
    }
    struct ClinicalRequest: Encodable { let products: [ClinicalProduct] }
    func check(_ items: [RegimenItem], endpoint: String) async throws -> ClinicalResult {
        guard let base = URL(string: endpoint), base.scheme == "https", base.host != nil, base.user == nil, base.password == nil else {
            throw LookupError.unavailable("No secure clinical provider configured. Local limited checks only.")
        }
        let eligible = items.filter { !$0.stopped && ($0.end.map { $0 >= Calendar.current.startOfDay(for: Date()) } ?? true) }
        guard !eligible.isEmpty, eligible.allSatisfy({ $0.product.verified && !$0.product.id.hasPrefix("manual:") && !$0.product.id.hasPrefix("legacy:") && !$0.product.sources.contains(where: \.stale) && $0.quantity > 0 }) else {
            throw LookupError.unavailable("Full regimen checking unavailable: confirm every product, source and dose. No partial list was submitted as a complete regimen.")
        }
        let payload = ClinicalRequest(products: eligible.map { ClinicalProduct(id: $0.product.id, quantity: $0.quantity, unit: $0.unit, weekdays: $0.weekdays, times: $0.times, asNeeded: $0.asNeeded) })
        var request = URLRequest(url: base.appendingPathComponent("check")); request.httpMethod = "POST"; request.httpBody = try JSONEncoder().encode(payload); request.setValue("application/json", forHTTPHeaderField: "Content-Type"); request.timeoutInterval = 20
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200, data.count < 2_000_000 else { throw LookupError.unavailable("Clinical service unavailable or rate limited. No comprehensive check performed.") }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let result = try decoder.decode(ClinicalResult.self, from: data)
        guard !result.coverage.isEmpty, result.checked <= Date().addingTimeInterval(300), result.checked >= Date().addingTimeInterval(-86400), result.findings.count <= 500,
              result.findings.allSatisfy({ finding in
                  ["Urgent review", "Review", "Information"].contains(finding.severity) && ["Documented", "Theoretical", "Limited evidence"].contains(finding.evidence) && !finding.consequence.isEmpty && !finding.advice.isEmpty && !finding.spacing.isEmpty && !finding.sources.isEmpty && finding.sources.allSatisfy { $0.url.scheme == "https" && $0.url.host != nil && $0.url.user == nil && $0.url.password == nil && !$0.stale }
              }) else { throw LookupError.unavailable("Clinical result missing current evidence or coverage. Local limited checks only.") }
        return result
    }
}
