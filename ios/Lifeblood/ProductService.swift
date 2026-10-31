import Foundation

// The app has no provider secret. A configured HTTPS backend must use licensed structured
// product data; search transmits only the query, never a patient profile or regimen.
struct ProductService {
    var configuration: URLSessionConfiguration = .ephemeral
    var useCache = false
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
        if endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let key = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if useCache, let cached = await ProductSearchCache.shared.get(key) { return cached }
            let result = try await searchPublicProducts(query)
            if useCache && !result.isEmpty { await ProductSearchCache.shared.put(key, products: result) }
            return result
        }
        guard let base = URL(string: endpoint), base.scheme == "https", base.host != nil, base.user == nil, base.password == nil else {
            throw LookupError.unavailable("No secure product provider configured. Australian product research and autocomplete are unavailable. Manual entry remains unverified.")
        }
        var url = URLComponents(url: base.appendingPathComponent("products"), resolvingAgainstBaseURL: false)!
        url.queryItems = [URLQueryItem(name: "q", value: String(query.prefix(120))), URLQueryItem(name: "jurisdiction", value: "AU")]
        var request = URLRequest(url: url.url!); request.timeoutInterval = 15; request.cachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration, delegate: RejectRedirects(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
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
        let session = URLSession(configuration: configuration, delegate: RejectRedirects(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
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

// Never redirect product queries or sensitive regimen payloads to a different endpoint.
final class RejectRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

// Public, keyless structured product directory. US results are never represented as
// Australian products or a clinical interaction check. A configured AU provider is
// never silently replaced if that provider fails.
extension ProductService {
    struct NDCDirectory: Decodable {
        let results: [NDCProduct]
    }
    struct NDCProduct: Decodable {
        let product_ndc: String?
        let finished: Bool?
        let brand_name: String?
        let generic_name: String?
        let dosage_form: String?
        let route: [String]?
        let labeler_name: String?
        let active_ingredients: [NDCIngredient]?
    }
    struct NDCIngredient: Decodable {
        let name: String
        let strength: String?
    }
    func searchPublicProducts(_ query: String, generic: Bool = false, allowSynonym: Bool = true) async throws -> [Product] {
        let plan = MedicineSearch(query)
        guard plan.name.count >= 2 else { throw LookupError.unavailable("Enter at least two letters of the brand or generic name.") }
        var url = URLComponents(string: "https://api.fda.gov/drug/ndc.json")!
        url.queryItems = [URLQueryItem(name: "search", value: plan.expression(generic: generic)), URLQueryItem(name: "limit", value: "50")]
        var request = URLRequest(url: url.url!); request.timeoutInterval = 15; request.cachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration, delegate: RejectRedirects(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LookupError.unavailable("Could not connect to the public product directory. Try again or enter manually.") }
        if http.statusCode == 404 {
            if !generic { return try await searchPublicProducts(query, generic: true, allowSynonym: allowSynonym) }
            if allowSynonym { return try await searchSynonym(plan) }
            return []
        }
        guard http.statusCode == 200 else {
            throw LookupError.unavailable(http.statusCode == 429 ? "The FDA product directory is rate limited. Try again shortly or enter manually." : "The FDA product directory is unavailable. Try again or enter manually.")
        }
        guard data.count < 2_000_000 else { throw LookupError.unavailable("Product response was too large. Refine your search.") }
        let rows = try JSONDecoder().decode(NDCDirectory.self, from: data).results
        guard rows.count <= 100 else { throw LookupError.unavailable("Too many results. Refine your search.") }
        var seen = Set<String>()
        let products: [Product] = rows.compactMap { row in
            guard row.finished == true, let ndc = row.product_ndc, !ndc.isEmpty, seen.insert(ndc).inserted,
                  let formulation = row.dosage_form, !formulation.isEmpty,
                  let routes = row.route, !routes.isEmpty,
                  let brand = row.brand_name ?? row.generic_name, !brand.isEmpty else { return nil }
            let raw = row.active_ingredients ?? []
            let parsed = raw.compactMap { Self.directoryIngredient($0, formulation: formulation) }
            let complete = !raw.isEmpty && parsed.count == raw.count
            var sourceURL = URLComponents(string: "https://api.fda.gov/drug/ndc.json")!
            sourceURL.queryItems = [URLQueryItem(name: "search", value: "product_ndc:\"\(ndc)\"")]
            var missing = ["US directory entry; not verified against your Australian pack. A directory listing does not establish FDA approval.", "The directory does not supply PI/CMI, side-effect classification, individual suitability or comprehensive interactions.", "Manufacturer / labeler: " + (row.labeler_name ?? "Not supplied")]
            if !complete { missing.append("Structured ingredient amounts could not be fully interpreted. No ingredient totals will be calculated until every ingredient and strength basis is confirmed manually.") }
            let strengths = raw.map { $0.name + ": " + ($0.strength ?? "strength not supplied") }.joined(separator: "; ")
            return Product(id: "fda-ndc:" + ndc, brand: brand, generic: row.generic_name ?? "Not supplied", strength: strengths.isEmpty ? "Strength not supplied" : strengths, formulation: formulation, route: routes.joined(separator: ", "), ingredients: complete ? parsed : [], verified: false, sources: [EvidenceSource(id: "fda-ndc:" + ndc, title: "US FDA National Drug Code directory — " + ndc, url: sourceURL.url!, checked: Date(), jurisdiction: "US")], missing: missing)
        }
        try products.forEach(Self.validate)
        if products.isEmpty && !generic { return try await searchPublicProducts(query, generic: true, allowSynonym: allowSynonym) }
        return Array(products.sorted { plan.rank($0) > plan.rank($1) }.prefix(30))
    }
    static func directoryIngredient(_ raw: NDCIngredient, formulation: String) -> Ingredient? {
        // Only explicit mass/unit or mass/volume expressions are recognised. No IU
        // conversion, percentage conversion or inferred injection concentration.
        guard let strength = raw.strength, raw.name.count <= 500, !raw.name.isEmpty else { return nil }
        let pattern = #"^\s*([0-9]+(?:\.[0-9]+)?)\s*(mg|mcg|ug|microgram|g)\s*/\s*([0-9]+(?:\.[0-9]+)?)?\s*(mL)?\s*$"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
              let match = regex.firstMatch(in: strength, range: NSRange(strength.startIndex..., in: strength)) else { return nil }
        func group(_ n: Int) -> String { Range(match.range(at: n), in: strength).map { String(strength[$0]) } ?? "" }
        guard let amount = Decimal(string: group(1)), amount > 0 else { return nil }
        let perText = group(3)
        let per = perText.isEmpty ? Decimal(1) : Decimal(string: perText)
        guard let per, per > 0 else { return nil }
        let unit: DoseUnit
        switch group(2).lowercased() { case "mg": unit = .mg; case "g": unit = .g; default: unit = .microgram }
        let productUnit: DoseUnit
        if !group(4).isEmpty { productUnit = .mL }
        else {
            // NDC /1 means one discrete dosage unit, only when its actual dosage
            // form is explicitly a tablet or capsule. Unknown forms stay unparsed.
            guard !perText.isEmpty else { return nil }
            let form = formulation.uppercased()
            if form == "TABLET" || form.hasPrefix("TABLET,") { productUnit = .tablet }
            else if form == "CAPSULE" || form.hasPrefix("CAPSULE,") { productUnit = .capsule }
            else { return nil }
        }
        return Ingredient(id: "fda-name:" + raw.name.lowercased(), name: raw.name, amount: amount, unit: unit, per: per, productUnit: productUnit)
    }
}

extension ProductService {
    struct RxIDs: Decodable { struct Group: Decodable { let rxnormId: [String]? }; let idGroup: Group }
    struct RxProperties: Decodable { struct Properties: Decodable { let name: String; let tty: String }; let properties: Properties }
    func searchSynonym(_ plan: MedicineSearch) async throws -> [Product] {
        var components = URLComponents(string: "https://rxnav.nlm.nih.gov/REST/rxcui.json")!
        components.queryItems = [URLQueryItem(name: "name", value: plan.name), URLQueryItem(name: "search", value: "0")]
        let session = URLSession(configuration: configuration, delegate: RejectRedirects(), delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        do {
            let (data, response) = try await session.data(for: URLRequest(url: components.url!, timeoutInterval: 8))
            guard (response as? HTTPURLResponse)?.statusCode == 200, data.count < 200_000,
                  let id = try JSONDecoder().decode(RxIDs.self, from: data).idGroup.rxnormId?.first,
                  id.allSatisfy(\.isNumber) else { return [] }
            let (properties, result) = try await session.data(for: URLRequest(url: URL(string: "https://rxnav.nlm.nih.gov/REST/rxcui/\(id)/properties.json")!, timeoutInterval: 8))
            guard (result as? HTTPURLResponse)?.statusCode == 200, properties.count < 200_000 else { return [] }
            let value = try JSONDecoder().decode(RxProperties.self, from: properties).properties
            // Only exact terminology matches for ingredients, never approximate brand substitution.
            guard ["IN", "PIN"].contains(value.tty), value.name.lowercased() != plan.name else { return [] }
            var products = try await searchPublicProducts(value.name + " " + plan.strength, allowSynonym: false)
            for index in products.indices {
                products[index].missing.append("Search term \(plan.name) matched the NLM ingredient name \(value.name). These are US reference products, not confirmation of an Australian brand.")
                products[index].sources.append(EvidenceSource(id: "rxnorm:" + id, title: "NLM RxNorm ingredient terminology", url: URL(string: "https://rxnav.nlm.nih.gov/REST/rxcui/\(id)/properties.json")!, checked: Date(), jurisdiction: "US"))
            }
            return products
        } catch is CancellationError { throw CancellationError() }
        catch { return [] } // Optional terminology unavailable; never fabricate matches.
    }
}
