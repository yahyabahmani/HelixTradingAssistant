import Foundation
import UserNotifications

struct NotificationChartTarget: Codable, Hashable, Identifiable {
    let pairID: String
    let timeframeRawValue: String
    let indicatorRawValue: String
    let candleDate: Date
    let price: Double
    let label: String

    var id: String {
        "\(pairID)|\(timeframeRawValue)|\(indicatorRawValue)|\(candleDate.timeIntervalSince1970)|\(price)"
    }
}

extension Notification.Name {
    static let helixNotificationOpened = Notification.Name("helix.notification.opened")
}

/// Presents local notifications even while Helix is the foreground app.
/// macOS otherwise accepts the request but suppresses the visible banner.
private final class ForegroundNotificationDelegate: NSObject, UNUserNotificationCenterDelegate {
    static let shared = ForegroundNotificationDelegate()

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }
        guard let encoded = response.notification.request.content.userInfo["chartTarget"] as? String,
              let data = Data(base64Encoded: encoded),
              let target = try? JSONDecoder().decode(NotificationChartTarget.self, from: data)
        else { return }
        DispatchQueue.main.async {
            NotificationCenter.default.post(
                name: .helixNotificationOpened,
                object: nil,
                userInfo: ["target": target]
            )
        }
    }
}

/// One entry in the app-wide notification history ("Inbox"). Every
/// code path that wants to alert the user — price/RSI alerts, order
/// block lifecycle events (`AlertStore`), Confluence Scanner
/// opportunities (`ScannerStore`) — funnels through
/// `NotificationInbox.record(...)` instead of calling
/// `UNUserNotificationCenter` directly. That's what gives the app a
/// single persisted history to browse AND a single place to decide
/// "have we already told the user about this" instead of every
/// caller inventing its own ad-hoc dedup.
struct NotificationRecord: Identifiable, Codable, Equatable {
    let id: UUID
    let pairID: String
    let pairLabel: String
    let category: Category
    let title: String
    let body: String
    /// Chart/analysis timeframe the triggering condition was
    /// evaluated on (e.g. "1h", "4h"), when the caller has one.
    /// Optional because some events (order block lifecycle across
    /// whichever timeframe the chart happened to be on) may not
    /// always have a crisp single timeframe.
    let timeframeLabel: String?
    let chartTarget: NotificationChartTarget?
    let createdAt: Date
    var isRead: Bool

    enum Category: String, Codable {
        case priceAlert
        case rsiAlert
        case orderBlock
        case strategy
        case scanner
        case changeOfCharacter

        var icon: String {
            switch self {
            case .priceAlert: return "bell.badge.fill"
            case .rsiAlert:   return "waveform.path.ecg"
            case .orderBlock: return "square.stack.3d.up.fill"
            case .strategy:   return "point.3.connected.trianglepath.dotted"
            case .scanner:    return "scope"
            case .changeOfCharacter: return "arrow.triangle.2.circlepath"
            }
        }

        var label: String {
            switch self {
            case .priceAlert: return "Price Alert"
            case .rsiAlert:   return "RSI Alert"
            case .orderBlock: return "Order Block"
            case .strategy:   return "Strategy"
            case .scanner:    return "Scanner"
            case .changeOfCharacter: return "Change of Character"
            }
        }
    }

    init(
        id: UUID = UUID(),
        pairID: String,
        pairLabel: String,
        category: Category,
        title: String,
        body: String,
        timeframeLabel: String?,
        chartTarget: NotificationChartTarget? = nil,
        createdAt: Date = Date(),
        isRead: Bool = false
    ) {
        self.id = id
        self.pairID = pairID
        self.pairLabel = pairLabel
        self.category = category
        self.title = title
        self.body = body
        self.timeframeLabel = timeframeLabel
        self.chartTarget = chartTarget
        self.createdAt = createdAt
        self.isRead = isRead
    }

    /// Defensive decoder — only `id`/`title`/`body` are load-bearing;
    /// everything else falls back so an older or future payload shape
    /// still decodes instead of wiping the whole inbox.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        pairID = try c.decodeIfPresent(String.self, forKey: .pairID) ?? ""
        pairLabel = try c.decodeIfPresent(String.self, forKey: .pairLabel) ?? ""
        category = try c.decodeIfPresent(Category.self, forKey: .category) ?? .priceAlert
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? ""
        body = try c.decodeIfPresent(String.self, forKey: .body) ?? ""
        timeframeLabel = try c.decodeIfPresent(String.self, forKey: .timeframeLabel)
        chartTarget = try c.decodeIfPresent(NotificationChartTarget.self, forKey: .chartTarget)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        isRead = try c.decodeIfPresent(Bool.self, forKey: .isRead) ?? false
    }
}

/// App-scoped, persistent inbox of every notification the app has
/// sent. Lives on `AppState` (constructed eagerly, no DB dependency)
/// and is also injected as its own `@EnvironmentObject` so any screen
/// — including ones that don't otherwise touch `AppState` — can read
/// unread counts / history without prop-drilling.
///
/// Persisted to UserDefaults under `notifications.inbox.v1`, capped
/// at 300 entries (oldest dropped first).
@MainActor
final class NotificationInbox: ObservableObject {
    @Published private(set) var records: [NotificationRecord] = []
    @Published private(set) var systemPermissionChecked = false
    @Published private(set) var systemPermissionGranted = false

    private static let storageKey = "notifications.inbox.v1"
    private static let cap = 300
    /// Default "don't tell them again this soon" window applied when
    /// a caller doesn't pass an explicit `cooldown`. Most callers
    /// (AlertStore, order-block lifecycle) already have their own
    /// one-shot-per-transition state machines, so this mostly exists
    /// as a backstop against a caller accidentally invoking `record`
    /// twice for the same condition.
    private static let defaultCooldown: TimeInterval = 60 * 15

    /// Last-fired timestamp per dedup key, rebuilt from persisted
    /// `records` on load so the cooldown survives a relaunch (a key
    /// that fired 5 minutes before quitting shouldn't be free to fire
    /// again 5 seconds after relaunch).
    private var lastFiredAt: [String: Date] = [:]

    var unreadCount: Int { records.filter { !$0.isRead }.count }

    /// Newest first.
    var sorted: [NotificationRecord] { records.sorted { $0.createdAt > $1.createdAt } }

    init() {
        load()
        configureSystemNotifications()
    }

    /// Record + post a system notification for `dedupKey`, unless the
    /// same key already fired within `cooldown` seconds. This is the
    /// single funnel every alert-producing subsystem should call
    /// through — it's what makes "don't send the same notification
    /// twice" a property of the inbox rather than something every
    /// caller has to reimplement.
    ///
    /// - Parameters:
    ///   - dedupKey: Stable identity for "this specific condition"
    ///     (e.g. `"alert|<uuid>"`, `"scanner|<setupID>"`). Pass `nil`
    ///     to always record with no dedup (rare — most callers have
    ///     an identity to key on).
    ///   - cooldown: How long, after firing for `dedupKey`, before
    ///     the same key is allowed to fire again. Defaults to 15
    ///     minutes; pass a longer window for conditions that can
    ///     legitimately stay "active" for hours (e.g. scanner
    ///     opportunities) so a re-evaluation loop doesn't spam.
    @discardableResult
    func record(
        dedupKey: String?,
        cooldown: TimeInterval = NotificationInbox.defaultCooldown,
        pairID: String,
        pairLabel: String,
        category: NotificationRecord.Category,
        title: String,
        body: String,
        timeframeLabel: String? = nil,
        chartTarget: NotificationChartTarget? = nil
    ) -> Bool {
        let now = Date()
        if let key = dedupKey, let last = lastFiredAt[key], now.timeIntervalSince(last) < cooldown {
            return false
        }
        if let key = dedupKey { lastFiredAt[key] = now }

        let record = NotificationRecord(
            pairID: pairID,
            pairLabel: pairLabel,
            category: category,
            title: title,
            body: body,
            timeframeLabel: timeframeLabel,
            chartTarget: chartTarget,
            createdAt: now
        )
        records.append(record)
        if records.count > Self.cap {
            records = Array(records.suffix(Self.cap))
        }
        save()
        post(record)
        return true
    }

    func markRead(id: UUID) {
        guard let idx = records.firstIndex(where: { $0.id == id }), !records[idx].isRead else { return }
        records[idx].isRead = true
        save()
    }

    func markAllRead() {
        guard records.contains(where: { !$0.isRead }) else { return }
        for idx in records.indices { records[idx].isRead = true }
        save()
    }

    func remove(id: UUID) {
        records.removeAll { $0.id == id }
        save()
    }

    func clearAll() {
        records = []
        lastFiredAt = [:]
        save()
    }

    // ── System notification ────────────────────────────────────────

    private func configureSystemNotifications() {
        let center = UNUserNotificationCenter.current()
        center.delegate = ForegroundNotificationDelegate.shared
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                NSLog("Helix notification permission error: %@", error.localizedDescription)
            } else if !granted {
                NSLog("Helix notification permission was not granted")
            }
            Task { @MainActor [weak self] in
                self?.refreshSystemNotificationPermission()
            }
        }
        refreshSystemNotificationPermission()
    }

    func refreshSystemNotificationPermission() {
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            let granted = settings.authorizationStatus == .authorized
                || settings.authorizationStatus == .provisional
            Task { @MainActor [weak self] in
                self?.systemPermissionGranted = granted
                self?.systemPermissionChecked = true
            }
        }
    }

    private func post(_ record: NotificationRecord) {
        let content = UNMutableNotificationContent()
        content.title = record.title
        content.body = record.body
        content.sound = .default
        if let target = record.chartTarget,
           let data = try? JSONEncoder().encode(target) {
            content.userInfo["chartTarget"] = data.base64EncodedString()
        }
        let request = UNNotificationRequest(identifier: record.id.uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                NSLog("Helix notification delivery error: %@", error.localizedDescription)
            }
        }
    }

    // ── Persistence ───────────────────────────────────────────────

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.storageKey),
              let decoded = try? JSONDecoder().decode([NotificationRecord].self, from: data)
        else { return }
        records = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(records) else { return }
        UserDefaults.standard.set(data, forKey: Self.storageKey)
    }
}
