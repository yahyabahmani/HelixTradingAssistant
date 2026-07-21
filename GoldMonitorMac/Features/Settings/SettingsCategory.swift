import Foundation

/// Settings left-rail categories. Lives at file scope so other
/// modules (AppState, the dashboard's deep-link gear button) can
/// reference it without nesting through `SettingsView`.
enum SettingsCategory: String, CaseIterable, Identifiable {
    case general, notifications, data, ai, network, autoTrader, about
    var id: String { rawValue }
    var label: String {
        switch self {
        case .general:    return "General"
        case .notifications: return "Notifications"
        case .data:       return "Data sources"
        case .ai:         return "AI"
        case .network:    return "Network"
        case .autoTrader: return "Auto-trader"
        case .about:      return "About"
        }
    }
    var symbol: String {
        switch self {
        case .general:    return "gearshape.fill"
        case .notifications: return "bell.badge.fill"
        case .data:       return "antenna.radiowaves.left.and.right"
        case .ai:         return "sparkles"
        case .network:    return "network.badge.shield.half.filled"
        case .autoTrader: return "wand.and.rays"
        case .about:      return "info.circle.fill"
        }
    }
    var blurb: String {
        switch self {
        case .general:    return "Markets visible in the sidebar + the first-run setup wizard."
        case .notifications: return "Choose which trading events can send app and macOS notifications."
        case .data:       return "Endpoints + API keys for the live data feeds and the AI binary."
        case .ai:         return "Claude model selection, reasoning effort, and token usage rollup."
        case .network:    return "SOCKS5 proxy for region-locked or corporate-network setups."
        case .autoTrader: return "Per-pair auto-trading: lot size, trailing stops, safety gates. Paper by default; live requires explicit opt-in (XAU/USD only in this build)."
        case .about:      return "App version + links to release notes and the project page."
        }
    }
}
