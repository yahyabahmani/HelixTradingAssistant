import Foundation
import SwiftUI

/// A trading pair shown in the sidebar. After the open-source cut,
/// only live-streamed pairs are supported (Metal + Crypto) — there's
/// no longer a snapshot-table pipeline, so every pair sources its
/// price + history from `YahooScheduler` / `CTraderScheduler` /
/// `TwelveDataSpotStream`.
struct TradingPair: Identifiable, Hashable {
    let id: String          // e.g. "ounce", "btc", "eth", "sol"
    let name: String        // localized display name
    let symbol: String      // short code (XAU, BTC, …)
    let price: Double       // last known live price
    let change: Double      // absolute change vs previous tick
    let changePercent: Double
    let high24h: Double
    let low24h: Double
    let isOnline: Bool      // greyed in sidebar when source unreachable
    let colorHex: String    // per-pair accent ("#3B82F6", etc.)
    let category: Category  // sidebar grouping

    /// Market category — drives sidebar grouping. All categories
    /// share the live-stream + Yahoo-history pipeline; the split is
    /// purely about UX grouping (and which weekend-handling rules
    /// apply — crypto trades 24/7, forex + indices have a weekly
    /// close).
    enum Category: String, Codable, CaseIterable, Hashable {
        case forex, crypto, indices

        var label: String {
            switch self {
            case .forex:   return "Forex"
            case .crypto:  return "Crypto"
            case .indices: return "Indices"
            }
        }
    }

    /// Kept as a constant for callers that previously branched on
    /// snapshot-vs-live. Every pair is now live-streamed, so this
    /// is always `true`. Will be removed once the call sites
    /// settle.
    var usesLiveStream: Bool { true }

    /// SwiftUI Color from the hex string. Falls back to Theme.Color.info
    /// if the hex is malformed — keeps the UI from rendering as black.
    var color: Color {
        Color(hex: colorHex) ?? Theme.Color.info
    }
}

// ── Built-in pair catalog ───────────────────────────────────────────────

extension TradingPair {
    /// Static catalog seeded into `AppState.pairs` at boot. Live
    /// schedulers stream prices into this list keyed by `id`. The
    /// open-source build ships with a single metal pair (XAU/USD)
    /// + three crypto majors — extending the catalog is a one-line
    /// `.init(...)` addition here.
    static let catalog: [PairDefinition] = [
        // Forex — XAU/USD ounce (Twelve Data WS + Yahoo history,
        // cTrader bridge takes over when running).
        .init(id: "ounce",    name: "Gold Ounce",       symbol: "XAU",  colorHex: "#EAB308", category: .forex),

        // Commodity — WTI crude oil (Faraz WTICO_USD live, Yahoo CL=F
        // history). Grouped under Forex like the metal.
        .init(id: "wti",      name: "WTI Crude Oil",    symbol: "WTI",  colorHex: "#78350F", category: .forex),

        // Crypto — live from Twelve Data, history from Yahoo.
        .init(id: "btc",      name: "Bitcoin",          symbol: "BTC",  colorHex: "#F7931A", category: .crypto),
        .init(id: "sol",      name: "Solana",           symbol: "SOL",  colorHex: "#14F195", category: .crypto),
        .init(id: "eth",      name: "Ethereum",         symbol: "ETH",  colorHex: "#627EEA", category: .crypto),

        // Indices — Yahoo polling only (no Twelve Data WS on free
        // tier). 15m delayed on Yahoo for US indices but fine for
        // chart + TA. Respects weekend close.
        .init(id: "dji",      name: "Dow Jones",        symbol: "DJI",  colorHex: "#3B82F6", category: .indices),

        // Dollar index — Faraz TVC_DXY live + history, Yahoo DX-Y.NYB
        // when the source toggle is off Faraz.
        .init(id: "dxy",      name: "US Dollar Index",  symbol: "DXY",  colorHex: "#22C55E", category: .indices),
    ]

    /// Build the runtime `TradingPair` rows from the catalog. Prices
    /// default to 0 — the live schedulers fill them in as ticks
    /// arrive. UI treats a zero price as "no data yet" and renders
    /// a placeholder.
    static func seed() -> [TradingPair] {
        catalog.map { def in
            TradingPair(
                id: def.id,
                name: def.name,
                symbol: def.symbol,
                price: 0,
                change: 0,
                changePercent: 0,
                high24h: 0,
                low24h: 0,
                isOnline: false,
                colorHex: def.colorHex,
                category: def.category
            )
        }
    }
}

/// Lightweight static metadata about a pair, used to seed the sidebar
/// before any live ticks arrive.
struct PairDefinition: Identifiable, Hashable {
    let id: String
    let name: String
    let symbol: String
    let colorHex: String
    let category: TradingPair.Category

    var color: Color { Color(hex: colorHex) ?? Theme.Color.info }
}

// ── Color hex helper ────────────────────────────────────────────────────

extension Color {
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6,
              let n = UInt32(s, radix: 16) else { return nil }
        let r = Double((n >> 16) & 0xff) / 255.0
        let g = Double((n >> 8)  & 0xff) / 255.0
        let b = Double( n        & 0xff) / 255.0
        self = Color(red: r, green: g, blue: b)
    }
}
