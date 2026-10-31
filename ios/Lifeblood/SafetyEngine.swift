import Foundation

struct SafetyEngine {
    static func rank(_ severity: String) -> Int { ["Urgent review": 0, "Review": 1, "Information": 2][severity] ?? 3 }
    static let coverage = "Limited mode: checks entered ingredient duplicates and calculable intake only. Drug, supplement, food, alcohol, absorption, overlapping therapeutic effects and individual dose-limit checks require a clinical provider. No interactions identified in the sources checked does not establish safety."
    static func totals(_ entries: [(Product, Decimal, DoseUnit)]) -> (totals: [IngredientTotal], missing: [String]) {
        var result: [String: IngredientTotal] = [:]
        var missing: [String] = []
        for (product, quantity, unit) in entries {
            if product.ingredients.isEmpty { missing.append("\(product.brand): ingredients unavailable") }
            for ingredient in product.ingredients {
                guard let delivered = ingredient.delivered(quantity: quantity, unit: unit) else {
                    missing.append("\(product.brand), \(ingredient.name): dose unit does not match confirmed strength basis")
                    continue
                }
                let normalizedUnit: DoseUnit = ingredient.unit.massInMg == nil ? ingredient.unit : .mg
                let normalizedAmount = delivered * (ingredient.unit.massInMg ?? 1)
                let key = ingredient.id + "|" + normalizedUnit.rawValue
                var total = result[key] ?? IngredientTotal(id: key, name: ingredient.name, amount: 0, unit: normalizedUnit, contributions: [])
                total.amount += normalizedAmount
                total.contributions.append("\(product.brand): \(normalizedAmount) \(normalizedUnit.rawValue)")
                result[key] = total
            }
        }
        return (result.values.sorted { $0.name < $1.name }, Array(Set(missing)).sorted())
    }
    static func scheduledTotals(items: [RegimenItem], on date: Date) -> (totals: [IngredientTotal], missing: [String]) {
        totals(items.filter { $0.scheduled(on: date) }.map { ($0.product, $0.quantity * Decimal($0.times.count), $0.unit) })
    }
    static func actualTotals(doses: [TakenDose], on date: Date) -> (totals: [IngredientTotal], missing: [String]) {
        totals(doses.filter { Calendar.current.isDate($0.takenAt, inSameDayAs: date) }.map { ($0.product, $0.quantity, $0.unit) })
    }
    static func findings(items: [RegimenItem], on date: Date = Date()) -> [Finding] {
        let active = items.filter { $0.active(on: date) }
        var groups: [String: [(RegimenItem, Ingredient)]] = [:]
        for item in active {
            for ingredient in item.product.ingredients { groups[ingredient.id, default: []].append((item, ingredient)) }
        }
        var output: [Finding] = []
        for (id, entries) in groups where Set(entries.map { $0.0.id }).count > 1 {
            output.append(Finding(id: "duplicate:" + id, title: "Review duplicate ingredient", products: entries.map { $0.0.product.brand }, ingredients: [entries[0].1.name], consequence: "These products contain the same entered ingredient. Taking them together may duplicate dosing, even on different schedules or as needed.", severity: "Review", evidence: entries.allSatisfy { $0.0.product.verified } ? "Confirmed product composition" : "User-entered composition; unverified", advice: "Ask your pharmacist or prescriber whether this overlap is intended. Do not change prescribed treatment yourself.", spacing: "Spacing does not remove duplicate exposure.", sources: entries.flatMap { $0.0.product.sources }))
        }
        for item in active where !item.product.verified || item.product.ingredients.isEmpty || item.product.sources.contains(where: \.stale) || !item.product.conflicts.isEmpty {
            output.append(Finding(id: "incomplete:\(item.id)", title: "Product information needs review", products: [item.product.brand], ingredients: item.product.ingredients.map(\.name), consequence: "Unverified, missing, stale or conflicting product data limits screening.", severity: "Information", evidence: "Incomplete", advice: "Confirm the exact pack and current Australian PI/CMI with your pharmacist.", spacing: "Not assessed.", sources: item.product.sources))
        }
        return output.sorted { rank($0.severity) < rank($1.severity) }
    }
    static func recommendations(profile: PatientProfile, items: [RegimenItem]) -> [Recommendation] {
        if profile.diet == "Vegan" {
            let existing = items.filter { $0.active(on: Date()) }.flatMap { $0.product.ingredients }.contains { $0.name.lowercased().contains("b12") || $0.name.lowercased().contains("cobalamin") }
            return [Recommendation(id: "b12-assessment", title: existing ? "Review existing vitamin B12 coverage" : "Consider a vitamin B12 assessment", reason: "A vegan dietary pattern can provide insufficient reliable vitamin B12. This does not diagnose deficiency.", evidence: "General dietary guidance; not a personalised prescription.", nextStep: existing ? "B12 is already entered. Review adequacy, duplication and blood tests with a dietitian or clinician; do not add another product automatically." : "Discuss fortified foods, testing and supplementation with a dietitian or clinician before choosing a product. Interaction screening is unavailable.", missing: "Intake, absorption, relevant medicines, test results and clinical assessment. No dose recommendation is made.")]
        }
        return [Recommendation(id: "none", title: "No additional supplement indicated from the available information", reason: "Available information does not establish a supported individual need.", evidence: "Insufficient for a personalised recommendation.", nextStep: "Review food sources and seek assessment or testing when clinically indicated. Supplements can interact with medicines.", missing: "Age, dietary intake, conditions, pregnancy status and current blood-test interpretation may be needed. Interaction coverage is incomplete.")]
    }
}
