import Foundation
import Combine

/// Live-price + history coordinator for every pair that doesn't go
/// through the Iranian snapshot pipeline. Despite the legacy name
/// (kept so env-object wiring stays intact), this scheduler manages
/// FOUR pairs concurrently: `ounce`, `btc`, `sol`, `eth`. Each has
/// its own Yahoo history symbol (`GC=F` / `BTC-USD` / `SOL-USD` /
/// `ETH-USD`) and Twelve Data WebSocket symbol (`XAU/USD` / `BTC/USD`
/// / `SOL/USD` / `ETH/USD`).
///
/// Source priority per pair:
///   1. **Twelve Data WebSocket** — primary live tick stream for all
///      four symbols on a single socket (free-tier allows 8 symbols).
///   2. **gold-api.com** — fallback ONLY for `ounce` (no equivalent
///      free spot endpoint for crypto). Polled every 10s when the
///      stream's last `XAU/USD` tick is older than `streamStaleSeconds`.
///   3. **Yahoo Finance** — authoritative history sync per pair every
///      6th tick (~60s). Overwrites whatever the live sources rolled
///      and provides the long-tail backfill on launch / gap-fill.
@MainActor
final class YahooScheduler: ObservableObject {
    /// Latest spot price per pair, keyed by internal pair id
    /// (`ounce`, `btc`, `sol`, `eth`). The dashboard reads this map
    /// directly for sidebar / header / chart-tag price display.
    @Published private(set) var latestPrices: [String: Double] = [:]
    /// Back-compat accessor — many existing call sites still read
    /// `latestOuncePrice` specifically. Returns the entry in the map
    /// rather than a separate stored field.
    var latestOuncePrice: Double? { latestPrices["ounce"] }

    /// When set, only this pair is actively synced (all other pairs
    /// are paused). Set to `nil` to sync all pairs (macOS default).
    /// iPad sets this to the selected pair to reduce CPU usage.
    var focusedPairID: String?

    /// Mac: the currently selected pair in the dashboard. Drives
    /// dual-speed ticking — the selected pair gets live data every
    /// `fastTickSeconds` (5s), while all other pairs sync every
    /// `slowTickSeconds` (60min). Set from AppState; `nil` means
    /// tick everything at the fast rate (fallback).
    var selectedPairID: String?

    /// Timestamp of the last successful update (any source). Drives
    /// the dashboard's "fresh as of …" indicator and the countdown.
    @Published private(set) var lastUpdateAt: Date?
    /// Last error string, source-prefixed (`twelve-data:` /
    /// `gold-api:` / `yahoo:`) so the UI can see which feed died.
    @Published private(set) var lastError: String?
    /// True once the first Yahoo history bootstrap completed for at
    /// least one pair. Used to gate "no data" UI states.
    @Published private(set) var hasBootstrapped: Bool = false
    /// In-flight indicator for the spinner.
    @Published private(set) var isFetching: Bool = false
    /// Which source delivered the most recent price tick to ANY pair.
    /// Surfaced in the debug pane.
    @Published private(set) var activeLiveSource: String = "(none)"

    /// Source series currently being deep-backfilled, keyed
    /// `"pairID|sourceTF"` (e.g. `"ounce|1h"`). The dashboard watches
    /// this to show a loading skeleton over the chart while the
    /// historical candles for the selected timeframe are still
    /// arriving from Yahoo.
    @Published private(set) var backfilling: Set<String> = []

    /// Source series we've already pulled to full depth this session,
    /// so toggling back to a timeframe doesn't re-download years of
    /// bars. Populated by both the bootstrap and on-demand backfills.
    private var deepBackfilled: Set<String> = []

    /// Source series currently fetching an *older* page from Twelve Data
    /// (the pan-left "load more history" path), keyed `"pairID|sourceTF"`.
    /// The dashboard watches this to show a "loading older bars" hint at
    /// the left edge without blocking the rest of the chart.
    @Published private(set) var loadingOlder: Set<String> = []

    /// Series we've paged all the way back on — Twelve Data returned
    /// nothing older than what we already had. Stops the pan-left
    /// trigger from re-requesting (and burning the daily request quota)
    /// once we've hit the bottom of available history.
    private var exhaustedOlder: Set<String> = []

    /// Bumped each time the ounce series is cleared + refetched because
    /// the user changed the gold data source. The dashboard observes this
    /// and does a full `reloadCandles()` (the cheap trailing splice can't
    /// represent a wholesale clear). `@Published` so SwiftUI sees it.
    @Published private(set) var dataResetToken: Int = 0

    /// Combine subscription to `DataSourceConfig.$goldSource`. On a real
    /// change we clear the ounce bars and refetch from the new upstream.
    private var goldSourceCancellable: AnyCancellable?

    /// Combine subscription to `DataSourceConfig.$farazCookie`. A fresh
    /// cookie (e.g. captured by the in-app re-login flow after a 401)
    /// restarts the Faraz WS with the new credential and backfills.
    private var farazCookieCancellable: AnyCancellable?

    /// Active data source, read live from the shared config (both this
    /// scheduler and the config are `@MainActor`, so this is safe).
    private var goldSource: GoldDataSource { DataSourceConfig.shared.goldSource }

    /// True when a pair should be driven by Faraz rather than the
    /// default Twelve Data + Yahoo path. The source toggle is global, so
    /// any pair Faraz has a symbol for (gold + BTC/SOL/ETH) follows it;
    /// pairs without a Faraz mapping (indices) always stay on Yahoo.
    private func usesFaraz(_ pairID: String) -> Bool {
        goldSource == .faraz && FarazHistorySource.symbolByPairID[pairID] != nil
    }

    /// Pair ids Faraz can serve — derived from the symbol map so adding a
    /// crypto symbol there is the only change needed to extend coverage.
    private var farazPairIDs: [String] {
        pairs.map(\.pairID).filter { FarazHistorySource.symbolByPairID[$0] != nil }
    }

    private func backfillKey(_ pairID: String, _ sourceTF: String) -> String {
        "\(pairID)|\(sourceTF)"
    }

    /// Deepest `(range, interval)` Yahoo will serve for each native
    /// source series. These are the per-interval ceilings — asking for
    /// more just returns the same window.
    private func deepFetchSpec(forSourceTF tf: String) -> (range: String, interval: String)? {
        switch tf {
        case "1m": return ("8d",  "1m")
        case "5m": return ("60d", "5m")
        case "1h": return ("2y",  "1h")
        case "1d": return ("10y", "1d")
        default:   return nil
        }
    }

    /// 10s tick — for the gold-api fallback path. Twelve Data ticks
    /// arrive on their own clock independent of this.
    let tickIntervalSeconds: Int = 10

    /// Mac dual-speed: selected pair ticks at this rate.
    private let fastTickSeconds: Int = 5
    /// Mac dual-speed: non-selected pairs tick at this rate.
    private let slowTickSeconds: Int = 3600

    /// Yahoo history sync runs every Nth tick (~60s).
    private let yahooEveryNTicks: Int = 6

    /// gold-api fallback kicks in when the XAU stream has been quiet
    /// for this long. 30s is well past Twelve Data's heartbeat
    /// cadence — anything longer means we've actually lost the
    /// stream.
    private let streamStaleSeconds: TimeInterval = 30

    /// Per-pair config: which symbol to ask each upstream for, plus
    /// market-calendar flags. Driven directly from
    /// `TradingPair.catalog` so adding a new metal/crypto pair is
    /// purely a catalog entry + this static map.
    private struct PairConfig {
        let pairID: String
        let yahooSymbol: String         // e.g. "GC=F", "BTC-USD", "^DJI"
        /// nil = no Twelve Data WS feed for this symbol (e.g. US
        /// indices on the free tier). The bar history still syncs
        /// via Yahoo polling — the chart just doesn't get
        /// sub-second live ticks for these pairs.
        let twelveDataSymbol: String?
        let respectsWeekend: Bool       // forex + indices = yes, crypto = no
        let goldAPIFallback: Bool       // only ounce has a free spot fallback
    }

    private let pairs: [PairConfig] = [
        .init(pairID: "ounce", yahooSymbol: "GC=F",    twelveDataSymbol: "XAU/USD",
              respectsWeekend: true,  goldAPIFallback: true),
        .init(pairID: "wti",   yahooSymbol: "CL=F",    twelveDataSymbol: nil,
              respectsWeekend: true,  goldAPIFallback: false),
        .init(pairID: "btc",   yahooSymbol: "BTC-USD", twelveDataSymbol: "BTC/USD",
              respectsWeekend: false, goldAPIFallback: false),
        .init(pairID: "sol",   yahooSymbol: "SOL-USD", twelveDataSymbol: "SOL/USD",
              respectsWeekend: false, goldAPIFallback: false),
        .init(pairID: "eth",   yahooSymbol: "ETH-USD", twelveDataSymbol: "ETH/USD",
              respectsWeekend: false, goldAPIFallback: false),
        .init(pairID: "dji",   yahooSymbol: "^DJI",    twelveDataSymbol: nil,
              respectsWeekend: true,  goldAPIFallback: false),
        .init(pairID: "dxy",   yahooSymbol: "DX-Y.NYB", twelveDataSymbol: nil,
              respectsWeekend: true,  goldAPIFallback: false),
    ]

    /// Reverse-lookup helper: Twelve Data symbol → internal pair id.
    /// Built once from `pairs` and used in the WS tick callback to
    /// route a tick by symbol back to the right OHLC bucket. Pairs
    /// with no Twelve Data feed (nil `twelveDataSymbol`) drop out.
    private var pairIDByTwelveDataSymbol: [String: String] {
        Dictionary(uniqueKeysWithValues: pairs.compactMap { cfg in
            cfg.twelveDataSymbol.map { ($0, cfg.pairID) }
        })
    }

    private var task: Task<Void, Never>?
    private var stream: TwelveDataSpotStream?
    private var farazStream: FarazWebSocketStream?
    private var farazWSObservation: AnyCancellable?
    private var tickCount: Int = 0
    /// Wall-clock of the most recent tick delivered by `FarazWebSocketStream`.
    /// When this is recent the 10s HTTP poll is suppressed — the WS is the
    /// live source. HTTP still runs every Nth tick for 5m / 1h / 1d bars
    /// that the WS doesn't broadcast.
    private var lastFarazWSTick: Date?
    /// Seconds of silence before we consider the Faraz WS stale and fall
    /// back to the HTTP poll. 20s is comfortably past the Socket.IO
    /// heartbeat interval (25s), so a live socket always wins.
    private let farazWSStaleSeconds: TimeInterval = 20

    /// True when the Faraz WS has ever completed a successful namespace
    /// handshake this session. Published so the UI can distinguish
    /// "WS never connected" from "WS connected but stale".
    @Published private(set) var farazWSConnected: Bool = false
    /// True when the Faraz WS has established at least one successful
    /// connection this session (even if it's currently disconnected/reconnecting).
    @Published private(set) var farazWSEverConnected: Bool = false

    /// Repo reference cached at start() so external entry points can
    /// roll bars without re-plumbing the AppDatabase through every
    /// call. OHLCRepo is a value type so a strong reference is fine.
    private var cachedRepo: OHLCRepo?

    /// External entry point for ticks from sources OTHER than this
    /// scheduler's owned TwelveData / gold-api / Yahoo, feeding them
    /// through the exact same OHLC + published-price pipeline as
    /// everything else. No-op until `start(database:)` has populated
    /// `cachedRepo`.
    func applyExternalTick(price: Double, pairID: String, source: String) {
        guard let repo = cachedRepo else { return }
        // applyLiveTick is async (DB bar-roll runs off-main). Hop onto a
        // task so this synchronous entry point stays non-blocking.
        Task { await self.applyLiveTick(price: price, pairID: pairID, source: source, repo: repo) }
    }

    // ── On-demand deep backfill ───────────────────────────────────────

    /// Pull + store the full Yahoo depth for one pair's source series
    /// (1m / 5m / 1h / 1d). Idempotent within a session — a series
    /// already filled (by the bootstrap or a prior call) returns
    /// immediately. Publishes `backfilling` around the network round
    /// trip so the dashboard can show a skeleton while history loads.
    /// No-op until `start(database:)` has cached the repo.
    func ensureDeepHistory(pairID: String, sourceTF: String) async {
        guard let repo = cachedRepo else { return }
        let key = backfillKey(pairID, sourceTF)
        if deepBackfilled.contains(key) || backfilling.contains(key) { return }
        guard let cfg = pairs.first(where: { $0.pairID == pairID }) else { return }

        // When Faraz is the active source, pairs it doesn't serve
        // (e.g. US30 index) have no upstream at all — skip the
        // deep fetch entirely rather than falling through to Yahoo.
        if goldSource == .faraz && !usesFaraz(pairID) { return }

        let faraz = usesFaraz(pairID)
        // Each source supports its own set of timeframes — bail early on
        // an unsupported TF so we don't insert a `backfilling` flag that
        // never clears.
        if faraz {
            guard FarazHistorySource.resolution(forSourceTF: sourceTF) != nil else { return }
        } else {
            guard deepFetchSpec(forSourceTF: sourceTF) != nil else { return }
        }

        backfilling.insert(key)
        defer { backfilling.remove(key) }
        do {
            let bars: [OHLCBar]
            if faraz {
                // Faraz honours the from..to window (not `countback` as a
                // cap), so a large bar count here just widens `from` — giving
                // deep history per TF (~8d of 1m, ~41d of 5m, ~1.4y of 1h,
                // decades of 1d), comparable to Yahoo's per-interval ceilings.
                bars = try await fetchFarazWindow(
                    pairID: pairID, sourceTF: sourceTF, cfg: cfg,
                    to: Date(), countback: 12000, firstDataRequest: true
                )
            } else {
                let spec = deepFetchSpec(forSourceTF: sourceTF)!
                bars = try await YahooGoldSource.fetchHistory(
                    pairID: pairID, symbol: cfg.yahooSymbol,
                    skipWeekends: cfg.respectsWeekend,
                    range: spec.range, interval: spec.interval
                )
            }
            try await repo.upsertMany(bars)
            deepBackfilled.insert(key)
            publishLastUpdate()
        } catch {
            self.lastError = "\(faraz ? "faraz" : "yahoo") backfill \(pairID)/\(sourceTF): \(error.localizedDescription)"
        }
    }

    /// Build + run one Faraz `/history` request for a source timeframe,
    /// anchored at `to` and reaching `countback` bars back. Centralises
    /// the symbol lookup + from/to math so the bootstrap, periodic sync,
    /// and pan-left paths all issue identical requests.
    private func fetchFarazWindow(
        pairID: String, sourceTF: String, cfg: PairConfig,
        to: Date, countback: Int, firstDataRequest: Bool
    ) async throws -> [OHLCBar] {
        let cookie     = DataSourceConfig.shared.farazCookie
        let apiBaseURL = DataSourceConfig.shared.farazAPIURL
        let symbol = FarazHistorySource.symbolByPairID[pairID] ?? "XAU_USD"
        let from = to.addingTimeInterval(-Double(countback * FarazHistorySource.tfSeconds(sourceTF)))
        return try await FarazHistorySource.fetchHistory(
            pairID: pairID, symbol: symbol, tfTag: sourceTF,
            from: from, to: to, countback: countback, cookie: cookie,
            apiBaseURL: apiBaseURL,
            firstDataRequest: firstDataRequest, skipWeekends: cfg.respectsWeekend
        )
    }

    /// Warm every native series for one pair at once (1m/5m/1h/1d),
    /// fetched in parallel. Used to pre-fill all timeframes rather than
    /// lazily per selection.
    func backfillAll(pairID: String) async {
        await withTaskGroup(of: Void.self) { group in
            for tf in ["1m", "5m", "1h", "1d"] {
                group.addTask { [self] in
                    await ensureDeepHistory(pairID: pairID, sourceTF: tf)
                }
            }
        }
    }

    // ── Pan-left "load older history" (Twelve Data REST) ─────────────

    /// Fetch one older page of intraday bars for a source series and
    /// prepend it to the stored history. Yahoo caps 1m at ~8d and 5m at
    /// ~60d, so once the user pans past that the chart hits a wall;
    /// Twelve Data's `time_series` REST endpoint reaches years further
    /// back for the same symbols. Anchors the (backward-counting) request
    /// on the oldest bar we currently have and upserts whatever's older.
    ///
    /// Returns the number of genuinely-older bars added (0 = nothing new,
    /// either because we've hit the bottom of available data or the fetch
    /// failed). Idempotent against concurrent calls + a per-series
    /// "exhausted" latch so a user pinned at the left edge can't spin the
    /// request quota. No-op for coarse TFs (1h/1d already reach years via
    /// Yahoo) and until `start(database:)` has cached the repo.
    @discardableResult
    func loadOlderHistory(pairID: String, sourceTF: String) async -> Int {
        guard let repo = cachedRepo else { return 0 }
        // Only the intraday series are Yahoo-capped; 1h/1d go back years
        // already, so there's nothing for Twelve Data to extend there.
        guard sourceTF == "1m" || sourceTF == "5m" else { return 0 }
        let key = backfillKey(pairID, sourceTF)
        if loadingOlder.contains(key) || exhaustedOlder.contains(key) { return 0 }
        guard let cfg = pairs.first(where: { $0.pairID == pairID }),
              let earliest = try? await repo.earliestBucket(pairID: pairID, timeframe: sourceTF)
        else { return 0 }

        let faraz = usesFaraz(pairID)
        loadingOlder.insert(key)
        defer { loadingOlder.remove(key) }
        do {
            // End the window one second before our oldest bar so the page
            // is strictly older (the boundary bar would just dedupe).
            let cutoff = earliest.addingTimeInterval(-1)
            let bars: [OHLCBar]
            if faraz {
                guard !DataSourceConfig.shared.farazCookie.isEmpty else { return 0 }
                bars = try await fetchFarazWindow(
                    pairID: pairID, sourceTF: sourceTF, cfg: cfg,
                    to: cutoff, countback: 5000, firstDataRequest: false
                )
            } else {
                let apiKey = TwelveDataSpotStream.apiKey
                guard !apiKey.isEmpty, let symbol = cfg.twelveDataSymbol else { return 0 }
                bars = try await TwelveDataHistorySource.fetchHistory(
                    pairID: pairID, symbol: symbol, tfTag: sourceTF,
                    end: cutoff, apiKey: apiKey,
                    skipWeekends: cfg.respectsWeekend
                )
            }
            let older = bars.filter { $0.bucketStart < earliest }
            guard !older.isEmpty else {
                exhaustedOlder.insert(key)
                return 0
            }
            try await repo.upsertMany(older)
            publishLastUpdate()
            return older.count
        } catch {
            self.lastError = "\(faraz ? "faraz" : "twelve-data") history \(pairID)/\(sourceTF): \(error.localizedDescription)"
            return 0
        }
    }

    /// Start every loop. Idempotent — repeated calls from AppState's
    /// boot path are no-ops once running.
    func start(database: AppDatabase) {
        guard task == nil else { return }
        let repo = database.ohlcRepo
        cachedRepo = repo

        // Live-stream source selection. Every Twelve Data-served
        // symbol (ounce + BTC/SOL/ETH) is Faraz-driven when Faraz is
        // on, so opening the Twelve Data socket in that mode just
        // delivers ticks the per-tick `usesFaraz` gate would drop —
        // wasted bandwidth + reconnect churn. Open exactly one of
        // the two; `switchGoldSource` toggles between them when the
        // user changes Settings.
        if goldSource == .faraz {
            startFarazStream(repo: repo)
        } else {
            startTwelveDataStream(repo: repo)
        }

        // Watch for a gold-source switch in Settings. `dropFirst` skips
        // the value present at subscription; `removeDuplicates` ignores a
        // save that didn't actually change the source (e.g. only the
        // cookie changed). A real change clears + refetches the ounce.
        goldSourceCancellable = DataSourceConfig.shared.$goldSource
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in
                guard let self else { return }
                Task { await self.switchGoldSource(repo: repo) }
            }

        // Watch for a fresh Faraz cookie (the in-app re-login flow saves one
        // after a 401). Restart the WS with the new credential and backfill
        // so live data resumes without a source switch. Only relevant while
        // Faraz is the active source.
        farazCookieCancellable = DataSourceConfig.shared.$farazCookie
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in
                guard let self else { return }
                guard DataSourceConfig.shared.goldSource == .faraz else { return }
                Task { await self.reloadFarazAfterAuth(repo: repo) }
            }

        // 2) Bootstrap + polling/sync loop.
        // Mac: dual-speed — selected pair at 5s, others at 60min.
        // iPad: single loop via focusedPairID (already gates pairs).
        task = Task { [weak self] in
            await self?.bootstrapAndGapFill(repo: repo)
            guard let self else { return }
            // Fast loop: selected pair only (or all when selectedPairID is nil).
            let fastTask = Task { [weak self] in
                while !Task.isCancelled {
                    let interval = UInt64(self?.fastTickSeconds ?? 5) * 1_000_000_000
                    try? await Task.sleep(nanoseconds: interval)
                    if Task.isCancelled { break }
                    await self?.tick(repo: repo, onlyPair: self?.selectedPairID)
                }
            }
            // Slow loop: all pairs EXCEPT the selected one.
            let slowTask = Task { [weak self] in
                while !Task.isCancelled {
                    let interval = UInt64(self?.slowTickSeconds ?? 3600) * 1_000_000_000
                    try? await Task.sleep(nanoseconds: interval)
                    if Task.isCancelled { break }
                    await self?.tick(repo: repo, excludePair: self?.selectedPairID)
                }
            }
            // Keep both alive until cancelled.
            await fastTask.value
            await slowTask.value
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        stopTwelveDataStream()
        stopFarazStream()
        goldSourceCancellable?.cancel()
        goldSourceCancellable = nil
        farazCookieCancellable?.cancel()
        farazCookieCancellable = nil
    }

    /// Resume the Faraz feed after a fresh cookie is captured (in-app
    /// re-login). Unlike `switchGoldSource` this does NOT wipe stored bars —
    /// the source is unchanged, only the credential — so we just restart the
    /// live WS and backfill each Faraz pair, then nudge the dashboard.
    @MainActor
    private func reloadFarazAfterAuth(repo: OHLCRepo) async {
        startFarazStream(repo: repo)
        for pairID in farazPairIDs {
            await backfillAll(pairID: pairID)
        }
        dataResetToken &+= 1
    }

    // ── Gold-source switch (clear + refetch) ──────────────────────────

    /// React to the user changing the ounce's data source in Settings:
    /// wipe the stored ounce bars (so two providers' OHLC can't
    /// interleave), drop this pair's session backfill latches, then
    /// refetch deep history from the now-active upstream. Bumps
    /// `dataResetToken` at the end so the dashboard does a full reload.
    // MARK: - Live-stream lifecycle

    /// One socket, all four Twelve Data symbols (XAU + BTC + SOL + ETH).
    /// Idempotent — repeated calls stop the previous stream first. Kept
    /// open for the lifetime the app is in non-Faraz mode; closed via
    /// `stopTwelveDataStream` (called from `stop` / `switchGoldSource`)
    /// when Faraz takes over, since every symbol this socket would
    /// deliver is Faraz-driven and the ticks would just be dropped.
    private func startTwelveDataStream(repo: OHLCRepo) {
        stopTwelveDataStream()
        let s = TwelveDataSpotStream(symbols: pairs.compactMap { $0.twelveDataSymbol })
        s.onTick = { [weak self] symbol, price in
            guard let self = self else { return }
            let id = self.pairIDByTwelveDataSymbol[symbol] ?? symbol
            // Source gate: when this pair is Faraz-driven, ignore the
            // Twelve Data tick — Faraz's 10s poll + Faraz WS are the
            // authoritative feeds. The socket is normally closed
            // entirely in this case, but the per-tick gate stays as a
            // belt-and-braces against a windowed source switch.
            if self.usesFaraz(id) { return }
            Task { await self.applyLiveTick(price: price, pairID: id, source: "twelve-data", repo: repo) }
        }
        s.start()
        stream = s
    }

    private func stopTwelveDataStream() {
        stream?.stop()
        stream = nil
    }

    // MARK: - Faraz WebSocket stream lifecycle

    private func startFarazStream(repo: OHLCRepo) {
        stopFarazStream()
        let symbols    = Array(FarazHistorySource.symbolByPairID.values)
        let cookie     = DataSourceConfig.shared.farazCookie
        let apiBaseURL = DataSourceConfig.shared.farazAPIURL
        let s = FarazWebSocketStream(symbols: symbols, cookie: cookie, apiBaseURL: apiBaseURL)
        s.onTick = { [weak self] pairID, price in
            guard let self else { return }
            Task { await self.applyFarazTick(price: price, pairID: pairID, repo: repo) }
        }
        s.onCandle = { [weak self] bar in
            guard let self else { return }
            Task {
                try? await repo.upsertMany([bar])
                // Throttled to 1 Hz — Faraz can push many candle
                // updates per second; an unthrottled write here
                // pegs the main thread on chart redraws.
                await MainActor.run { self.publishLastUpdate() }
            }
        }
        // Observe WS connection state changes.
        farazWSObservation = s.$isConnected.combineLatest(s.$wsEverConnected)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] connected, everConnected in
                self?.farazWSConnected = connected
                self?.farazWSEverConnected = everConnected
            }
        s.start()
        farazStream = s
    }

    private func stopFarazStream() {
        farazStream?.stop()
        farazStream = nil
        farazWSObservation?.cancel()
        farazWSObservation = nil
        farazWSConnected = false
        // Don't reset farazWSEverConnected — it's a session-lifetime flag
    }

    /// True when the Faraz WS has delivered a tick recently enough to be
    /// considered the authoritative live source. Mirrors `streamIsFreshForOunce`.
    private func farazWSIsFresh() -> Bool {
        guard let last = lastFarazWSTick else { return false }
        return Date().timeIntervalSince(last) < farazWSStaleSeconds
    }

    /// Live tick from the Faraz WebSocket — bypasses the `usesFaraz` gate
    /// that suppresses other sources, since this IS the Faraz source.
    private func applyFarazTick(price: Double, pairID: String, repo: OHLCRepo) async {
        lastFarazWSTick = Date()
        let cfg = pairs.first { $0.pairID == pairID }
        let respectsWeekend = cfg?.respectsWeekend ?? false
        // Bar-rolling on every tick — buckets must reflect the latest
        // price the moment it lands; gating this would let bars lag.
        try? await rollLiveBar(pairID: pairID, timeframe: "1m", bucketSize: 60,
                               respectsWeekend: respectsWeekend, price: price, repo: repo)
        try? await rollLiveBar(pairID: pairID, timeframe: "5m", bucketSize: 300,
                               respectsWeekend: respectsWeekend, price: price, repo: repo)
        // @Published side (price tag, source label, lastUpdateAt) is
        // throttled to 1 Hz — see `publishTick`.
        publishTick(price: price, pairID: pairID, source: "faraz-ws")
    }

    /// Push the latest tick to the `@Published` side of this scheduler,
    /// throttled to 1 Hz. `latestPrices`, `activeLiveSource` and
    /// `lastUpdateAt` are all `@Published`, so every set fires
    /// `objectWillChange` and re-evaluates every SwiftUI view that
    /// touches ANY of this scheduler's properties via `@EnvironmentObject`
    /// — including the whole `DashboardView` body, `ChartView`, the
    /// three `OscillatorPanel`s, the sidebar `PairRow`s, etc.
    ///
    /// Live providers (Twelve Data WS, Faraz WS) can push
    /// 5–20 ticks per second per symbol; an unthrottled publish pegs the
    /// main thread on chart redraws. 1 Hz is plenty for the price-tag UI
    /// AND for the trade / alert evaluators (they observe
    /// `yahoo.$latestPrices` and care about price touches against
    /// entry / TP / SL — not cadence).
    ///
    /// The bar-rolling DB writes upstream of this call are explicitly NOT
    /// throttled — buckets must reflect the latest tick the instant it
    /// arrives; the trailing-splice / Yahoo history sync reads from the
    /// DB, not from `latestPrices`, so they're unaffected by this gate.
    private func publishTick(price: Double, pairID: String, source: String) {
        let now = Date()
        if let prev = lastUpdateAt, now.timeIntervalSince(prev) < 1.0 {
            return
        }
        // Batch all @Published writes so objectWillChange fires once
        // instead of once per property (3-4x per tick). Without this,
        // each write re-evaluates the entire DashboardView body and
        // dismisses any open Menu / context menu.
        objectWillChange.send()
        latestPrices[pairID] = price
        activeLiveSource = "\(source)/\(pairID)"
        lastUpdateAt = now
        hasBootstrapped = true
    }

    /// Throttled `lastUpdateAt` write for paths that don't carry a
    /// live price — deep-history backfill, pan-left older-bars load,
    /// Faraz WS candle arrivals. Same 1 Hz gate as `publishTick`
    /// so the `@Published` cascade (DashboardView body → ChartView →
    /// OscillatorPanels → Apple Charts scene graph) fires at most
    /// once per second regardless of how fast the upstream pushes
    /// data.
    private func publishLastUpdate() {
        let now = Date()
        if let prev = lastUpdateAt, now.timeIntervalSince(prev) < 1.0 {
            return
        }
        objectWillChange.send()
        lastUpdateAt = now
        hasBootstrapped = true
    }

    private func switchGoldSource(repo: OHLCRepo) async {
        // Toggle both live-stream sockets to match the new selection.
        // Faraz on  → close Twelve Data (every TD-served symbol is
        //            Faraz-driven now, so the socket would just deliver
        //            ticks the per-tick `usesFaraz` gate drops).
        // Faraz off → reopen Twelve Data, close Faraz.
        if goldSource == .faraz {
            stopTwelveDataStream()
            startFarazStream(repo: repo)
        } else {
            stopFarazStream()
            startTwelveDataStream(repo: repo)
        }

        // The toggle is global, so every Faraz-capable pair flips between
        // Faraz and Twelve Data + Yahoo at once — clear + refetch them all
        // so two providers' OHLC can't interleave in any series.
        let affected = farazPairIDs
        objectWillChange.send()
        for pairID in affected {
            // Forget what we've already fetched for this pair so the new
            // source's deep history + pan-left start fresh.
            deepBackfilled = deepBackfilled.filter { !$0.hasPrefix("\(pairID)|") }
            exhaustedOlder = exhaustedOlder.filter { !$0.hasPrefix("\(pairID)|") }
            try? await repo.deleteAll(pairID: pairID)
            latestPrices[pairID] = nil
        }

        // Refetch every native series from the active source (the routing
        // inside ensureDeepHistory picks Faraz vs Yahoo). Fan out across
        // pairs so the four series each fetch in parallel.
        await withTaskGroup(of: Void.self) { group in
            for pairID in affected {
                group.addTask { [self] in await self.backfillAll(pairID: pairID) }
            }
        }

        dataResetToken &+= 1
        publishLastUpdate()
    }

    // ── Bootstrap / gap-fill ──────────────────────────────────────────
    //
    // Yahoo-only: gold-api has no history, Twelve Data's free tier
    // doesn't expose historical OHLC over WS. One pass over every
    // managed pair at launch; gaps detected by latest stored bar.
    private func bootstrapAndGapFill(repo: OHLCRepo) async {
        isFetching = true
        defer { isFetching = false }
        // Collect seed prices for all pairs, then write the whole
        // dictionary once at the end. Writing `latestPrices[k] = v`
        // inside the loop fires `objectWillChange` per pair — each
        // triggers a full DashboardView + ChartView body rerun, and
        // at bootstrap the chart just loaded years of deep history
        // so each rerun is expensive. A single dictionary assignment
        // collapses all four into one cascade.
        //
        // Parallel: each pair's 4 timeframes are fetched concurrently
        // via backfillAll/ensureDeepHistory, and pairs themselves run
        // concurrently via TaskGroup. The `deepBackfilled` /
        // `backfilling` guards inside ensureDeepHistory prevent
        // double-fetching. (Parallel-bootstrap Performance Fix.)
        let eligiblePairs = pairs.filter { cfg in
            !(goldSource == .faraz && !usesFaraz(cfg.pairID))
        }

        // Phase 1: deep history for all pairs in parallel.
        await withTaskGroup(of: Void.self) { group in
            for cfg in eligiblePairs {
                group.addTask { [self] in
                    // Weekend cleanup only matters for markets that have
                    // weekends; crypto never has closed-day rows.
                    if cfg.respectsWeekend {
                        _ = try? await repo.deleteClosedDayBars(pairID: cfg.pairID)
                    }
                    // Pull every native series to full depth. backfillAll
                    // already fans out 1m/5m/1h/1d in parallel.
                    await self.backfillAll(pairID: cfg.pairID)
                }
            }
        }
        hasBootstrapped = true

        // Phase 2: seed prices from the last stored 1m bar per pair.
        // These reads are cheap; batch them to avoid per-pair
        // @Published cascades.
        var seedPrices: [String: Double] = [:]
        await withTaskGroup(of: (String, Double?).self) { group in
            for cfg in eligiblePairs {
                group.addTask {
                    var price: Double?
                    if let last1m = try? await repo.latestBucket(pairID: cfg.pairID, timeframe: "1m"),
                       let recent = try? await repo.read(
                        pairID: cfg.pairID, timeframe: "1m",
                        since: last1m.addingTimeInterval(-60),
                        until: last1m
                       ).last {
                        price = recent.close
                    }
                    return (cfg.pairID, price)
                }
            }
            for await (pairID, price) in group {
                if let price { seedPrices[pairID] = price }
            }
        }
        // Single @Published write — one chart cascade instead of N.
        if !seedPrices.isEmpty {
            objectWillChange.send()
            for (pairID, price) in seedPrices {
                latestPrices[pairID] = price
            }
        }
        publishLastUpdate()
    }

    // ── Periodic tick ─────────────────────────────────────────────────
    /// - onlyPair: if set, only tick this pair (fast loop for selected).
    /// - excludePair: if set, tick all pairs EXCEPT this one (slow loop
    ///   for non-selected). When both nil, tick everything.
    private func tick(repo: OHLCRepo, onlyPair: String? = nil, excludePair: String? = nil) async {
        isFetching = true
        defer { isFetching = false }
        tickCount += 1

        // Filter pairs: iPad uses focusedPairID, Mac uses onlyPair/excludePair
        // for dual-speed ticking.
        let activePairs: [PairConfig]
        if let focused = focusedPairID {
            // On iPad, focusedPairID gates to just the focused pair.
            // When the slow loop passes excludePair that matches the
            // focused pair, this is a no-op — the fast loop already
            // handles it.
            if let exclude = excludePair, exclude == focused { return }
            activePairs = pairs.filter { $0.pairID == focused }
        } else if let only = onlyPair {
            activePairs = pairs.filter { $0.pairID == only }
        } else if let exclude = excludePair {
            activePairs = pairs.filter { $0.pairID != exclude }
        } else {
            activePairs = pairs
        }

        // Faraz-driven pairs: the WebSocket now provides live price ticks
        // and candle updates for ALL timeframes (1m/5m/15m/1h/4h/1D) in
        // real time. HTTP polling is only needed as a fallback when the
        // WS is stale/disconnected.
        if goldSource == .faraz {
            let wsFresh = farazWSIsFresh()
            let historyTick = tickCount % yahooEveryNTicks == 0
            if !wsFresh {
                // WS is stale or never connected — HTTP poll every tick as
                // the primary source for all timeframes.
                await syncFarazPairs(repo: repo, pairs: activePairs)
            } else if historyTick {
                // WS is fresh — only poll for 1h/1d history the WS doesn't
                // broadcast. 1m/5m come from the WS live ticks.
                await syncFarazPairsHistory(repo: repo, pairs: activePairs)
            }
        }

        // Yahoo authoritative history sync every Nth tick. Completely
        // skipped when Faraz is the active source — Faraz serves all
        // the pairs it covers via its own WS + HTTP path, and pairs
        // without a Faraz symbol (e.g. US30) go without Yahoo sync
        // while Faraz is on. Toggle back to the default source to
        // restore Yahoo-driven history for those pairs.
        if tickCount % yahooEveryNTicks == 0 && goldSource != .faraz {
            await withTaskGroup(of: Void.self) { group in
                for cfg in activePairs {
                    group.addTask { [self] in
                        await syncYahoo(cfg: cfg, repo: repo)
                    }
                }
            }
            publishLastUpdate()
        }
    }

    /// Faraz live/trailing sync for every Faraz-driven pair (gold +
    /// BTC/SOL/ETH). Fans out across pairs so one slow request doesn't
    /// stall the others within a 10s tick.
    private func syncFarazPairs(repo: OHLCRepo, pairs activePairs: [PairConfig]? = nil) async {
        guard !DataSourceConfig.shared.farazCookie.isEmpty else {
            self.lastError = "faraz: session cookie not set (Settings)."
            return
        }
        let allPairs = activePairs ?? pairs
        let faraz = allPairs.filter { FarazHistorySource.symbolByPairID[$0.pairID] != nil }
        await withTaskGroup(of: Void.self) { group in
            for cfg in faraz {
                group.addTask { [self] in await self.syncFarazPair(cfg: cfg, repo: repo) }
            }
        }
        // `publishTick` inside each `syncFarazPair` already wrote
        // `lastUpdateAt` / `latestPrices` / `activeLiveSource` at
        // most 1 Hz — no additional @Published write needed here.
        // Skip `hasBootstrapped` write to avoid an extra
        // objectWillChange cascade.
    }

    /// History-only sync when the WS is fresh — fetches 1h + 1d bars
    /// that the WS doesn't broadcast, skipping 1m/5m (the WS handles
    /// those live). Respects `activePairs` so iPad's focusedPairID
    /// filtering isn't bypassed.
    private func syncFarazPairsHistory(repo: OHLCRepo, pairs activePairs: [PairConfig]? = nil) async {
        guard !DataSourceConfig.shared.farazCookie.isEmpty else { return }
        let allPairs = activePairs ?? pairs
        let faraz = allPairs.filter { FarazHistorySource.symbolByPairID[$0.pairID] != nil }
        await withTaskGroup(of: Void.self) { group in
            for cfg in faraz {
                group.addTask { [self] in
                    for tf in ["1h", "1d"] {
                        do {
                            let bars = try await self.fetchFarazWindow(
                                pairID: cfg.pairID, sourceTF: tf, cfg: cfg,
                                to: Date(), countback: 30, firstDataRequest: false
                            )
                            try await repo.upsertMany(bars)
                        } catch {
                            await MainActor.run {
                                self.lastError = "faraz \(cfg.pairID)/\(tf): \(error.localizedDescription)"
                            }
                        }
                    }
                }
            }
        }
    }

    /// Fallback sync for one Faraz pair when the WS is stale/disconnected.
    /// Fetches 1m bars every tick for the live price, and the remaining
    /// timeframes (5m/15m/30m/1h/4h/1d) only every `yahooEveryNTicks`
    /// ticks (~60s) to avoid hammering the API with redundant requests
    /// for timeframes that rarely change.
    private func syncFarazPair(cfg: PairConfig, repo: OHLCRepo) async {
        // 1m every tick — this is the live-price source when WS is down.
        var newestClose: Double?
        do {
            let bars = try await fetchFarazWindow(
                pairID: cfg.pairID, sourceTF: "1m", cfg: cfg,
                to: Date(), countback: 30, firstDataRequest: false
            )
            try await repo.upsertMany(bars)
            if let last = bars.last { newestClose = last.close }
        } catch {
            self.lastError = "faraz \(cfg.pairID)/1m: \(error.localizedDescription)"
        }

        // Coarser timeframes only on the history tick (~60s cadence).
        if tickCount % yahooEveryNTicks == 0 {
            for tf in ["5m", "15m", "30m", "1h", "4h", "1d"] {
                do {
                    let bars = try await fetchFarazWindow(
                        pairID: cfg.pairID, sourceTF: tf, cfg: cfg,
                        to: Date(), countback: 30, firstDataRequest: false
                    )
                    try await repo.upsertMany(bars)
                } catch {
                    self.lastError = "faraz \(cfg.pairID)/\(tf): \(error.localizedDescription)"
                }
            }
        }

        if let px = newestClose {
            publishTick(price: px, pairID: cfg.pairID, source: "faraz")
        }
    }

    /// Sync one pair's 1m + 5m + 1h + 1d history in parallel.
    /// Errors are captured into `lastError` but don't bail — one pair
    /// failing shouldn't stop the others.
    ///
    /// Incremental: checks `latestBucket` for each timeframe and
    /// only fetches bars newer than what's stored. Falls back to
    /// the full `range` when no prior data exists.
    /// (Incremental-fetch Performance Fix.)
    private func syncYahoo(cfg: PairConfig, repo: OHLCRepo) async {
        // Faraz is the single source for every pair it serves; when
        // it's the active source, Yahoo is not needed at all — even
        // for pairs (e.g. US30) that have no Faraz symbol. Those
        // pairs simply go without periodic history sync while Faraz
        // is on; the user toggles back to default to restore them.
        if goldSource == .faraz { return }
        do {
            // Check what we already have for each timeframe so we
            // can pass `since` to Yahoo and skip re-fetching /
            // re-upserting thousands of stale bars.
            let latest1m  = try? await repo.latestBucket(pairID: cfg.pairID, timeframe: "1m")
            let latest5m  = try? await repo.latestBucket(pairID: cfg.pairID, timeframe: "5m")
            let latest1h  = try? await repo.latestBucket(pairID: cfg.pairID, timeframe: "1h")
            let latest1d  = try? await repo.latestBucket(pairID: cfg.pairID, timeframe: "1d")

            async let oneMinT = YahooGoldSource.fetchHistory(
                pairID: cfg.pairID, symbol: cfg.yahooSymbol,
                skipWeekends: cfg.respectsWeekend,
                range: "8d", interval: "1m",
                since: latest1m
            )
            async let fiveMinT = YahooGoldSource.fetchHistory(
                pairID: cfg.pairID, symbol: cfg.yahooSymbol,
                skipWeekends: cfg.respectsWeekend,
                range: "1mo", interval: "5m",
                since: latest5m
            )
            async let oneHourT = YahooGoldSource.fetchHistory(
                pairID: cfg.pairID, symbol: cfg.yahooSymbol,
                skipWeekends: cfg.respectsWeekend,
                range: "5d", interval: "1h",
                since: latest1h
            )
            async let oneDayT = YahooGoldSource.fetchHistory(
                pairID: cfg.pairID, symbol: cfg.yahooSymbol,
                skipWeekends: cfg.respectsWeekend,
                range: "1mo", interval: "1d",
                since: latest1d
            )
            let oneMin = try await oneMinT
            let fiveMin = try await fiveMinT
            let oneHour = try await oneHourT
            let oneDay = try await oneDayT
            try await repo.upsertMany(oneMin)
            try await repo.upsertMany(fiveMin)
            try await repo.upsertMany(oneHour)
            try await repo.upsertMany(oneDay)
        } catch {
            self.lastError = "yahoo \(cfg.pairID): \(error.localizedDescription)"
        }
    }

    // ── Live-tick handler (Twelve Data + gold-api) ───────────────────

    /// Common path for an incoming live price. Publishes it for the
    /// pair, rolls 1m + 5m buckets, updates timestamps + source tag.
    private func applyLiveTick(
        price: Double,
        pairID: String,
        source: String,
        repo: OHLCRepo
    ) async {
        // When this pair is on Faraz, its 10s poll is the only writer —
        // ignore ticks from every other provider (Twelve Data,
        // gold-api) so they can't interleave a second source's prices.
        if usesFaraz(pairID) { return }
        let cfg = pairs.first { $0.pairID == pairID }
        let respectsWeekend = cfg?.respectsWeekend ?? false
        // Bar-rolling on every tick — buckets must reflect the latest
        // price the moment it lands; gating this would let bars lag and
        // the trailing-splice UI path would show stale OHLC.
        try? await rollLiveBar(pairID: pairID, timeframe: "1m", bucketSize: 60,
                               respectsWeekend: respectsWeekend, price: price, repo: repo)
        try? await rollLiveBar(pairID: pairID, timeframe: "5m", bucketSize: 300,
                               respectsWeekend: respectsWeekend, price: price, repo: repo)
        // @Published side (price tag, source label, lastUpdateAt) is
        // throttled to 1 Hz — see `publishTick` for why.
        publishTick(price: price, pairID: pairID, source: source)
    }

    /// True if Twelve Data has delivered an XAU/USD tick recently.
    /// Drives the gold-api fallback gate (which only applies to the
    /// ounce — crypto symbols have no fallback path).
    private func streamIsFreshForOunce() -> Bool {
        guard let last = stream?.lastTickAtBySymbol["XAU/USD"] else { return false }
        return Date().timeIntervalSince(last) < streamStaleSeconds
    }

    // ── Helpers ───────────────────────────────────────────────────────

    /// Upsert (or extend) the open OHLC bar for "right now" at the
    /// given pair + timeframe. Open is captured on first touch;
    /// high/low expand monotonically; close always reflects the
    /// latest tick. For markets with a weekly close (gold), skips
    /// weekend buckets to keep stale Friday quotes out of the chart.
    ///
    /// The read-modify-write is done atomically inside the repo's SQL
    /// `ON CONFLICT` merge (`upsertLiveTickBar`) and runs off the main
    /// thread, so a burst of ticks for the same bucket can't race a
    /// stale read — and the main actor never blocks on SQLite here.
    private func rollLiveBar(
        pairID: String,
        timeframe: String,
        bucketSize: TimeInterval,
        respectsWeekend: Bool,
        price: Double,
        repo: OHLCRepo
    ) async throws {
        let nowSecs = Date().timeIntervalSince1970
        let bucketSecs = floor(nowSecs / bucketSize) * bucketSize
        let bucketStart = Date(timeIntervalSince1970: bucketSecs)
        if respectsWeekend && MarketCalendar.isClosedDay(bucketStart) { return }

        try await repo.upsertLiveTickBar(
            pairID: pairID,
            timeframe: timeframe,
            bucketStart: bucketStart,
            price: price
        )
    }
}
