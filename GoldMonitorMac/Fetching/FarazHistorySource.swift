import Foundation

/// Pulls OHLC bars from Faraz's TradingView-UDF `/history` endpoint
/// (`https://faraz.io/api/customer/trading-view/history`). This is a
/// *customer* API — every request must carry the user's logged-in
/// session cookie (copied from the browser into Settings). Without it
/// the endpoint replies 401, so the scheduler surfaces a "set your
/// Faraz cookie" hint instead of silently failing.
///
/// The gold ounce (XAU/USD → `XAU_USD`) and the three crypto majors
/// (BTC/SOL/ETH → `BTCUSDT`/`SOLUSDT`/`ETHUSDT`) are wired; indices stay
/// on Yahoo. The endpoint speaks the standard TradingView UDF history
/// shape — `{ s, t[], o[], h[], l[], c[], v[] }` — and we tolerate a
/// `{ success, data: {…} }` envelope too, since the error path returns
/// `{ success:false, message:"…" }`.
enum FarazHistorySource {

    /// Internal pair id → Faraz `symbolName`. Faraz uses an
    /// underscore-separated form for the metal (`XAU_USD`) and a compact
    /// ticker for crypto (`BTCUSDT`) — both distinct from Twelve Data's
    /// slash form (`XAU/USD`). Any pair present here can be driven by
    /// Faraz when the user selects it as the data source.
    static let symbolByPairID: [String: String] = [
        "ounce": "XAU_USD",
        "wti":   "WTICO_USD",
        "btc":   "BTCUSDT",
        "sol":   "SOLUSDT",
        "eth":   "ETHUSDT",
    ]

    /// Fetch a window of bars for one source timeframe. Anchored by the
    /// `from`/`to` Unix-second range plus `countback` (UDF lets the
    /// server honour whichever bounds the data); bars come back tagged
    /// with `tfTag` so they upsert into the same native series Yahoo /
    /// Twelve Data fill. Weekend bars drop for the weekly-close metal.
    static func fetchHistory(
        pairID: String,
        symbol: String,
        tfTag: String,             // stored timeframe tag: "1m"/"5m"/"1h"/"1d"
        from: Date,
        to: Date,
        countback: Int,
        cookie: String,            // read at the @MainActor call site
        apiBaseURL: String,        // read at the @MainActor call site
        firstDataRequest: Bool,
        skipWeekends: Bool
    ) async throws -> [OHLCBar] {
        guard !cookie.isEmpty else { throw FarazError.noCookie }
        guard let resolution = resolution(forSourceTF: tfTag) else {
            throw FarazError.unsupportedTimeframe(tfTag)
        }

        var comps = URLComponents(string: "\(apiBaseURL)/api/customer/trading-view/history")!
        comps.queryItems = [
            .init(name: "symbolName", value: symbol),
            .init(name: "resolution", value: resolution),
            .init(name: "from", value: String(Int(from.timeIntervalSince1970))),
            .init(name: "to",   value: String(Int(to.timeIntervalSince1970))),
            .init(name: "countback", value: String(max(countback, 1))),
            .init(name: "firstDataRequest", value: firstDataRequest ? "true" : "false"),
            .init(name: "latest", value: "false"),
            .init(name: "adjustType", value: "2"),
            .init(name: "json", value: "true"),
        ]
        guard let url = comps.url else { throw FarazError.badURL }

        var req = URLRequest(url: url)
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("Mozilla/5.0 HelixTradingApp", forHTTPHeaderField: "User-Agent")
        req.setValue("\(apiBaseURL)/", forHTTPHeaderField: "Referer")
        // The whole auth story: a session cookie lifted from the browser.
        req.setValue(cookie, forHTTPHeaderField: "Cookie")

        let start = Date()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            await log(url: url, status: nil, durationMs: Date().timeIntervalSince(start) * 1000,
                      response: nil, error: error, headers: req.allHTTPHeaderFields)
            throw error
        }
        let durationMs = Date().timeIntervalSince(start) * 1000
        let status = (response as? HTTPURLResponse)?.statusCode
        await log(url: url, status: status, durationMs: durationMs, response: data, error: nil, headers: req.allHTTPHeaderFields)

        guard let http = response as? HTTPURLResponse else { throw FarazError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            // 401 here almost always means the cookie expired. Trigger the
            // in-app re-login flow (opens a faraz.io WKWebView, captures a
            // fresh session cookie) and surface the explicit error.
            if http.statusCode == 401 {
                FarazAuthCoordinator.shared.reportUnauthorized()
                throw FarazError.unauthorized
            }
            throw FarazError.http(status: http.statusCode)
        }

        let udf = try Self.decodeUDF(data)
        // Faraz's success body (`{"result":{…}}`) carries no `s` field, so
        // a nil status means "ok". Only an explicit non-ok status is an
        // error; `no_data` is a valid empty page (hit the bottom).
        if let s = udf.s {
            if s == "no_data" { return [] }
            if s != "ok" { throw FarazError.api(message: udf.errmsg ?? s) }
        }

        guard let t = udf.t, let o = udf.o, let h = udf.h,
              let l = udf.l, let c = udf.c else { return [] }
        let n = min(t.count, o.count, h.count, l.count, c.count)
        var bars: [OHLCBar] = []
        bars.reserveCapacity(n)
        for i in 0..<n {
            // UDF times are Unix seconds; guard against an accidental ms
            // payload (13-digit) by scaling down when the value is absurd.
            let raw = t[i]
            let secs = raw > 1_000_000_000_000 ? raw / 1000 : raw
            let date = Date(timeIntervalSince1970: secs)
            if skipWeekends && MarketCalendar.isClosedDay(date) { continue }
            let vol: Double? = (udf.v != nil && i < udf.v!.count) ? udf.v![i] : nil
            bars.append(OHLCBar(
                pairID: pairID,
                timeframe: tfTag,
                bucketStart: date,
                open: o[i], high: h[i], low: l[i], close: c[i],
                volume: vol
            ))
        }
        // UDF is oldest-first already, but sort defensively so the dedupe
        // upsert + chart are stable regardless of server ordering.
        bars.sort { $0.bucketStart < $1.bucketStart }
        return bars
    }

    // ── Mapping helpers ────────────────────────────────────────────────

    /// Stored timeframe tag → TradingView-UDF `resolution`. Minutes are
    /// bare numbers; daily is `1D`. Mirrors the four native series the
    /// rest of the app keeps (1m / 5m / 1h / 1d).
    static func resolution(forSourceTF tf: String) -> String? {
        switch tf {
        case "1m": return "1"
        case "5m": return "5"
        case "1h": return "60"
        case "1d": return "1D"
        default:   return nil
        }
    }

    /// Seconds per bar for a source timeframe — used to size the `from`
    /// anchor of a `countback`-bar request.
    static func tfSeconds(_ tf: String) -> Int {
        switch tf {
        case "1m": return 60
        case "5m": return 300
        case "1h": return 3600
        case "1d": return 86400
        default:   return 60
        }
    }

    // ── Decoding ───────────────────────────────────────────────────────

    /// Decode the OHLC payload from any of the shapes Faraz / UDF use:
    ///   1. `{ "result": { o,h,l,c,v,t } }`  — Faraz's actual success body
    ///   2. raw UDF `{ s, t, o, … }`         — vanilla TradingView UDF
    ///   3. `{ success:false, message }`      — error envelope
    /// The error path is surfaced as a thrown `FarazError.api` so an
    /// auth/symbol problem doesn't masquerade as an empty "no more data".
    private static func decodeUDF(_ data: Data) throws -> UDF {
        let dec = JSONDecoder()
        // 1) Faraz wraps the bars under `result` (no status field).
        if let wrap = try? dec.decode(ResultEnvelope.self, from: data),
           let r = wrap.result, r.t != nil {
            return r
        }
        // 2) Raw UDF — OHLC arrays / status at the top level.
        if let udf = try? dec.decode(UDF.self, from: data),
           udf.s != nil || udf.t != nil {
            return udf
        }
        // 3) Error / success envelope.
        let env = try dec.decode(Envelope.self, from: data)
        if env.success == false {
            throw FarazError.api(message: env.message ?? "Faraz request failed")
        }
        if let inner = env.data { return inner }
        throw FarazError.invalidResponse
    }

    private static func log(
        url: URL, status: Int?, durationMs: Double, response: Data?, error: Error?,
        headers: [String: String]? = nil
    ) async {
        await MainActor.run {
            NetworkLog.shared.record(
                source: "faraz",
                method: "GET",
                url: url.absoluteString,
                status: status,
                durationMs: durationMs,
                response: response,
                error: error,
                headers: headers
            )
        }
    }
}

// MARK: - Wire format
//
// TradingView UDF /history success:
//   { "s":"ok", "t":[…secs], "o":[…], "h":[…], "l":[…], "c":[…], "v":[…] }
// no more data:
//   { "s":"no_data", "nextTime": … }
// error (raw or enveloped):
//   { "s":"error", "errmsg":"…" }  ·  { "success":false, "message":"…" }
//
// OHLC arrays are aligned to `t[]` by index. Faraz returns numeric arrays
// (not the string-encoded numbers Twelve Data uses), so [Double] decodes
// directly.

private struct UDF: Decodable {
    let s: String?
    let t: [Double]?
    let o: [Double]?
    let h: [Double]?
    let l: [Double]?
    let c: [Double]?
    let v: [Double]?
    let errmsg: String?
    let nextTime: Double?
}

private struct Envelope: Decodable {
    let success: Bool?
    let message: String?
    let data: UDF?
}

/// Faraz's success shape: `{ "result": { o,h,l,c,v,t }, "last": … }`.
/// We only need `result`; `last` (latest tick metadata) is ignored —
/// the newest bar's close serves as the live price.
private struct ResultEnvelope: Decodable {
    let result: UDF?
}

enum FarazError: LocalizedError {
    case noCookie
    case unauthorized
    case badURL
    case invalidResponse
    case unsupportedTimeframe(String)
    case http(status: Int)
    case api(message: String)

    var errorDescription: String? {
        switch self {
        case .noCookie:                    return "Faraz session cookie not set (Settings)."
        case .unauthorized:                return "Faraz session expired — re-paste your cookie in Settings."
        case .badURL:                      return "Could not construct Faraz URL."
        case .invalidResponse:             return "Faraz sent a malformed response."
        case .unsupportedTimeframe(let t): return "Faraz history not supported for timeframe \(t)."
        case .http(let s):                 return "Faraz HTTP \(s)."
        case .api(let m):                  return "Faraz: \(m)"
        }
    }
}
