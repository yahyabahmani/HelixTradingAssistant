import SwiftUI

/// Sidebar → Inbox. Browsable history of every notification the app
/// has sent — price/RSI alerts, order-block lifecycle events, and
/// Confluence Scanner opportunities — all funnelled through the one
/// shared `NotificationInbox` store so there's a single place to see
/// what already fired instead of hunting through macOS Notification
/// Center.
struct NotificationInboxView: View {
    @EnvironmentObject private var inbox: NotificationInbox
    @EnvironmentObject private var app: AppState

    @State private var categoryFilter: NotificationRecord.Category? = nil

    private var filtered: [NotificationRecord] {
        guard let categoryFilter else { return inbox.sorted }
        return inbox.sorted.filter { $0.category == categoryFilter }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Theme.Color.border)
            if filtered.isEmpty {
                emptyState
            } else {
                list
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Theme.Color.canvas)
    }

    // ── Header ────────────────────────────────────────────────────

    private var header: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            HStack(spacing: Theme.Spacing.sm) {
                Label("Inbox", systemImage: "bell.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Theme.Color.textPrimary)
                if inbox.unreadCount > 0 {
                    Text("\(inbox.unreadCount) unread")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(Theme.Color.danger))
                }
                Spacer()
                Button { inbox.markAllRead() } label: {
                    Text("Mark all read")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.Color.textSecondary)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.Color.surface))
                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.Color.border, lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(inbox.unreadCount == 0)
                Button { inbox.clearAll() } label: {
                    Text("Clear all")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.Color.danger)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.Color.danger.opacity(0.1)))
                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.Color.danger.opacity(0.3), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .disabled(inbox.records.isEmpty)
            }
            filterRow
        }
        .padding(Theme.Spacing.lg)
    }

    private var filterRow: some View {
        HStack(spacing: Theme.Spacing.sm) {
            filterChip(nil, label: "All")
            filterChip(.priceAlert, label: "Price")
            filterChip(.rsiAlert, label: "RSI")
            filterChip(.orderBlock, label: "Order Blocks")
            filterChip(.strategy, label: "Strategy")
            Spacer()
        }
    }

    private func filterChip(_ category: NotificationRecord.Category?, label: String) -> some View {
        let selected = categoryFilter == category
        return Button { categoryFilter = category } label: {
            Text(label)
                .font(.system(size: 11, weight: selected ? .bold : .medium))
                .foregroundStyle(selected ? .white : Theme.Color.textSecondary)
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 7)
                    .fill(selected ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.Color.surface)))
                .overlay(RoundedRectangle(cornerRadius: 7)
                    .strokeBorder(selected ? Color.clear : Theme.Color.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
    }

    // ── List ──────────────────────────────────────────────────────

    private var list: some View {
        ScrollView {
            LazyVStack(spacing: Theme.Spacing.sm) {
                ForEach(filtered) { record in
                    row(record)
                }
            }
            .padding(Theme.Spacing.lg)
        }
    }

    private func row(_ record: NotificationRecord) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.md) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(categoryColor(record.category).opacity(0.14))
                    .frame(width: 32, height: 32)
                Image(systemName: record.category.icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(categoryColor(record.category))
            }
            .padding(.top, 2)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(record.title)
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Theme.Color.textPrimary)
                    if !record.isRead {
                        Circle().fill(Theme.Color.danger).frame(width: 6, height: 6)
                    }
                    Spacer()
                    Text(Self.relativeFmt.localizedString(for: record.createdAt, relativeTo: Date()))
                        .font(.system(size: 10))
                        .foregroundStyle(Theme.Color.textMuted)
                }
                Text(record.body)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Text(record.category.label.uppercased())
                        .font(.system(size: 8, weight: .heavy)).tracking(0.4)
                        .foregroundStyle(categoryColor(record.category))
                    if let tf = record.timeframeLabel, !tf.isEmpty {
                        Text("· \(tf)")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Theme.Color.textMuted)
                    }
                    if record.chartTarget != nil {
                        Spacer()
                        Label("Show on chart", systemImage: "arrow.up.right.square")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(Theme.Color.accentStart)
                    }
                }
            }

            Button { inbox.remove(id: record.id) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(Theme.Color.textMuted)
            }
            .buttonStyle(.plain)
        }
        .padding(Theme.Spacing.md)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.md).fill(Theme.Color.surface))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.md).strokeBorder(Theme.Color.border, lineWidth: 1))
        .contentShape(Rectangle())
        .onTapGesture {
            inbox.markRead(id: record.id)
            if let target = record.chartTarget {
                app.openNotificationChart(target)
            }
        }
    }

    private func categoryColor(_ category: NotificationRecord.Category) -> Color {
        switch category {
        case .priceAlert: return Theme.Color.info
        case .rsiAlert:   return Theme.Color.warn
        case .orderBlock: return Theme.Color.accentStart
        case .strategy:   return Theme.Color.success
        case .scanner:    return Theme.Color.danger
        case .changeOfCharacter: return Theme.Color.accentEnd
        }
    }

    private var emptyState: some View {
        VStack(spacing: Theme.Spacing.md) {
            Spacer()
            Image(systemName: "bell.slash")
                .font(.system(size: 40))
                .foregroundStyle(Theme.Color.textMuted)
            Text("No notifications yet")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.Color.textSecondary)
            Text("Price alerts, strategy signals, and scanner opportunities will show up here.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.Color.textMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private static let relativeFmt: RelativeDateTimeFormatter = {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .abbreviated
        return f
    }()
}
