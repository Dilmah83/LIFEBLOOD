import Foundation

struct PrescriptionLine: Sendable {
    let text: String
    let confidence: Float
    var minX: Double? = nil
    var midY: Double? = nil
    var height: Double? = nil
    var page: Int = 0
}
struct PrescriptionDraft: Identifiable, Equatable {
    let id = UUID()
    var name: String
    var strength = ""
    var formulation = ""
    var route = ""
    var quantity = ""
    var unit: DoseUnit = .tablet
    var asNeeded = false
    var directions = ""
    var warnings: [String] = []
    var reviewed = false
    var isSupplement = false
    var labelIngredients: [Ingredient] = []
    var servingDescription = ""
    var ingredientPanelText: [String] = []
}
struct PrescriptionParseResult {
    var drafts: [PrescriptionDraft]
    var warnings: [String]
}

// Conservative text extraction, not prescribing or product identification. Names and
// strengths are suggestions to review. Ingredients, dates, intervals and concentrations
// are never derived as medical facts. Raw OCR/patient identifiers are not persisted.
enum PrescriptionParser {
    static func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }
    static func parse(_ input: [PrescriptionLine]) -> PrescriptionParseResult {
        guard input.count <= 500, input.reduce(0, { $0 + $1.text.count }) <= 40_000 else {
            return .init(drafts: [], warnings: ["Too much text to review reliably. Scan one prescription at a time."])
        }
        let lines = input.map { PrescriptionLine(text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines), confidence: $0.confidence) }.filter { !$0.text.isEmpty }
        let strengthPattern = #"\b[0-9]+(?:\.[0-9]+)?\s*(?:micrograms?|mcg|µg|μg|mg|g|IU|units?)(?:\s*/\s*(?:[0-9]+(?:\.[0-9]+)?\s*)?mL)?\b"#
        var drafts: [PrescriptionDraft] = []
        for line in lines {
            let text = line.text
            guard text.count <= 300 else { continue }
            let labelled = !matches(#"^(?:medicine|medication|drug|product)\s*:\s*"#, in: text).isEmpty
            let strengths = matches(strengthPattern, in: text)
            let isDirections = !matches(#"^(?:take|inject|apply|inhale|instil|swallow|directions|dose|sig)\b"#, in: text).isEmpty
            guard !isDirections, labelled || !strengths.isEmpty else { continue }
            let stripped = text.replacingOccurrences(of: #"^(?:medicine|medication|drug|product)\s*:\s*"#, with: "", options: .regularExpression.union(.caseInsensitive))
            var name = stripped
            if strengths.count == 1, let range = stripped.range(of: strengths[0]) { name = String(stripped[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines) }
            // Reject identity/administration headers, addresses and isolated strength lines.
            guard !name.isEmpty, name.count <= 200,
                  matches(#"^(?:name|patient|doctor|prescriber|address|DOB|date|age|weight|strength|quantity|dispense|repeats|total|phone|fax|ABN|PBS|Medicare|warning|caution|contains|each)\b"#, in: name).isEmpty,
                  name.rangeOfCharacter(from: .letters) != nil else { continue }
            var draft = PrescriptionDraft(name: name)
            draft.strength = strengths.joined(separator: " + ")
            if !matches(#"\btablets?\b"#, in: text).isEmpty { draft.formulation = "Tablet"; draft.unit = .tablet }
            else if !matches(#"\bcapsules?\b"#, in: text).isEmpty { draft.formulation = "Capsule"; draft.unit = .capsule }
            else if !matches(#"\b(injection|injectable)\b"#, in: text).isEmpty { draft.formulation = "Injection"; draft.unit = .mL }
            draft.warnings = ["Photo text is unverified. Confirm the exact product, all ingredients, strength and formulation against the prescription and pack.", "Reminder times, weekdays and start/end dates must be entered explicitly. No schedule was inferred."]
            if line.confidence < 0.85 { draft.warnings.append("Low-confidence text recognition. Check every character, especially decimal points and mg versus micrograms.") }
            if strengths.count > 1 { draft.warnings.append("Multiple strengths or a combination product may be present. The full medicine line was retained; confirm every ingredient separately.") }
            if strengths.isEmpty { draft.warnings.append("No readable strength found.") }
            drafts.append(draft)
        }
        if drafts.count > 10 { return .init(drafts: [], warnings: ["More than ten possible medicine lines were found. Scan one prescription at a time; none were added."]) }
        var warnings = ["Nothing is added or changed until you review and save it. Do not change prescribed treatment based on a scan."]
        if drafts.count == 1 {
            let directionLines = lines.filter { !matches(#"\b(?:take|inject|apply|inhale|instil|swallow)\b"#, in: $0.text).isEmpty }
            if directionLines.count == 1, let line = directionLines.first {
                // Keep only the instruction clause, never a whole page or personal header.
                let clauses = matches(#"\b(?:take|inject|apply|inhale|instil|swallow)\b[^\n]*"#, in: line.text)
                if let clause = clauses.first, clause.count <= 500 {
                    drafts[0].directions = clause
                    drafts[0].asNeeded = !matches(#"\b(?:prn|as needed|when required|as required)\b"#, in: clause).isEmpty
                    let variable = !matches(#"\b(?:then|taper|alternate|alternating|increase|decrease|half|quarter)\b|[0-9]\s*[-–/]\s*[0-9]|[½¼¾]"#, in: clause).isEmpty
                    if variable { drafts[0].warnings.append("Variable, fractional or tapering dose detected. No dose quantity was populated; review with your pharmacist.") }
                    else if let quantity = matches(#"^(?:take|inject|apply|inhale|instil|swallow)\s+[0-9]+(?:\.[0-9]+)?\s*(?:tablets?|capsules?|mL)\b"#, in: clause).first {
                        drafts[0].quantity = matches(#"[0-9]+(?:\.[0-9]+)?"#, in: quantity).first ?? ""
                        if quantity.lowercased().contains("capsule") { drafts[0].unit = .capsule }
                        else if quantity.lowercased().contains("tablet") { drafts[0].unit = .tablet }
                        else { drafts[0].unit = .mL }
                    }
                    if line.confidence < 0.85 { drafts[0].quantity = ""; drafts[0].asNeeded = false; drafts[0].warnings.append("Directions have low recognition confidence. Dose and as-needed status require manual entry.") }
                    if line.confidence >= 0.85, !matches(#"\b(?:by mouth|orally)\b"#, in: clause).isEmpty { drafts[0].route = "Oral" }
                    else if line.confidence >= 0.85, !matches(#"\bsubcutaneously\b"#, in: clause).isEmpty { drafts[0].route = "Subcutaneous" }
                    else if line.confidence >= 0.85, !matches(#"\bintramuscularly\b"#, in: clause).isEmpty { drafts[0].route = "Intramuscular" }
                }
            } else { drafts[0].warnings.append("Directions are missing or ambiguous. No dose quantity was assigned.") }
        } else if drafts.count > 1 {
            warnings.append("Multiple possible medicines were found. Directions and doses have not been assigned to individual products; review each separately.")
        }
        if drafts.isEmpty { warnings.append("No clear medicine line found. Retake a sharp, well-lit photo or enter the product manually. Handwriting may not be recognised.") }
        return .init(drafts: drafts, warnings: warnings)
    }
}
