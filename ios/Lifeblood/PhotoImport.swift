import Foundation

// Shared by the single-screen photo review and compact product-search confirmation.
enum PhotoImport {
    enum ImportError: LocalizedError {
        case invalid(String)
        var errorDescription: String? { if case .invalid(let text) = self { return text }; return nil }
    }
    static func quantity(_ text: String) throws -> Decimal {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty { return 0 } // Unknown is not one dose, PRN or a daily schedule.
        guard value.range(of: #"^[0-9]+(?:\.[0-9]+)?$"#, options: .regularExpression) != nil,
              let amount = Decimal(string: value), amount > 0 else {
            throw ImportError.invalid("The dose is unclear. Clear it to add without a dose, or enter the confirmed quantity.")
        }
        return amount
    }
    static func item(from draft: PrescriptionDraft, product: Product? = nil) throws -> RegimenItem {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw ImportError.invalid("No product name or readable ingredient was found. Retake the photo.") }
        if draft.isSupplement && draft.labelIngredients.isEmpty && product == nil {
            throw ImportError.invalid("Photograph the ingredient panel and serving size on the back of the pack. A brand photo is not enough to identify the contents.")
        }
        var p = product ?? Product(id: "manual:" + UUID().uuidString, brand: name, generic: "", strength: draft.strength, formulation: draft.formulation, route: draft.route, ingredients: draft.labelIngredients)
        guard draft.labelIngredients.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.amount > 0 && $0.per > 0 }) else { throw ImportError.invalid("Check the ingredient names, amounts and serving basis, or retake the panel.") }
        if product == nil { p.ingredients = draft.labelIngredients.map { value in var ingredient = value; ingredient.id = "manual:" + value.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(); return ingredient }; p.verified = false; p.missing = ["User-accepted photo text; product composition is not independently verified."] }
        let amount = try quantity(draft.quantity)
        var item = RegimenItem(product: p)
        item.quantity = amount; item.unit = draft.unit
        item.times = []; item.weekdays = []; item.asNeeded = draft.asNeeded
        item.instructions = [draft.directions, draft.servingDescription.isEmpty ? "" : "Label serving: " + draft.servingDescription].filter { !$0.isEmpty }.joined(separator: "\n")
        if amount == 0 { item.legacyDose = "Dose not confirmed" }
        return item
    }
}

// Only combines text boxes on the same physical row of the same page. No pairing
// by nearby reading order: missing geometry keeps the conservative manual fallback.
enum LabelRows {
    static func assemble(_ lines: [PrescriptionLine]) -> [PrescriptionLine] {
        guard lines.allSatisfy({ line in
            guard let x = line.minX, let y = line.midY, let h = line.height else { return false }
            return x.isFinite && y.isFinite && h.isFinite && (0...1).contains(x) && (0...1).contains(y) && h > 0 && h <= 1
        }) else { return lines }
        var rows: [[PrescriptionLine]] = []
        for line in lines.sorted(by: { $0.page != $1.page ? $0.page < $1.page : $0.midY! > $1.midY! }) {
            if let last = rows.last, let anchor = last.first, anchor.page == line.page,
               abs(anchor.midY! - line.midY!) <= min(anchor.height!, line.height!) * 0.4,
               max(anchor.height!, line.height!) / min(anchor.height!, line.height!) <= 2 {
                rows[rows.count - 1].append(line)
            } else { rows.append([line]) }
        }
        return rows.map { row in
            let sorted = row.sorted { $0.minX! < $1.minX! }
            return PrescriptionLine(text: sorted.map(\.text).joined(separator: " "), confidence: sorted.map(\.confidence).min() ?? 0, page: sorted[0].page)
        }
    }
}
