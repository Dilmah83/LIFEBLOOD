import SwiftUI
import UniformTypeIdentifiers
import EventKit
import UserNotifications
import UIKit

@main struct LifebloodApp: App {
    @UIApplicationDelegateAdaptor(NotificationDelegate.self) private var notifications
    @StateObject private var store = Store()
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup { RootView().environmentObject(store).onChange(of: phase) { _, value in if value == .active { Task { await store.scheduleReminders(); await store.recheckClinical() } } } }
    }
}
struct RootView: View {
    @EnvironmentObject var store: Store
    @State private var errorDismissed = false
    var body: some View {
        TabView {
            NavigationStack { TodayView() }.tabItem { Label("Today", systemImage: "calendar") }
            NavigationStack { ItemsView() }.tabItem { Label("Products", systemImage: "pills") }
            NavigationStack { SafetyView() }.tabItem { Label("Safety", systemImage: "exclamationmark.shield") }
            NavigationStack { VitaminsView() }.tabItem { Label("Consider", systemImage: "leaf") }
            NavigationStack { SettingsView() }.tabItem { Label("Settings", systemImage: "gear") }
        }.tint(.red).alert("Record storage needs attention", isPresented: Binding(get: { store.error != nil && !errorDismissed }, set: { if !$0 { errorDismissed = true } })) {
            Button("Keep records unchanged", role: .cancel) {}
        } message: { Text(store.error ?? "") }
    }
}
struct TodayView: View {
    @EnvironmentObject var store: Store
    @State private var day = Date()
    @State private var logItem: RegimenItem?
    @State private var scheduled: Date?
    var body: some View {
        List {
            DatePicker("Schedule date", selection: $day, displayedComponents: .date)
            Section("Scheduled intake") {
                ForEach(store.archive.items.filter { $0.scheduled(on: day) }) { item in
                    ForEach(item.times, id: \.self) { time in
                        let date = Store.scheduledDate(day, time: time)
                        let taken = store.archive.doses.contains { $0.itemID == item.id && $0.scheduledAt == date }
                        VStack(alignment: .leading) {
                            Text(item.product.brand).font(.headline)
                            Text("\(time) · \(item.legacyDose ?? String(describing: item.quantity)) \(item.unit.rawValue)")
                            if taken { Label("Taken", systemImage: "checkmark.circle").foregroundStyle(.green) }
                            else { Button("Record actual dose") { scheduled = date; logItem = item } }
                        }
                    }
                }
            }
            Section("As-needed products") {
                ForEach(store.archive.items.filter { $0.active(on: day) && $0.asNeeded }) { item in
                    Button("Record \(item.product.brand)") { scheduled = nil; logItem = item }
                }
            }
            Section("Actual doses recorded on this date") {
                ForEach(store.archive.doses.filter { Calendar.current.isDate($0.takenAt, inSameDayAs: day) }.sorted { $0.takenAt > $1.takenAt }) { dose in
                    VStack(alignment: .leading) {
                        Text(dose.product.brand).font(.headline)
                        Text("\(dose.quantity) \(dose.unit.rawValue) · \(dose.takenAt.formatted(date: .omitted, time: .shortened))")
                        Text(dose.note).font(.caption)
                    }
                }
            }
            Text("A scheduled dose is not counted as taken until you record it. Do not double up a missed dose without advice.").font(.footnote)
        }.navigationTitle("LIFEBLOOD").sheet(item: $logItem) { item in NavigationStack { DoseLogView(item: item, scheduled: scheduled) } }
    }
}
struct DoseLogView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    let item: RegimenItem
    let scheduled: Date?
    @State private var amount = ""
    @State private var unit: DoseUnit = .tablet
    @State private var date = Date()
    @State private var note = ""
    var body: some View {
        Form {
            Text(item.product.display)
            TextField("Actual quantity", text: $amount).keyboardType(.decimalPad)
            Picker("Unit", selection: $unit) { ForEach(DoseUnit.allCases) { Text($0.rawValue).tag($0) } }
            DatePicker("Taken at", selection: $date, in: ...Date())
            TextField("Note / injection site", text: $note)
            Text("Use the quantity actually taken. For an injection, enter volume in mL only when the product's concentration has been confirmed.")
            Button("Save actual dose") {
                guard let value = Decimal(string: amount), value > 0 else { return }
                store.log(item, quantity: value, unit: unit, at: date, scheduled: scheduled, note: note); dismiss()
            }.disabled((Decimal(string: amount) ?? 0) <= 0)
        }.navigationTitle("Record dose").onAppear { amount = String(describing: item.quantity); unit = item.unit }
    }
}
struct ItemsView: View {
    @EnvironmentObject var store: Store
    @State private var adding = false
    @State private var scanning = false
    var body: some View {
        List {
            Button { adding = true } label: { Label("Add medication or supplement", systemImage: "plus") }
            Button { scanning = true } label: { Label("Scan prescription photo", systemImage: "doc.viewfinder") }
            ForEach(store.archive.items) { item in
                NavigationLink { ProductDetail(item: item) } label: {
                    VStack(alignment: .leading) {
                        Text(item.product.brand).font(.headline)
                        Text(item.product.display).font(.caption)
                        Text(item.product.verified ? "Source-confirmed product" : "Unverified entry").font(.caption).foregroundStyle(.secondary)
                        if item.stopped { Text("Discontinued") }
                        if item.asNeeded { Text("As needed") }
                    }
                }
            }
        }.navigationTitle("Your products")
        .sheet(isPresented: $adding) { NavigationStack { SearchView() } }
        .sheet(isPresented: $scanning) { NavigationStack { PrescriptionScannerView() } }
    }
}
struct SearchView: View {
    var initialQuery = ""
    var prescriptionDraft: PrescriptionDraft? = nil
    @AppStorage("productEndpoint") private var endpoint = ""
    @State private var query = ""
    @AppStorage("productSearchConsent") private var consent = false
    @State private var results: [Product] = []
    @State private var message = "Enter at least two letters and allow product-name searches. No API key is needed for the public directory."
    @State private var searching = false
    @State private var generation = UUID()
    @State private var lastSignature = ""
    var signature: String { endpoint + "|" + query.trimmingCharacters(in: .whitespacesAndNewlines) }
    var usesPublicDirectory: Bool { endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var body: some View {
        List {
            Section(usesPublicDirectory ? "Public product search — US directory" : "Australian medical provider") {
                TextField("Brand or generic name", text: $query).textInputAutocapitalization(.never).autocorrectionDisabled().submitLabel(.search).onSubmit { if consent { Task { await search() } } }
                Toggle("Allow product-name searches", isOn: $consent)
                Text("Only the search term is sent. Your identity, medication list and health profile are not sent. Provider details: \(usesPublicDirectory ? "US FDA public National Drug Code directory (api.fda.gov)" : endpoint)").font(.caption)
                Button(searching ? "Searching…" : "Search products") { Task { await search() } }.disabled(!consent || query.trimmingCharacters(in: .whitespacesAndNewlines).count < 2 || searching)
                if usesPublicDirectory {
                    Text("US products only. Australian brands, ingredients and strengths can differ. Vitamins and supplements may not be listed. Confirm every detail against your own pack; results are not Australian product verification.").font(.footnote)
                }
                if !consent { Text("Turn on Allow product-name searches above to search.").font(.footnote) }
                Text(message).font(.footnote)
            }
            ForEach(results) { product in
                NavigationLink { ConfirmationView(product: product, prescriptionDraft: prescriptionDraft) } label: { Text(product.display) }
            }
            Section("No exact match?") {
                NavigationLink("Enter manually — unverified") { ProductEditor(item: nil, selected: nil, initialName: query, prescriptionDraft: prescriptionDraft) }
                Link("Australian PI and CMI search (TGA)", destination: URL(string: "https://www.tga.gov.au/resources/artg")!)
                Link("Australian medicine information (Healthdirect)", destination: URL(string: "https://www.healthdirect.gov.au/medicines")!)
                Text("Do not choose a brand match without confirming all ingredients, strength, formulation and route on the pack.")
            }
        }.navigationTitle("Find a product")
        .onAppear { if query.isEmpty { query = initialQuery } }
        .onChange(of: query) { _, _ in generation = UUID(); results = []; searching = false }
        .onChange(of: endpoint) { _, _ in generation = UUID(); results = []; searching = false }
        .onChange(of: consent) { _, allowed in if !allowed { generation = UUID(); results = []; searching = false } }
        .task(id: signature + "|" + String(consent)) {
            guard consent, query.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 else { return }
            do { try await Task.sleep(for: .milliseconds(600)) } catch { return }
            guard !Task.isCancelled, !searching, lastSignature != signature else { return }
            await search()
        }
        .onDisappear { generation = UUID(); searching = false }
    }
    @MainActor func search() async {
        guard consent, query.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2 else { return }
        let request = UUID(); generation = request; searching = true; lastSignature = signature
        message = "Searching published product records…"
        do {
            let products = try await ProductService().search(query, endpoint: endpoint)
            guard generation == request else { return }
            results = products
            message = products.isEmpty ? "No product found in the directory checked. Australian-only products and supplements may be absent. Try the generic name, open the Australian sources below, or enter manually." : "Choose your exact product, strength and formulation. Different products with similar names remain separate."
        } catch {
            guard generation == request else { return }
            if !Task.isCancelled { message = "Lookup failed: " + error.localizedDescription + " You can retry or enter manually."; results = [] }
        }
        if generation == request { searching = false }
    }
}
struct ConfirmationView: View {
    let product: Product
    var prescriptionDraft: PrescriptionDraft? = nil
    @State private var confirmed = false
    var body: some View {
        List {
            ProductInformation(product: product)
            Toggle("I checked the exact pack, all ingredients, strength, formulation and route", isOn: $confirmed)
            if confirmed { NavigationLink("Enter prescribed or labelled dose") { ProductEditor(item: nil, selected: product, prescriptionDraft: prescriptionDraft) } }
        }.navigationTitle("Confirm product")
    }
}
struct ProductInformation: View {
    let product: Product
    var body: some View {
        Section("Product") {
            Text(product.display).font(.headline)
            Text("Generic: \(product.generic)")
            Text(product.verified ? "Source-confirmed composition; not a verified prescription" : "Unverified product information")
            ForEach(product.ingredients) { ingredient in
                Text("\(ingredient.name) [\(ingredient.form)] · \(ingredient.amount) \(ingredient.unit.rawValue) per \(ingredient.per) \(ingredient.productUnit.rawValue)")
            }
        }
        ForEach(ProductService.sectionNames, id: \.self) { name in
            DisclosureGroup(name) { Text(product.sections[name] ?? "Not supplied. Ask your pharmacist or check the current Australian PI/CMI.") }
        }
        Section("Sources and missing information") {
            ForEach(product.sources) { source in
                VStack(alignment: .leading) {
                    if source.url.scheme == "https" { Link(source.title, destination: source.url) }
                    Text("\(source.jurisdiction) · Checked \(source.checked.formatted(date: .abbreviated, time: .omitted))\(source.stale ? " · STALE — refresh needed" : "")").font(.caption)
                }
            }
            if product.sources.isEmpty { Text("No verified source or checked date available.") }
            ForEach(product.missing + product.conflicts, id: \.self) { Text($0).foregroundStyle(.orange) }
            Text("General education. Your individual interactions and suitability have not been established.").font(.footnote)
        }
    }
}
struct ProductDetail: View {
    @EnvironmentObject var store: Store
    let item: RegimenItem
    var current: RegimenItem { store.archive.items.first { $0.id == item.id } ?? item }
    var body: some View {
        List {
            NavigationLink("Edit product, dose or schedule") { ProductEditor(item: current, selected: nil) }
            Button(current.stopped ? "Record restart" : "Record discontinuation") { var next = current; next.stopped.toggle(); store.upsert(next) }
            Text("Record only changes agreed with your prescriber. The app does not recommend stopping or changing treatment.").font(.footnote)
            ProductInformation(product: current.product)
        }.navigationTitle(current.product.brand)
    }
}
struct ProductEditor: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    let item: RegimenItem?
    let selected: Product?
    var initialName = ""
    var prescriptionDraft: PrescriptionDraft? = nil
    @State private var name = ""
    @State private var generic = ""
    @State private var strength = ""
    @State private var formulation = ""
    @State private var route = "Oral"
    @State private var ingredients: [Ingredient] = []
    @State private var quantity = "1"
    @State private var unit: DoseUnit = .tablet
    @State private var times = "08:00"
    @State private var days = Set(1...7)
    @State private var start = Date()
    @State private var hasEnd = false
    @State private var end = Date()
    @State private var prn = false
    @State private var instructions = ""
    @State private var confirmed = false
    @State private var error = ""
    @State private var saved = false
    var sourceProduct: Product? { selected ?? item?.product }
    var body: some View {
        Form {
            if let scanned = prescriptionDraft {
                Section("Populated from prescription — unverified") {
                    Text("Scanned medicine: " + scanned.name)
                    Text("Scanned strength: " + (scanned.strength.isEmpty ? "Not readable" : scanned.strength))
                    Text("Compare these with the exact product below. Do not accept a different product or strength just because its name matches. Ask your pharmacist about discrepancies.")
                    Text("Enter reminder times and days explicitly. Nothing from the photo has been saved yet.")
                }
            }
            Section("Exact product") {
                TextField("Brand / product name", text: $name)
                TextField("Generic names", text: $generic)
                TextField("Pack strength", text: $strength)
                TextField("Formulation", text: $formulation)
                TextField("Administration route", text: $route)
                Text("Manual entries and edited compositions are unverified. Never infer ingredients from a brand.").font(.caption)
            }
            Section("Every ingredient — amount per product unit") {
                ForEach($ingredients) { $ingredient in
                    VStack {
                        TextField("Ingredient name", text: $ingredient.name)
                        TextField("Ingredient form (if known)", text: $ingredient.form)
                        TextField("Amount", value: $ingredient.amount, format: .number).keyboardType(.decimalPad)
                        Picker("Ingredient unit", selection: $ingredient.unit) { ForEach(DoseUnit.allCases) { Text($0.rawValue).tag($0) } }
                        TextField("Per quantity of product", value: $ingredient.per, format: .number).keyboardType(.decimalPad)
                        Picker("Product unit", selection: $ingredient.productUnit) { ForEach(DoseUnit.allCases) { Text($0.rawValue).tag($0) } }
                        Button("Remove ingredient", role: .destructive) { ingredients.removeAll { $0.id == ingredient.id } }
                    }
                }
                Button("Add ingredient") { ingredients.append(Ingredient(id: UUID().uuidString, name: "", amount: 0, unit: .mg)) }
                Text("Injection example: 10 mg per 1 mL, then enter 0.5 mL per dose. Supplement example: amounts per 2 capsules, then enter capsules taken. IU stays in IU unless a verified ingredient-specific conversion exists.").font(.caption)
            }
            Section("Dose and schedule") {
                TextField("Quantity per dose / servings", text: $quantity).keyboardType(.decimalPad)
                Picker("Dose unit", selection: $unit) { ForEach(DoseUnit.allCases) { Text($0.rawValue).tag($0) } }
                Toggle("As needed — no scheduled reminders", isOn: $prn)
                if !prn {
                    TextField("24-hour times, comma separated", text: $times)
                    ForEach(1...7, id: \.self) { day in
                        Toggle(Calendar.current.weekdaySymbols[day - 1], isOn: Binding(get: { days.contains(day) }, set: { if $0 { days.insert(day) } else { days.remove(day) } }))
                    }
                }
                DatePicker("Start", selection: $start, displayedComponents: .date)
                Toggle("End date", isOn: $hasEnd)
                if hasEnd { DatePicker("End", selection: $end, in: start..., displayedComponents: .date) }
                TextField("Label / clinician instructions", text: $instructions, axis: .vertical)
                Toggle("I confirm these product and dose details", isOn: $confirmed)
                Text(error).foregroundStyle(.red)
                Button("Save product and check regimen") { saveItem() }.disabled(!confirmed)
            }
        }.navigationTitle(item == nil ? "Add product" : "Edit product").onAppear(perform: populate)
        .alert("Product saved", isPresented: $saved) { Button("Done") { dismiss() } } message: { Text("Local safety findings and ingredient totals have been updated. Open Safety to review coverage and findings.") }
    }
    func populate() {
        let p = sourceProduct
        name = p?.brand ?? initialName; generic = p?.generic ?? ""; strength = p?.strength ?? ""; formulation = p?.formulation ?? ""; route = p?.route ?? "Oral"; ingredients = p?.ingredients ?? []; unit = p?.ingredients.first?.productUnit ?? .tablet
        if let scanned = prescriptionDraft, item == nil {
            if p == nil { name = initialName.isEmpty ? scanned.name : initialName; strength = scanned.strength; formulation = scanned.formulation; route = scanned.route }
            quantity = scanned.quantity; unit = scanned.unit; prn = scanned.asNeeded; instructions = scanned.directions
            times = ""; days = []
        }
        if let item { quantity = String(describing: item.quantity); unit = item.unit; times = item.times.joined(separator: ", "); days = Set(item.weekdays); start = item.start; hasEnd = item.end != nil; end = item.end ?? item.start; prn = item.asNeeded; instructions = item.instructions }
    }
    func saveItem() {
        guard prescriptionDraft?.reviewed != false else { error = "Review the recognised prescription fields before saving."; return }
        let schedule = times.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty, let amount = Decimal(string: quantity), amount > 0,
              ingredients.allSatisfy({ !$0.name.trimmingCharacters(in: .whitespaces).isEmpty && $0.amount > 0 && $0.per > 0 }),
              Set(ingredients.map(\.id)).count == ingredients.count,
              prn || (!days.isEmpty && !schedule.isEmpty && schedule.allSatisfy { Store.scheduledDate(Date(), time: $0) != nil }),
              !hasEnd || end >= start else { error = "Check name, positive amounts, ingredient details, times, days and date range."; return }
        var p = sourceProduct ?? Product(id: "manual:" + UUID().uuidString, brand: name, generic: generic, strength: strength, formulation: formulation, route: route, ingredients: [])
        let unchanged = p.brand == name && p.generic == generic && p.strength == strength && p.formulation == formulation && p.route == route && p.ingredients == ingredients
        p.brand = name; p.generic = generic; p.strength = strength; p.formulation = formulation; p.route = route
        // Manual names normalise only literal spelling. Synonyms need a provider identity.
        p.ingredients = ingredients.map { ingredient in
            var value = ingredient
            if !unchanged || !p.verified { value.id = "manual:" + ingredient.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            return value
        }
        if !unchanged { p.verified = false }
        if prescriptionDraft != nil && selected == nil {
            p.verified = false
            if !p.missing.contains("Created from user-reviewed photo text; product details and ingredients are not independently verified.") { p.missing.append("Created from user-reviewed photo text; product details and ingredients are not independently verified.") }
        }
        var next = item ?? RegimenItem(product: p)
        next.product = p; next.quantity = amount; next.unit = unit; next.asNeeded = prn; next.times = prn ? [] : Array(Set(schedule)).sorted(); next.weekdays = days.sorted(); next.start = start; next.end = hasEnd ? end : nil; next.instructions = instructions; next.legacyDose = nil
        store.upsert(next); saved = store.error == nil
    }
}
struct SafetyView: View {
    @EnvironmentObject var store: Store
    @State private var date = Date()
    @State private var actual = false
    var body: some View {
        let result = actual ? SafetyEngine.actualTotals(doses: store.archive.doses, on: date) : SafetyEngine.scheduledTotals(items: store.archive.items, on: date)
        List {
            Section("Coverage") {
                Label("Limited checks available", systemImage: "info.circle").font(.headline)
                Text(SafetyEngine.coverage)
                Text("No comprehensive interaction check has been performed. Spacing doses only helps specific documented absorption conflicts; it does not resolve every interaction.")
            }
            Section("Clinical provider status") {
                Text(store.clinicalStatus)
                if let result = store.clinicalResult {
                    Text(result.coverage)
                    Text("Checked " + result.checked.formatted())
                    if !result.complete { Label("Incomplete coverage", systemImage: "exclamationmark.triangle") }
                    if result.findings.isEmpty { Text("No interactions identified in the sources checked. This does not establish safety for an individual.") }
                    ForEach(result.findings.sorted { SafetyEngine.rank($0.severity) < SafetyEngine.rank($1.severity) }) { finding in
                        DisclosureGroup(finding.severity + ": " + finding.title) {
                            Text(finding.products.joined(separator: " + "))
                            Text(finding.ingredients.joined(separator: ", "))
                            Text(finding.consequence)
                            Text("Evidence: " + finding.evidence)
                            Text(finding.spacing)
                            Text(finding.advice)
                            ForEach(finding.sources) { source in Link(source.title, destination: source.url); Text("Checked " + source.checked.formatted()).font(.caption) }
                        }
                    }
                }
                Button("Recheck current regimen") { Task { await store.recheckClinical() } }
            }
            Section("Prioritised local findings") {
                let findings = SafetyEngine.findings(items: store.archive.items)
                if findings.isEmpty { Text("No duplicate ingredients identified in entered data. Missing or unrecognised ingredient synonyms may hide overlaps.") }
                ForEach(findings) { finding in
                    DisclosureGroup {
                        Text(finding.products.joined(separator: " + "))
                        Text(finding.ingredients.joined(separator: ", "))
                        Text(finding.consequence)
                        Text("Evidence: " + finding.evidence)
                        Text(finding.advice)
                        Text(finding.spacing)
                        ForEach(finding.sources) { source in if source.url.scheme == "https" { Link(source.title, destination: source.url) } }
                    } label: { Label(finding.severity + ": " + finding.title, systemImage: finding.severity == "Review" ? "exclamationmark.triangle" : "info.circle").foregroundStyle(finding.severity == "Review" ? .orange : .secondary) }
                }
            }
            Section("Ingredient totals") {
                DatePicker("Intake date", selection: $date, displayedComponents: .date)
                Toggle("Show actual logged intake", isOn: $actual)
                Text(actual ? "Recorded doses only. Unrecorded doses and food are excluded." : "Scheduled doses on this date only; as-needed intake is excluded. Weekly doses are not averaged into daily doses.")
                ForEach(result.totals) { total in
                    DisclosureGroup("\(total.name): \(total.amount) \(total.unit.rawValue)") {
                        ForEach(Array(total.contributions.enumerated()), id: \.offset) { _, text in Text(text) }
                    }
                }
                ForEach(result.missing, id: \.self) { Text($0).foregroundStyle(.orange) }
                Text("Dietary intake is not quantified: these totals are incomplete. Below an upper limit does not establish individual safety. IU and mass are not combined.").font(.footnote)
            }
            Section("Excessive intake and dose limits — unavailable") {
                Text("No verified Australian/New Zealand nutrient reference dataset or individual medication limits are connected. Recommended intakes and upper limits are different. Limits may apply to supplements only, specific forms or total intake. No limit has been inferred; a missing limit does not mean unlimited intake is safe.")
                Text("Age, sex, pregnancy/breastfeeding, indication, formulation, renal/hepatic conditions and food intake may be necessary for a valid comparison. Ask your pharmacist to review totals and prescribed doses.")
                Link("Australian/New Zealand nutrient reference values", destination: URL(string: "https://www.eatforhealth.gov.au/nutrient-reference-values")!)
            }
        }.navigationTitle("Safety & totals")
    }
}
struct VitaminsView: View {
    @EnvironmentObject var store: Store
    var body: some View {
        List {
            Section("General education — assessment prompts") {
                Text("Personalised supplement recommendations are unavailable without evidence and interaction coverage. No supplement is added automatically.")
            }
            ForEach(SafetyEngine.recommendations(profile: store.archive.profile, items: store.archive.items)) { suggestion in
                Section(suggestion.title) {
                    Text(suggestion.reason)
                    Text(suggestion.evidence)
                    Text(suggestion.nextStep)
                    Text("Missing: " + suggestion.missing)
                    Link("Australian dietary guidance", destination: URL(string: "https://www.eatforhealth.gov.au/")!)
                }
            }
            NavigationLink("Update optional health profile") { ProfileView() }
        }.navigationTitle("Vitamins to consider")
    }
}
struct ProfileView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    @State private var profile = PatientProfile()
    @State private var age = ""
    var body: some View {
        Form {
            Text("Optional. Stored on this device; not sent with product searches.")
            TextField("Name (optional)", text: $profile.name)
            TextField("Allergies / cautions", text: $profile.allergies, axis: .vertical)
            TextField("Age in years", text: $age).keyboardType(.numberPad)
            Picker("Sex", selection: $profile.sex) { ForEach(["Not supplied", "Female", "Male", "Other"], id: \.self) { Text($0) } }
            Picker("Pregnancy / breastfeeding", selection: $profile.pregnancy) { ForEach(["Not supplied", "Neither", "Pregnant", "Breastfeeding", "Pregnant and breastfeeding"], id: \.self) { Text($0) } }
            Picker("Dietary pattern", selection: $profile.diet) { ForEach(["Not supplied", "Mixed", "Vegetarian", "Vegan", "Other"], id: \.self) { Text($0) } }
            TextField("Relevant conditions / allergies", text: $profile.conditions, axis: .vertical)
            TextField("Goals", text: $profile.goals, axis: .vertical)
            Section("Blood tests — record only, not diagnostic interpretation") {
                ForEach($profile.bloodTests) { $test in
                    TextField("Test name", text: $test.name)
                    TextField("Value", text: $test.value)
                    TextField("Unit", text: $test.unit)
                    DatePicker("Test date", selection: $test.date, in: ...Date(), displayedComponents: .date)
                }
                Button("Add test") { profile.bloodTests.append(BloodTest(name: "", value: "", unit: "", date: Date())) }
            }
            Button("Save profile") {
                profile.age = Int(age)
                var next = store.archive; next.profile = profile; store.commit(next); dismiss()
            }.disabled(!age.isEmpty && (Int(age) == nil || (Int(age) ?? -1) < 0 || (Int(age) ?? 999) > 125))
        }.navigationTitle("Optional profile").onAppear { profile = store.archive.profile; age = profile.age.map(String.init) ?? "" }
    }
}
struct ArchiveDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.json] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws { data = configuration.file.regularFileContents ?? Data() }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}
struct SettingsView: View {
    @EnvironmentObject var store: Store
    @AppStorage("productEndpoint") private var endpoint = ""
    @State private var importing = false
    @State private var exporting = false
    @State private var legacyExport = false
    @State private var exportData = Data()
    @State private var message = ""
    @State private var calendarBusy = false
    @AppStorage("clinicalConsent") private var clinicalConsent = false
    var body: some View {
        Form {
            Section("Records") {
                if let error = store.error { Text(error).foregroundStyle(.red) }
                ShareLink("Share medication summary with pharmacist / doctor", item: store.summary)
                Button("Export full native backup") { do { legacyExport = false; exportData = try JSONEncoder().encode(store.archive); exporting = true } catch { message = error.localizedDescription } }
                Button("Import existing LIFEBLOOD archive (empty tracker only)") { importing = true }.disabled(!store.archive.items.isEmpty || !store.archive.doses.isEmpty || store.archive.legacyJSON != nil)
                if let data = store.archive.legacyJSON { Button("Export preserved browser archive") { exportData = data; legacyExport = true; exporting = true } }
                Text(store.importReport)
                Text(message)
            }
            Section("Reminders and Calendar") {
                Button("Enable native reminders") { Task { await store.scheduleReminders(requestPermission: true) } }
                Text(store.reminderStatus)
                Button("Export next 60 days to Calendar") { Task { await exportCalendar() } }.disabled(calendarBusy)
                Text("Calendar export is explicit. Re-export uses stable identifiers to avoid duplicates in the selected calendar. Existing browser-imported events are preserved and may need manual review. Calendar alerts cannot know whether you took a dose.").font(.caption)
            }
            Section("Medical data provider") {
                TextField("Optional Australian provider HTTPS URL", text: $endpoint).textInputAutocapitalization(.never).autocorrectionDisabled().keyboardType(.URL).onChange(of: endpoint) { _, _ in Task { await store.recheckClinical() } }
                if !endpoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Button("Remove custom backend and use public product search") { endpoint = "" }
                    Text("Removing the custom backend also makes its clinical checks unavailable.").font(.caption)
                }
                Text("The public US FDA directory works without setup. An optional trusted backend can supply appropriately licensed Australian product information. Only a product search term is transmitted after consent. The optional clinical check requires a licensed provider adapter. Nutrient-limit and personalised recommendation services are not connected in this build. Do not enter API keys here.")
            }
            Section("Optional third-party clinical processing") {
                Toggle("Allow automatic clinical checks", isOn: $clinicalConsent)
                    .onChange(of: clinicalConsent) { _, _ in Task { await store.recheckClinical() } }
                Text("When enabled, the configured provider receives product identifiers, quantities, units, weekdays and times after regimen changes. No name, profile, blood tests, notes or dose history is sent. This is sensitive regimen information: use only a trusted clinical provider whose privacy terms you accept. Checks without patient details have limited coverage. Disabling removes the displayed result.")
            }
            NavigationLink("Optional health profile") { ProfileView() }
            Section("Privacy and clinical limitations") {
                Text("Records use local iOS file protection and are never sent to general search or AI providers. Exported summaries and backups contain sensitive health data: share them only with intended recipients. Device backups follow your iOS settings. This app is not clinically validated. Do not change prescribed treatment based on its findings. For emergencies call 000.")
            }
        }.navigationTitle("Settings")
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json]) { result in
            do { let url = try result.get(); let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }; try store.restore(Data(contentsOf: url)); message = "Import complete. Review product details and reminder permissions." } catch { message = error.localizedDescription }
        }
        .fileExporter(isPresented: $exporting, document: ArchiveDocument(data: exportData), contentType: .json, defaultFilename: legacyExport ? "lifeblood-browser-archive" : "lifeblood-native-backup") { result in
            legacyExport = false
            if case .failure(let error) = result { message = error.localizedDescription }
        }
    }
    @MainActor func exportCalendar() async {
        calendarBusy = true; defer { calendarBusy = false }
        let ek = EKEventStore()
        do {
            guard try await ek.requestFullAccessToEvents() else { message = "Calendar access denied. No events changed."; return }
            guard let calendar = ek.defaultCalendarForNewEvents else { message = "No writable default calendar."; return }
            let now = Calendar.current.startOfDay(for: Date())
            let until = Calendar.current.date(byAdding: .day, value: 60, to: now)!
            let existing = ek.events(matching: ek.predicateForEvents(withStart: now, end: until, calendars: [calendar]))
            let generated = existing.filter { $0.url?.scheme == "lifeblood" }
            var desired = Set<String>()
            for n in 0..<60 {
                let date = Calendar.current.date(byAdding: .day, value: n, to: now)!
                for item in store.archive.items where item.scheduled(on: date) {
                    for time in item.times {
                        guard let at = Store.scheduledDate(date, time: time), at > Date() else { continue }
                        let identity = "lifeblood://dose/\(item.id.uuidString)/\(Int(at.timeIntervalSince1970))"
                        desired.insert(identity)
                        let event = generated.first { $0.url?.absoluteString == identity } ?? EKEvent(eventStore: ek)
                        event.calendar = calendar; event.title = "Health reminder"; event.startDate = at; event.endDate = at.addingTimeInterval(900); event.url = URL(string: identity); event.notes = "Open LIFEBLOOD to record the actual dose."; event.alarms = [EKAlarm(relativeOffset: 0)]
                        try ek.save(event, span: .thisEvent, commit: false)
                    }
                }
            }
            // Only this native app's marked events in the selected window are reconciled.
            for event in generated where !desired.contains(event.url?.absoluteString ?? "") { try ek.remove(event, span: .thisEvent, commit: false) }
            try ek.commit(); message = "Exported \(desired.count) reminders for the next 60 days. Review in Calendar."
        } catch { ek.reset(); message = "Calendar export failed: \(error.localizedDescription)" }
    }
}

final class NotificationDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        UNUserNotificationCenter.current().delegate = self
        return true
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
