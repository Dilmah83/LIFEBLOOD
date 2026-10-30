import SwiftUI
import Vision
import VisionKit
import PhotosUI
import ImageIO
import AVFoundation

struct PrescriptionScanResult: Sendable {
    let lines: [PrescriptionLine]
    let previews: [Data]
}
enum PrescriptionOCR {
    enum ScanError: LocalizedError {
        case unreadable, tooLarge, noText
        var errorDescription: String? {
            switch self {
            case .unreadable: return "This photo could not be read. Choose a JPEG/HEIC photo or retake it in good light."
            case .tooLarge: return "Scan at most five pages, with a combined size under 30 MB. Try one prescription at a time."
            case .noText: return "No readable text found. Retake the photo with the full prescription in focus."
            }
        }
    }
    static func thumbnail(_ data: Data) throws -> CGImage {
        guard data.count <= 30_000_000, let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true, kCGImageSourceThumbnailMaxPixelSize: 2800, kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { throw ScanError.unreadable }
        return image
    }
    static func recognise(_ pages: [Data]) throws -> PrescriptionScanResult {
        guard !pages.isEmpty, pages.count <= 5, pages.reduce(0, { $0 + $1.count }) <= 30_000_000 else { throw ScanError.tooLarge }
        var lines: [PrescriptionLine] = []
        var previews: [Data] = []
        for data in pages {
            try Task.checkCancellation()
            let image = try thumbnail(data)
            if let preview = UIImage(cgImage: image).jpegData(compressionQuality: 0.7) { previews.append(preview) }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false // Never auto-correct drug spellings.
            request.recognitionLanguages = ["en-US"]
            try VNImageRequestHandler(cgImage: image, orientation: .up).perform([request])
            try Task.checkCancellation()
            // Preserve Vision's reading order. Multiple products are never assigned
            // directions by proximity, because columns/handwriting can be ambiguous.
            for observation in request.results ?? [] {
                if let candidate = observation.topCandidates(1).first { lines.append(PrescriptionLine(text: candidate.string, confidence: candidate.confidence)) }
            }
        }
        guard !lines.isEmpty else { throw ScanError.noText }
        return PrescriptionScanResult(lines: lines, previews: previews)
    }
}
struct PrescriptionDocumentCamera: UIViewControllerRepresentable {
    let completion: (Result<[Data], Error>?) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }
    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController(); controller.delegate = context.coordinator; return controller
    }
    func updateUIViewController(_ uiViewController: VNDocumentCameraViewController, context: Context) {}
    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let completion: (Result<[Data], Error>?) -> Void
        init(completion: @escaping (Result<[Data], Error>?) -> Void) { self.completion = completion }
        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) { completion(nil) }
        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) { completion(.failure(error)) }
        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            guard (1...5).contains(scan.pageCount) else { completion(.failure(PrescriptionOCR.ScanError.tooLarge)); return }
            var pages: [Data] = []
            for index in 0..<scan.pageCount {
                guard let data = scan.imageOfPage(at: index).jpegData(compressionQuality: 0.9) else { completion(.failure(PrescriptionOCR.ScanError.unreadable)); return }
                pages.append(data)
            }
            completion(.success(pages))
        }
    }
}
struct PrescriptionScannerView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var camera = false
    @State private var photo: PhotosPickerItem?
    @State private var reading = false
    @State private var message = ""
    @State private var drafts: [PrescriptionDraft] = []
    @State private var warnings: [String] = []
    @State private var rawText = ""
    @State private var previews: [Data] = []
    @State private var worker: Task<Void, Never>?
    @State private var generation = UUID()
    @State private var showSensitivePreview = false
    @State private var cameraDenied = false
    var body: some View {
        List {
            Section("Prescription photo") {
                Text("Photograph the printed prescription or dispensing label. Text recognition runs on this iPhone. No photo, patient details or raw prescription text is uploaded or saved by LIFEBLOOD.")
                Text("Recognition can misread names, decimal points and units. Handwriting and complex layouts may need manual entry. You must review each medicine before adding it.").font(.footnote)
                if VNDocumentCameraViewController.isSupported {
                    Button { Task { await openCamera() } } label: { Label("Take prescription photo", systemImage: "doc.viewfinder") }.disabled(reading)
                } else { Text("Document camera is unavailable here. Choose an existing photo; the simulator has no document camera.").font(.footnote) }
                if cameraDenied {
                    Link("Open Settings for camera permission", destination: URL(string: UIApplication.openSettingsURLString)!)
                }
                PhotosPicker(selection: $photo, matching: .images, photoLibrary: .shared()) { Label("Choose prescription photo", systemImage: "photo") }.disabled(reading)
                if reading { ProgressView("Reading on this iPhone…") }
                if !message.isEmpty { Text(message).foregroundStyle(.secondary) }
            }
            if !drafts.isEmpty || !warnings.isEmpty {
                Section("Review before adding") {
                    ForEach(warnings, id: \.self) { Text($0) }
                    ForEach(drafts) { draft in
                        NavigationLink { PrescriptionReviewView(draft: draft) } label: {
                            VStack(alignment: .leading) { Text(draft.name).font(.headline); Text(draft.strength.isEmpty ? "Strength needs entry" : draft.strength).font(.caption) }
                        }
                    }
                }
            }
            if !rawText.isEmpty {
                Section("Private reference — not saved") {
                    Toggle("Show prescription photo and recognised text", isOn: $showSensitivePreview)
                    Text("This may show your name, address and other private details. Only fields you explicitly confirm are added to the tracker.").font(.caption)
                    if showSensitivePreview {
                        ForEach(Array(previews.enumerated()), id: \.offset) { _, data in
                            if let image = UIImage(data: data) { Image(uiImage: image).resizable().scaledToFit().accessibilityLabel("Prescription page preview") }
                        }
                        Text(rawText).textSelection(.enabled).privacySensitive()
                    }
                }
            }
            Section {
                NavigationLink("Enter a product manually") { ProductEditor(item: nil, selected: nil) }
                Text("For unclear directions or discrepancies, ask your pharmacist. Do not guess a dose or change prescribed treatment.").font(.footnote)
            }
        }.navigationTitle("Scan prescription")
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { discard(); dismiss() } } }
        .privacySensitive()
        .interactiveDismissDisabled(reading)
        .sheet(isPresented: $camera) {
            PrescriptionDocumentCamera { result in
                camera = false
                guard let result else { return }
                switch result { case .success(let pages): read(pages); case .failure(let error): message = error.localizedDescription }
            }.ignoresSafeArea()
        }
        .onChange(of: photo) { _, selected in
            guard let selected else { return }
            begin()
            let request = generation
            worker = Task { @MainActor in
                do {
                    guard let data = try await selected.loadTransferable(type: Data.self) else { throw PrescriptionOCR.ScanError.unreadable }
                    guard generation == request, !Task.isCancelled else { return }
                    photo = nil
                    performOCR([data], request: request)
                } catch { if generation == request { reading = false; message = error.localizedDescription } }
            }
        }
        .onChange(of: scenePhase) { _, phase in if phase != .active { showSensitivePreview = false } }
        // Navigation to review keeps the scan in memory; closing the sheet destroys it.
    }
    @MainActor private func openCamera() async {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        let allowed: Bool
        if status == .authorized { allowed = true }
        else if status == .notDetermined { allowed = await AVCaptureDevice.requestAccess(for: .video) }
        else { allowed = false }
        guard allowed else { cameraDenied = true; message = "Camera access is off or restricted. Choose a photo instead, or review camera permission in iPhone Settings."; return }
        cameraDenied = false; discard(); camera = true
    }
    @MainActor private func begin() {
        worker?.cancel(); generation = UUID(); reading = true; message = ""; drafts = []; warnings = []; rawText = ""; previews = []; showSensitivePreview = false
    }
    @MainActor private func read(_ pages: [Data]) { begin(); performOCR(pages, request: generation) }
    @MainActor private func performOCR(_ pages: [Data], request: UUID) {
        worker = Task { @MainActor in
            let operation = Task.detached(priority: .userInitiated) { try PrescriptionOCR.recognise(pages) }
            do {
                let result = try await withTaskCancellationHandler(operation: { try await operation.value }, onCancel: { operation.cancel() })
                guard generation == request, !Task.isCancelled else { return }
                let parsed = PrescriptionParser.parse(result.lines)
                drafts = parsed.drafts; warnings = parsed.warnings; rawText = result.lines.map(\.text).joined(separator: "\n"); previews = result.previews
                reading = false; message = "Found \(drafts.count) possible medicine line(s). Review each against the photo. Nothing has been saved."
            } catch { if generation == request { reading = false; message = error.localizedDescription } }
        }
    }
    @MainActor private func discard() { worker?.cancel(); generation = UUID(); reading = false; drafts = []; warnings = []; rawText = ""; previews = []; photo = nil }
}
struct PrescriptionReviewView: View {
    @State var draft: PrescriptionDraft
    @State private var confirmed = false
    var reviewedDraft: PrescriptionDraft { var copy = draft; copy.reviewed = true; return copy }
    var body: some View {
        Form {
            Section("Correct the recognised text") {
                TextField("Medicine name only — no patient details", text: $draft.name)
                TextField("Strength exactly as written", text: $draft.strength)
                TextField("Formulation", text: $draft.formulation)
                TextField("Route — leave blank if unclear", text: $draft.route)
                TextField("Quantity per dose — leave blank if unclear", text: $draft.quantity).keyboardType(.decimalPad)
                Picker("Dose unit", selection: $draft.unit) { ForEach(DoseUnit.allCases) { Text($0.rawValue).tag($0) } }
                Toggle("As needed", isOn: $draft.asNeeded)
                TextField("Directions — confirm against prescription", text: $draft.directions, axis: .vertical)
            }
            Section("Check carefully") {
                ForEach(draft.warnings, id: \.self) { Text($0) }
                Text("Only the edited medicine name is used if you explicitly open product search and allow that search. Photo text and personal details are not sent. Ingredients and schedules are not guessed.")
                Toggle("I compared these fields with the prescription", isOn: $confirmed)
            }
            if confirmed && !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Section("Populate the tracker") {
                    NavigationLink("Confirm a matching product first") { SearchView(initialQuery: draft.name, prescriptionDraft: reviewedDraft) }
                    NavigationLink("Continue with unverified manual product") { ProductEditor(item: nil, selected: nil, prescriptionDraft: reviewedDraft) }
                    Text("Check every ingredient and enter reminder times/days in the next screen. Saving is a separate explicit action.").font(.caption)
                }
            }
        }.navigationTitle("Review scanned medicine")
        .onChange(of: draft.name) { _, _ in confirmed = false }
        .onChange(of: draft.strength) { _, _ in confirmed = false }
    }
}
