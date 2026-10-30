import Foundation

enum DoseUnit: String, Codable, CaseIterable, Identifiable {
    case mg, microgram, g, mL, IU, tablet, capsule, serving
    var id: String { rawValue }
    var massInMg: Decimal? {
        switch self { case .mg: return 1; case .microgram: return Decimal(string: "0.001"); case .g: return 1000; default: return nil }
    }
}
struct Ingredient: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var amount: Decimal
    var unit: DoseUnit
    var form: String = ""
    // e.g. 5 mg per 1 tablet or 10 mg per 1 mL; never inferred from volume.
    var per: Decimal = 1
    var productUnit: DoseUnit = .tablet
    func delivered(quantity: Decimal, unit doseUnit: DoseUnit) -> Decimal? {
        guard per > 0, amount >= 0, quantity >= 0, productUnit == doseUnit else { return nil }
        return amount * quantity / per
    }
}
struct EvidenceSource: Codable, Identifiable, Equatable {
    var id: String
    var title: String
    var url: URL
    var checked: Date
    var jurisdiction: String
    var stale: Bool { checked < Date().addingTimeInterval(-90 * 86400) || checked > Date().addingTimeInterval(300) }
}
struct Product: Codable, Identifiable, Equatable {
    var id: String
    var brand: String
    var generic: String
    var strength: String
    var formulation: String
    var route: String
    var ingredients: [Ingredient]
    var verified: Bool = false
    var sources: [EvidenceSource] = []
    var sections: [String: String] = [:]
    var missing: [String] = []
    var conflicts: [String] = []
    var display: String { "\(brand) · \(strength) · \(formulation) · \(route)" }
}
struct RegimenItem: Codable, Identifiable {
    var id = UUID()
    var product: Product
    var quantity: Decimal = 1
    var unit: DoseUnit = .tablet
    var asNeeded = false
    var weekdays = [1, 2, 3, 4, 5, 6, 7]
    var times = ["08:00"]
    var start = Calendar.current.startOfDay(for: Date())
    var end: Date?
    var stopped = false
    var instructions = ""
    var legacyID: String?
    var legacyDose: String?
    func active(on date: Date, calendar: Calendar = .current) -> Bool {
        let day = calendar.startOfDay(for: date)
        return !stopped && day >= calendar.startOfDay(for: start) && (end.map { day <= calendar.startOfDay(for: $0) } ?? true)
    }
    func scheduled(on date: Date, calendar: Calendar = .current) -> Bool {
        active(on: date, calendar: calendar) && !asNeeded && weekdays.contains(calendar.component(.weekday, from: date))
    }
}
struct TakenDose: Codable, Identifiable {
    var id = UUID()
    var itemID: UUID
    var product: Product
    var quantity: Decimal
    var unit: DoseUnit
    var takenAt = Date()
    var scheduledAt: Date?
    var note = ""
}
struct PatientProfile: Codable {
    var age: Int?
    var sex = "Not supplied"
    var pregnancy = "Not supplied"
    var diet = "Not supplied"
    var conditions = ""
    var goals = ""
    var dietaryIntakeKnown = false
    var bloodTests: [BloodTest] = []
}
struct BloodTest: Codable, Identifiable {
    var id = UUID()
    var name: String
    var value: String
    var unit: String
    var date: Date
}
struct Archive: Codable {
    var version = 1
    var items: [RegimenItem] = []
    var doses: [TakenDose] = []
    var profile = PatientProfile()
    var legacyJSON: Data?
}
struct Finding: Identifiable, Codable {
    var id: String
    var title: String
    var products: [String]
    var ingredients: [String]
    var consequence: String
    var severity: String
    var evidence: String
    var advice: String
    var spacing: String
    var sources: [EvidenceSource]
}
struct IngredientTotal: Identifiable {
    var id: String
    var name: String
    var amount: Decimal
    var unit: DoseUnit
    var contributions: [String]
}
struct ClinicalResult: Codable {
    var coverage: String
    var complete: Bool
    var findings: [Finding]
    var checked: Date
}
struct Recommendation: Identifiable {
    var id: String
    var title: String
    var reason: String
    var evidence: String
    var nextStep: String
    var missing: String
}
