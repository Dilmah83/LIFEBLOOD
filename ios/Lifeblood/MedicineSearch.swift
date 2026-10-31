import Foundation

struct MedicineSearch {
    let name: String
    let terms: [String]
    let strength: String
    init(_ input: String) {
        let raw = String(input.prefix(120)).lowercased()
        strength = PrescriptionParser.matches(#"\b[0-9]+(?:\.[0-9]+)?\s*(?:mg|mcg|micrograms?|g|ml|iu)\b"#, in: raw).first ?? ""
        let withoutDose = raw.replacingOccurrences(of: #"\b[0-9]+(?:\.[0-9]+)?\s*(?:mg|mcg|micrograms?|g|ml|iu)\b"#, with: " ", options: .regularExpression)
        let clean = withoutDose.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || $0.value == 45 ? String($0) : " " }.joined()
        terms = clean.split(whereSeparator: { $0.isWhitespace }).map(String.init).filter { !$0.allSatisfy(\.isNumber) }
        name = terms.joined(separator: " ")
    }
    var releaseHint: String? { terms.count > 1 ? terms.first { ["xr", "er", "sr", "mr", "cr"].contains($0) } : nil }
    func expression(generic: Bool = false) -> String {
        let field = generic ? "generic_name" : "brand_name"
        let tokens = terms.filter { $0 != releaseHint }.map { $0.replacingOccurrences(of: "-", with: "\\-") + "*" }.joined(separator: " AND ")
        return "\(field):(\(tokens)) AND finished:true"
    }
    func rank(_ product: Product) -> Int {
        let brand = product.brand.lowercased(), generic = product.generic.lowercased()
        var score = brand == name ? 1000 : (brand.hasPrefix(name) ? 700 : (generic.hasPrefix(name) ? 400 : 0))
        score += product.ingredients.count == 1 ? 100 : 0
        let strengths = PrescriptionParser.matches(#"\b[0-9]+(?:\.[0-9]+)?\s*(?:mg|mcg|micrograms?|g|ml|iu)\b"#, in: product.strength.lowercased()).map { $0.filter { !$0.isWhitespace } }
        if !strength.isEmpty && strengths.contains(strength.filter { !$0.isWhitespace }) { score += 500 }
        if releaseHint != nil && product.formulation.lowercased().contains("release") { score += 500 }
        return score
    }
}
actor ProductSearchCache {
    static let shared = ProductSearchCache()
    private var values: [String: (Date, [Product])] = [:]
    func get(_ key: String) -> [Product]? {
        guard let value = values[key], Date().timeIntervalSince(value.0) < 600 else { return nil }
        return value.1
    }
    func put(_ key: String, products: [Product]) {
        if values.count >= 50 { values.removeAll() }
        values[key] = (Date(), products)
    }
}
