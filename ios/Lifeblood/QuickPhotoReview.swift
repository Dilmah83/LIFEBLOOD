import SwiftUI

struct QuickPhotoReview: View {
    @State var draft: PrescriptionDraft
    var product: Product? = nil
    let accept: (RegimenItem) -> Void
    let retake: () -> Void
    @State private var error = ""
    private var needsPanel: Bool { draft.isSupplement && draft.labelIngredients.isEmpty && product == nil }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(draft.isSupplement ? "Vitamin / supplement information" : (draft.name.isEmpty ? "Product name not read" : draft.name)).font(.headline)
            if draft.isSupplement && !draft.name.isEmpty { Text("Product: " + draft.name).font(.caption).foregroundStyle(.secondary) }
            if draft.isSupplement {
                Text("Ingredient information").font(.subheadline.bold())
                if needsPanel {
                    Label("Only branding or incomplete ingredients read. Photograph the ingredient panel and serving size on the BACK.", systemImage: "camera.viewfinder").foregroundStyle(.orange)
                } else {
                    ForEach(draft.labelIngredients) { ingredient in
                        Text("\(ingredient.name) · \(ingredient.amount) \(ingredient.unit.rawValue) per \(ingredient.per) \(ingredient.productUnit.rawValue)")
                    }
                    if !draft.servingDescription.isEmpty { Text(draft.servingDescription).font(.caption) }
                }
            } else if !draft.strength.isEmpty { Text(draft.strength) }
            if !draft.directions.isEmpty { Text(draft.directions) }
            Text(draft.quantity.isEmpty ? "Dose not read — added without a dose or reminders." : "Dose: \(draft.quantity) \(draft.unit.rawValue). No reminders until you choose times.").font(.caption).foregroundStyle(.secondary)
            Text(product?.verified == true ? "Check this exact strength and formulation match your pack." : "Photo / reference information is unverified. Accept only if it matches your label.").font(.caption)
            DisclosureGroup("Correct details (optional)") {
                TextField("Product name", text: $draft.name).autocorrectionDisabled().disabled(product != nil)
                TextField("Strength", text: $draft.strength).disabled(product != nil)
                TextField("Dose quantity — blank if unknown", text: $draft.quantity).keyboardType(.decimalPad)
                Picker("Dose unit", selection: $draft.unit) { ForEach(DoseUnit.allCases) { Text($0.rawValue).tag($0) } }
                TextField("Formulation", text: $draft.formulation).disabled(product != nil)
                TextField("Route", text: $draft.route).disabled(product != nil)
                TextField("Directions", text: $draft.directions, axis: .vertical)
                Toggle("As needed", isOn: $draft.asNeeded)
                ForEach($draft.labelIngredients) { $ingredient in
                    TextField("Ingredient", text: $ingredient.name)
                    TextField("Amount", value: $ingredient.amount, format: .number).keyboardType(.decimalPad)
                    Picker("Ingredient unit", selection: $ingredient.unit) { ForEach(DoseUnit.allCases) { Text($0.rawValue).tag($0) } }
                    TextField("Per quantity", value: $ingredient.per, format: .number).keyboardType(.decimalPad)
                    Picker("Product unit", selection: $ingredient.productUnit) { ForEach(DoseUnit.allCases) { Text($0.rawValue).tag($0) } }
                }
            }
            DisclosureGroup("Recognition details") { ForEach(draft.warnings, id: \.self) { Text($0).font(.caption) } }
            if let product {
                DisclosureGroup("Product information and sources") {
                    Text(product.display)
                    ForEach(product.ingredients) { Text("\($0.name): \($0.amount) \($0.unit.rawValue) per \($0.per) \($0.productUnit.rawValue)") }
                    ForEach(product.sources) { source in Link(source.title, destination: source.url); Text("Checked " + source.checked.formatted()).font(.caption) }
                    ForEach(product.missing, id: \.self) { Text($0).font(.caption) }
                }
            }
            if !error.isEmpty { Text(error).foregroundStyle(.red) }
            HStack {
                Button("Accept") {
                    do { accept(try PhotoImport.item(from: draft, product: product)) }
                    catch { self.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent).disabled(needsPanel || draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button(product == nil ? "Retake / not accepted" : "Not this product", action: retake).buttonStyle(.bordered)
            }
        }.padding(.vertical, 8)
    }
}
struct QuickProductReview: View {
    @EnvironmentObject private var store: Store
    @Environment(\.dismiss) private var dismiss
    let product: Product
    var scan: PrescriptionDraft? = nil
    var onAccepted: (() -> Void)? = nil
    var draft: PrescriptionDraft {
        var result = scan ?? PrescriptionDraft(name: product.brand)
        result.name = product.brand; result.strength = product.strength; result.formulation = product.formulation; result.route = product.route
        if scan == nil { result.unit = product.ingredients.first?.productUnit ?? .tablet }
        return result
    }
    var body: some View {
        List {
            QuickPhotoReview(draft: draft, product: product) { item in
                store.upsert(item)
                if store.error == nil { if let onAccepted { onAccepted() } else { dismiss() } }
            } retake: { dismiss() }
        }.navigationTitle("Accept product")
    }
}
