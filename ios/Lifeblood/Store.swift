import Foundation
import SwiftUI
import UserNotifications

@MainActor final class Store: ObservableObject {
    @Published var archive = Archive()
    @Published var error: String?
    @Published var reminderStatus = "Reminders have not been enabled."
    @Published var importReport = ""
    @Published var clinicalResult: ClinicalResult?
    @Published var clinicalStatus = "No clinical provider check has been performed."
    private var clinicalGeneration = UUID()
    private let file: URL
    init(directory: URL? = nil) {
        let folder = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Lifeblood")
        file = folder.appendingPathComponent("records.json")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: file.path) {
                let decoded = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: file))
                guard decoded.version == 1 else { throw StoreError.invalid("Unsupported archive version; file was not changed.") }
                archive = decoded
            }
        } catch { self.error = "Records could not be loaded. Existing file has not been overwritten. \(error.localizedDescription)" }
    }
    enum StoreError: LocalizedError {
        case invalid(String)
        var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
    }
    // Commit atomically before updating visible state. An unreadable file blocks mutations.
    func commit(_ next: Archive) {
        guard error == nil else { return }
        do {
            let data = try JSONEncoder().encode(next)
            try data.write(to: file, options: [.atomic, .completeFileProtection])
            archive = next
            clinicalGeneration = UUID(); clinicalResult = nil
            Task { await scheduleReminders() }
            Task { await recheckClinical() }
        } catch { self.error = "Could not save records: \(error.localizedDescription)" }
    }
    func upsert(_ item: RegimenItem) {
        var next = archive
        if let index = next.items.firstIndex(where: { $0.id == item.id }) { next.items[index] = item } else { next.items.append(item) }
        commit(next)
    }
    func log(_ item: RegimenItem, quantity: Decimal, unit: DoseUnit, at: Date, scheduled: Date? = nil, note: String = "") {
        guard quantity > 0 else { return }
        if let scheduled, archive.doses.contains(where: { $0.itemID == item.id && $0.scheduledAt == scheduled }) { return }
        var next = archive
        next.doses.append(TakenDose(itemID: item.id, product: item.product, quantity: quantity, unit: unit, takenAt: at, scheduledAt: scheduled, note: note))
        commit(next)
    }
    func restore(_ data: Data) throws {
        guard archive.items.isEmpty && archive.doses.isEmpty && archive.legacyJSON == nil else { throw StoreError.invalid("Import is allowed only into an empty native tracker to avoid overwriting or duplicating records.") }
        if let native = try? JSONDecoder().decode(Archive.self, from: data), native.version == 1 { commit(native); importReport = "Native archive restored."; return }
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any], let items = root["items"] as? [[String: Any]], root["logs"] is [String: Any] else { throw StoreError.invalid("Not a supported LIFEBLOOD export.") }
        var next = archive
        next.legacyJSON = data
        let format = DateFormatter(); format.dateFormat = "yyyy-MM-dd"; format.locale = Locale(identifier: "en_US_POSIX")
        var map: [String: RegimenItem] = [:]
        for raw in items {
            guard let name = raw["name"] as? String, let id = raw["id"] as? String else { throw StoreError.invalid("An existing item is missing its identity; nothing imported.") }
            let p = Product(id: "legacy:" + id, brand: name, generic: raw["ingredient"] as? String ?? "", strength: raw["dose"] as? String ?? "Not confirmed", formulation: raw["cat"] as? String ?? "Not confirmed", route: raw["route"] as? String ?? "Not confirmed", ingredients: [], missing: ["Structured ingredients and dose must be confirmed from the original label."])
            var item = RegimenItem(product: p)
            item.legacyID = id; item.legacyDose = raw["dose"] as? String
            item.quantity = 0 // Not used for totals until a structured dose is explicitly confirmed.
            item.times = raw["times"] as? [String] ?? []
            let oldDays = raw["days"] as? [Int] ?? []
            item.weekdays = oldDays.isEmpty ? Array(1...7) : oldDays.map { $0 + 1 }
            item.start = (raw["start"] as? String).flatMap(format.date(from:)) ?? Calendar.current.startOfDay(for: Date())
            item.end = (raw["end"] as? String).flatMap(format.date(from:))
            item.stopped = raw["stopped"] as? Bool ?? false
            item.instructions = [raw["notes"], raw["food"]].compactMap { $0 as? String }.joined(separator: "\n")
            next.items.append(item); map[id] = item
        }
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let logs = root["logs"] as? [String: [String: Any]] ?? [:]
        for (key, log) in logs where log["status"] as? String == "taken" {
            let parts = key.components(separatedBy: "|")
            guard let item = map[parts[0]], let at = log["at"] as? String, let date = iso.date(from: at) ?? ISO8601DateFormatter().date(from: at) else { continue }
            next.doses.append(TakenDose(itemID: item.id, product: item.product, quantity: 0, unit: .serving, takenAt: date, note: "Imported dose amount unconfirmed. " + (log["note"] as? String ?? "")))
        }
        commit(next)
        importReport = "Imported \(next.items.count) items and \(next.doses.count) taken-dose records. All original records, skipped doses, reminder settings and symptom notes remain in the attached legacy archive. Confirm structured doses before relying on totals. Browser calendar events are not removed or changed."
    }
    func recheckClinical() async {
        let generation = UUID(); clinicalGeneration = generation
        clinicalResult = nil
        guard UserDefaults.standard.bool(forKey: "clinicalConsent") else { clinicalStatus = "Clinical provider checks are off. Local limited checks only."; return }
        clinicalStatus = "Checking the current regimen with the configured clinical provider…"
        do {
            let result = try await ProductService().check(archive.items, endpoint: UserDefaults.standard.string(forKey: "productEndpoint") ?? "")
            guard clinicalGeneration == generation else { return }
            clinicalResult = result
            clinicalStatus = result.complete ? "Provider returned a check for the submitted regimen. Review its stated coverage." : "Provider check is incomplete. Review missing coverage."
        } catch {
            guard clinicalGeneration == generation else { return }
            clinicalStatus = error.localizedDescription
        }
    }
    func scheduleReminders(requestPermission: Bool = false) async {
        let center = UNUserNotificationCenter.current()
        if requestPermission {
            do { _ = try await center.requestAuthorization(options: [.alert, .sound, .badge]) }
            catch { reminderStatus = error.localizedDescription; return }
        }
        let settings = await center.notificationSettings()
        guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else { reminderStatus = "Notifications are off. Enable them in iPhone Settings."; return }
        let pending = await center.pendingNotificationRequests()
        center.removePendingNotificationRequests(withIdentifiers: pending.filter { $0.identifier.hasPrefix("lifeblood:") }.map(\.identifier))
        // One-shot events respect start/end dates. iOS permits at most 64 pending notifications.
        // Replenish on foreground; disclose the actual scheduling horizon.
        var candidates: [(Date, RegimenItem)] = []
        for n in 0..<60 {
            guard let day = Calendar.current.date(byAdding: .day, value: n, to: Date()) else { continue }
            for item in archive.items where item.scheduled(on: day) {
                for time in item.times {
                    if let date = Self.scheduledDate(day, time: time), date > Date() { candidates.append((date, item)) }
                }
            }
        }
        let existingOther = pending.filter { !$0.identifier.hasPrefix("lifeblood:") }.count
        let events = Array(candidates.sorted { $0.0 < $1.0 }.prefix(max(0, 64 - existingOther)))
        for (date, item) in events {
            let content = UNMutableNotificationContent(); content.title = "LIFEBLOOD"; content.body = "A health item is due. Open LIFEBLOOD to record your dose."; content.sound = .default
            let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
            let request = UNNotificationRequest(identifier: "lifeblood:\(item.id):\(date.timeIntervalSince1970)", content: content, trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false))
            do { try await center.add(request) } catch { reminderStatus = "Some reminders could not be scheduled: \(error.localizedDescription)"; return }
        }
        reminderStatus = events.last.map { "\(events.count) alerts scheduled through \($0.0.formatted()). Reopen the app regularly to replenish alerts. Delivery depends on iOS permissions and Focus settings." } ?? "No future scheduled doses."
    }
    static func scheduledDate(_ day: Date, time: String) -> Date? {
        let parts = time.split(separator: ":").compactMap { Int($0) }
        guard parts.count == 2, (0...23).contains(parts[0]), (0...59).contains(parts[1]) else { return nil }
        return Calendar.current.date(bySettingHour: parts[0], minute: parts[1], second: 0, of: day)
    }
    var summary: String {
        "LIFEBLOOD — user-entered medication summary\nGenerated \(Date().formatted())\n\n" + archive.items.map { item in
            "\(item.product.display)\n\(item.legacyDose ?? String(describing: item.quantity)) \(item.unit.rawValue); \(item.asNeeded ? "as needed" : item.times.joined(separator: ", ") + "; weekdays " + item.weekdays.map(String.init).joined(separator: ","))\n\(item.product.ingredients.map { "\($0.name): \($0.amount) \($0.unit.rawValue) per \($0.per) \($0.productUnit.rawValue)" }.joined(separator: "\n"))\nVerified: \(item.product.verified); stopped: \(item.stopped)\n\(item.instructions)\n\(item.product.sources.map { "\($0.title) \($0.url.absoluteString), checked \($0.checked.formatted())" }.joined(separator: "\n"))"
        }.joined(separator: "\n\n") + "\n\n" + SafetyEngine.coverage + "\nDo not stop or change prescribed treatment without professional advice."
    }
}
