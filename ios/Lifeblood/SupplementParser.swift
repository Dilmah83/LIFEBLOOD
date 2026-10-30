import Foundation

// Reads labelled quantities; does not classify loose pills, infer nutrients from a
// brand, convert IU, resolve chemical equivalences, or align separated table columns.
enum SupplementParser {
    static func parse(_ input: [PrescriptionLine]) -> PrescriptionParseResult {
        guard input.count <= 500, input.reduce(0, { $0 + $1.text.count }) <= 40_000 else {
            return .init(drafts: [], warnings: ["Too much text. Photograph one supplement label at a time."])
        }
        let lines = input.map { PrescriptionLine(text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines), confidence: $0.confidence) }.filter { !$0.text.isEmpty }
        guard !lines.isEmpty else { return .init(drafts: [], warnings: ["No readable label. Photograph the product name and ingredient/serving panel; a loose pill cannot be reliably identified by appearance."]) }
        func has(_ pattern: String, _ text: String) -> Bool { !PrescriptionParser.matches(pattern, in: text).isEmpty }
        let servingPattern = #"(?:serving size\s*:?\s*|amounts? per\s+|ingredients per\s+)([0-9]+(?:\.[0-9]+)?)\s*(tablets?|capsules?|softgels?|mL)\b"#
        var basis: (Decimal, DoseUnit)?
        var basisIndex: Int?
        var servingText = ""
        var warnings = ["Label recognition is unverified. Compare every ingredient, amount and serving size with the original pack before saving.", "Read the bottle/pack label, not the pill's colour or shape. Appearance does not reliably identify a vitamin or its strength.", "Ingredient synonyms, chemical forms and equivalent amounts require confirmation. No IU-to-mass or salt-to-elemental conversion is made."]
        var candidates: [(Decimal, DoseUnit, Int, String)] = []
        for (index, line) in lines.enumerated() where line.confidence >= 0.85 {
            let each = PrescriptionParser.matches(#"\beach\s+(?:hard\s+|soft\s+)?(?:tablet|capsule|softgel)\s+contains\b"#, in: line.text).first
            let explicit = PrescriptionParser.matches(servingPattern, in: line.text).first
            if let each {
                let unit: DoseUnit = has(#"\btablet\b"#, each) ? .tablet : .capsule
                candidates.append((1, unit, index, each))
            } else if let explicit {
                guard let number = PrescriptionParser.matches(#"[0-9]+(?:\.[0-9]+)?"#, in: explicit).first, let amount = Decimal(string: number), amount > 0 else { continue }
                let unit: DoseUnit = has(#"\btablets?\b"#, explicit) ? .tablet : (has(#"\bmL\b"#, explicit) ? .mL : .capsule)
                candidates.append((amount, unit, index, explicit))
            }
        }
        if let first = candidates.first, candidates.allSatisfy({ $0.0 == first.0 && $0.1 == first.1 }) {
            basis = (first.0, first.1); basisIndex = first.2; servingText = first.3
        } else if !candidates.isEmpty { warnings.append("Conflicting serving/ingredient bases found. No ingredient quantities were populated; enter them manually after checking the pack.") }
        if basis == nil { warnings.append("No single explicit serving size or per-tablet/capsule basis was confirmed. Ingredient quantities remain blank rather than guessing a serving.") }
        let explicitName = lines.first { has(#"^(?:product|supplement)\s*:\s*\S"#, $0.text) }
        let headerPattern = #"^(?:supplement facts|nutrition|active ingredients|ingredients|serving|amount|directions|dosage|warning|caution|storage|each|adults|children|aust|manufactured|distributed|contains|patient|address|DOB|batch|expiry|other ingredients|excipients)\b|^[0-9]+\s*(?:tablets?|capsules?|softgels?)\b"#
        let front = lines.prefix(basisIndex ?? min(lines.count, 3)).filter { !has(headerPattern, $0.text) && $0.text.count <= 120 && $0.text.rangeOfCharacter(from: .letters) != nil }.prefix(2).map(\.text)
        let name = explicitName?.text.replacingOccurrences(of: #"^(?:product|supplement)\s*:\s*"#, with: "", options: [.regularExpression, .caseInsensitive]) ?? front.joined(separator: " ")
        var draft = PrescriptionDraft(name: name)
        draft.isSupplement = true; draft.servingDescription = servingText
        if let basis { draft.unit = basis.1; draft.formulation = basis.1 == .tablet ? "Tablet" : (basis.1 == .capsule ? (servingText.lowercased().contains("softgel") ? "Softgel" : "Capsule") : "Liquid") }
        let amountPattern = #"\b[0-9]+(?:\.[0-9]+)?\s*(?:micrograms?|mcg|µg|μg|mg|g|IU)\b"#
        var skipped: [String] = []
        if let basis, let start = basisIndex {
            for line in lines.dropFirst(start) {
                if has(#"^(?:other ingredients|inactive ingredients|excipients|directions|dosage|warnings?|caution|storage)\b"#, line.text) { break }
                let row = line.text.replacingOccurrences(of: #"^each\s+(?:hard\s+|soft\s+)?(?:tablet|capsule|softgel)\s+contains\s*:?\s*"#, with: "", options: [.regularExpression, .caseInsensitive])
                let amounts = PrescriptionParser.matches(amountPattern, in: row)
                if amounts.isEmpty {
                    if !row.isEmpty && !has(headerPattern, row) && !has(#"^(?:[†*%]|daily value|percent daily)"#, row) { skipped.append(row) }
                    continue
                }
                if line.confidence < 0.85 || amounts.count != 1 || has(#"\b(?:equiv|equivalent|blend|total|RAE|DFE|NE|RE)\b"#, row) || row.contains("<") || row.contains(">") {
                    skipped.append(row); continue
                }
                guard let amountText = amounts.first, let range = row.range(of: amountText) else { continue }
                let nutrient = String(row[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !nutrient.isEmpty, nutrient.count <= 200, !has(headerPattern, nutrient), !has(#"^(?:%|energy|calories|servings per)"#, nutrient), nutrient.rangeOfCharacter(from: .letters) != nil else { continue }
                guard let numeric = PrescriptionParser.matches(#"^[0-9]+(?:\.[0-9]+)?"#, in: amountText).first, let amount = Decimal(string: numeric), amount > 0 else { skipped.append(row); continue }
                let unit: DoseUnit
                if has(#"\bIU\b"#, amountText) { unit = .IU }
                else if has(#"\bmg\b"#, amountText) { unit = .mg }
                else if has(#"\bg\b"#, amountText) { unit = .g }
                else { unit = .microgram }
                let id = "manual:" + nutrient.lowercased()
                if draft.labelIngredients.contains(where: { $0.id == id }) { skipped.append(row); continue }
                draft.labelIngredients.append(Ingredient(id: id, name: nutrient, amount: amount, unit: unit, per: basis.0, productUnit: basis.1))
            }
        }
        // A partly recognised multivitamin must not masquerade as a complete composition.
        if !skipped.isEmpty {
            draft.labelIngredients = []
            warnings.append("Some ingredient rows were ambiguous, repeated or low-confidence. No partial ingredient list was populated. Enter the complete panel manually: " + skipped.prefix(10).joined(separator: "; "))
        }
        let amountOnly = lines.contains { has(#"^\s*[0-9]+(?:\.[0-9]+)?\s*(?:mg|g|mcg|µg|μg|micrograms?|IU)\b"#, $0.text) }
        if amountOnly {
            draft.labelIngredients = []
            warnings.append("Separated ingredient/amount columns may be present. Rows were not paired by proximity; enter the complete panel manually.")
        }
        let directionLines = lines.filter { has(#"^(?:take|adults?\s*:?\s*take)\b"#, $0.text) }
        if directionLines.count == 1, let line = directionLines.first {
            let parsed = PrescriptionParser.parse([PrescriptionLine(text: "Medicine: Supplement label", confidence: 1), PrescriptionLine(text: line.text.replacingOccurrences(of: #"^adults?\s*:?\s*"#, with: "", options: [.regularExpression, .caseInsensitive]), confidence: line.confidence)])
            if let directions = parsed.drafts.first { draft.quantity = directions.quantity; draft.directions = directions.directions; draft.asNeeded = directions.asNeeded; if !directions.quantity.isEmpty { draft.unit = directions.unit } }
        }
        if name.isEmpty { warnings.append("Product name was not clear. Enter the exact brand and product name before continuing.") }
        draft.strength = draft.labelIngredients.map { "\($0.name): \($0.amount) \($0.unit.rawValue) per \($0.per) \($0.productUnit.rawValue)" }.joined(separator: "; ")
        draft.warnings = warnings + ["Enter the dose and reminder schedule explicitly. The label's serving size is not automatically a recommended dose for you."]
        return .init(drafts: [draft], warnings: ["One supplement label draft created. Review all fields; nothing has been saved."])
    }
}
