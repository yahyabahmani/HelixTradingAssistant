import SwiftUI
import Charts

struct ChartViewiPad: View {
    let candles: [Candle]
    let chartType: ChartType
    let accent: Color

    @Binding var xDomain: ClosedRange<Double>?
    @Binding var yDomain: ClosedRange<Double>?

    let indicators: Set<IndicatorKind>
    let indicatorConfig: OscillatorConfig

    /// Higher-timeframe CHoCH zones (dated so they re-anchor onto the
    /// current, lower timeframe via `barIndex(forDate:)`). Computed
    /// upstream in `ChartPlotiPad`; empty unless the CHoCH HTF option is on.
    var htfChochZones: [ChangeOfCharacter.DatedZone] = []

    var srLevels: PromptBuilder.SRLevels = .init(support: [], resistance: [])
    var fvgZones: [PromptBuilder.FVGZone] = []
    var supplyDemandZones: [PromptBuilder.SupplyDemandZone] = []
    var taScenario: PromptBuilder.TAScenario? = nil
    var taAltScenario: PromptBuilder.TAScenario? = nil
    var drawings: [ChartDrawing] = []
    var activeTool: DrawingTool = .none

    /// Contract spec for the pair on screen — drives position-tool
    /// sizing. Passed down because the chart is otherwise pair-agnostic.
    var contractSpec: ContractSpec = .forPair(id: "ounce")
    var onCommitDrawing: ((ChartDrawing) -> Void)? = nil
    var onMoveDrawing: ((ChartDrawing) -> Void)? = nil
    var selectedDrawingID: UUID? = nil
    var onSelectDrawing: ((UUID?) -> Void)? = nil
    var trades: [Trade] = []
    var journalEntries: [JournalEntry] = []
    var livePrice: Double? = nil
    var replayActive: Bool = false

    /// ForexFactory economic-calendar events plotted as impact-coloured
    /// flags on the bottom time axis (see `NewsChartLayer`). Already
    /// currency/impact-filtered by `NewsStore.chartEvents`; the chart
    /// maps each `eventAt` to a bar and draws only the visible ones.
    var newsEvents: [ForexFactoryEvent] = []
    /// Display zone for the news popup timestamp (`NewsStore.effectiveTimeZone`).
    var newsTimeZone: TimeZone = .current

    @State private var hovered: HoverState?

    /// The news event whose flag was tapped, if any — drives the
    /// floating detail popover. Anchor is the flag point in the overlay
    /// coordinate space.
    @State private var selectedNews: ForexFactoryEvent?
    @State private var newsPopupAnchor: CGPoint = .zero
    @StateObject private var derived = ChartDerivedCache()
    @State private var dragStartDomain: ClosedRange<Double>?
    @State private var dragStartYDomain: ClosedRange<Double>?
    @State private var panLockedY = false
    @State private var magnifyStartDomain: ClosedRange<Double>?
    @State private var magnifyStartYDomain: ClosedRange<Double>?
    @State private var yScaleStartDomain: ClosedRange<Double>?
    @State private var drawingStart: DrawingPoint?
    @State private var drawingEnd: DrawingPoint?
    @State private var movingDrawingOriginal: ChartDrawing?
    @State private var movingDeltaTime: TimeInterval = 0
    @State private var movingDeltaPrice: Double = 0
    @State private var editingDrawingID: UUID?
    @State private var editingHandle: ChartDrawing.Handle?
    @State private var editingCursor: DrawingPoint?
    @State private var dragHadMovement: Bool = false
    /// Which axis a one-finger drag manipulates, decided on the first
    /// frame from where the touch started: the right price-axis gutter
    /// scales Y, the bottom time-axis gutter scales X, and anywhere
    /// inside the plot pans. Sticks for the rest of the gesture.
    @State private var axisDragMode: AxisDragMode = .pan
    @State private var crosshairActive: Bool = false
    @State private var crosshairLocation: CGPoint = .zero

    private struct HoverState: Equatable {
        let candle: Candle
        let index: Int
        let cursor: CGPoint
        let cursorPrice: Double
    }

    var body: some View {
        if candles.isEmpty {
            emptyState
        } else {
            chart
                .clipped()
                .overlay(alignment: .topLeading) { hoverTooltip }
        }
    }

    // MARK: - Chart body

    private var displayCandles: [Candle] {
        derived.displayCandles(
            candles: candles,
            heikinAshi: chartType == .heikinAshi,
            livePrice: livePrice
        )
    }

    private var utBotOutput: UTBot.Output? {
        guard indicators.contains(.utBot) else { return nil }
        return derived.utBot(
            candles: candles,
            keyValue: indicatorConfig.utKeyValue,
            atrPeriod: indicatorConfig.utATRPeriod,
            useHeikinAshi: indicatorConfig.utUseHeikinAshi
        )
    }

    private var orderBlockZones: [OrderBlocks.Zone] {
        guard indicators.contains(.orderBlock) else { return [] }
        let all = derived.orderBlocks(
            candles: candles,
            periods: indicatorConfig.obPeriods,
            threshold: indicatorConfig.obThreshold,
            useWicks: indicatorConfig.obUseWicks,
            detectSteroids: indicatorConfig.obDetectSteroids
        )
        let filtered = indicatorConfig.obShowExhausted ? all : all.filter { $0.status != .exhausted }
        return Array(filtered.suffix(6))
    }

    private var steroidOrderBlockZones: [SteroidOrderBlocks.Zone] {
        guard indicators.contains(.steroidOrderBlock) else { return [] }
        let all = derived.steroidOrderBlocks(
            candles: candles,
            periods: indicatorConfig.sobPeriods,
            threshold: indicatorConfig.sobThreshold,
            useWicks: indicatorConfig.sobUseWicks,
            volumeMultiplier: indicatorConfig.sobVolumeMultiplier,
            detectSteroids: indicatorConfig.sobDetectSteroids
        )
        let filtered = indicatorConfig.sobShowExhausted ? all : all.filter { $0.status != .exhausted }
        return Array(filtered.suffix(6))
    }


    /// Volume-Filtered Order Blocks — swing-anchored, volume-tagged zones.
    private var volumeFilteredOBZones: [VolumeFilteredOrderBlocks.Zone] {
        guard indicators.contains(.volumeFilteredOrderBlock) else { return [] }
        let cfg = indicatorConfig
        return derived.volumeFilteredOrderBlocks(
            candles: candles,
            swingLength: cfg.vfobSwingLength,
            invalidationWick: cfg.vfobInvalidation == "Wick",
            maxZonesPerSide: Self.vfobZoneCount(cfg.vfobZoneCount),
            showHistoric: cfg.vfobShowHistoric,
            combine: true
        ).zones
    }

    static func vfobZoneCount(_ preset: String) -> Int {
        switch preset {
        case "One":    return 1
        case "Medium": return 5
        case "High":   return 10
        default:       return 3   // "Low"
        }
    }

    private var sonarlabOBZones: [SonarlabOrderBlocks.Zone] {
        guard indicators.contains(.sonarlabOrderBlock) else { return [] }
        let mitType: SonarlabOrderBlocks.MitigationType =
            indicatorConfig.sonarlabMitigationType == "Wick" ? .wick : .close
        let all = derived.sonarlabOrderBlocks(
            candles: candles,
            sensitivity: indicatorConfig.sonarlabSensitivity,
            mitigationType: mitType
        )
        return Array(all.suffix(Self.maxSonarlabOBs))
    }
    private static let maxSonarlabOBs = 20

    /// Ranked Order Block zones — swing-structure OBs graded A/B/C by
    /// Volume Profile + Ichimoku confluence.
    private var rankedOBZones: [RankedOrderBlocks.Zone] {
        guard indicators.contains(.rankedOrderBlock) else { return [] }
        return derived.rankedOrderBlocks(
            candles: candles,
            config: indicatorConfig.rankedOrderBlockConfiguration
        )
    }

    /// Change of Character confluence zones — structure break + OB/FVG.
    private var chochZones: [ChangeOfCharacter.Zone] {
        guard indicators.contains(.changeOfCharacter) else { return [] }
        return derived.changeOfCharacter(
            candles: candles,
            swingLength: indicatorConfig.chochSwingLength,
            minSwingPct: indicatorConfig.chochMinSwingPct,
            requireFVG: indicatorConfig.chochRequireFVG,
            showMitigated: indicatorConfig.chochShowMitigated
        )
    }

    private var indicatorFvgZones: [FairValueGap.Zone] {
        guard indicators.contains(.fairValueGap) else { return [] }
        let all = derived.fairValueGaps(
            candles: candles,
            threshold: indicatorConfig.fvgThreshold
        )
        return indicatorConfig.fvgShowMitigated ? all : all.filter { !$0.isMitigated }
    }

    private var sessionRuns: [TradingSessions.SessionRun] {
        guard indicators.contains(.tradingSession) else { return [] }
        var latest: [String: TradingSessions.SessionRun] = [:]
        for run in derived.tradingSessions(candles: candles) where indicatorConfig.showsSession(run.sessionID) {
            latest[run.sessionID] = run
        }
        return latest.values.sorted { $0.start < $1.start }
    }

    private var nySetupResults: [NYOpenSetup.Result] {
        guard indicators.contains(.nyOpenSetup) else { return [] }
        let all = derived.nyOpenSetup(
            candles: candles,
            atrMult: indicatorConfig.nyAtrMult,
            amOnly: indicatorConfig.nyAMOnly
        )
        guard !all.isEmpty,
              let b = ChartWindow.visibleBounds(domain: effectiveXDomain, count: candles.count)
        else { return [] }
        let lastIndex = candles.count - 1
        let margin = max(8, (b.hi - b.lo) / 4)
        let lo = b.lo - margin
        let hi = b.hi + margin
        return all.suffix(3).filter { r in
            let end = r.resolveIndex ?? lastIndex
            return end >= lo && r.orStartIndex <= hi
        }
    }

    private var sp2lResults: [SP2LSetup.Result] {
        guard indicators.contains(.sp2lStrategy) else { return [] }
        let all = derived.sp2lSetup(candles: candles, config: indicatorConfig)
        guard !all.isEmpty,
              let bounds = ChartWindow.visibleBounds(domain: effectiveXDomain, count: candles.count)
        else { return [] }
        let lastIndex = candles.count - 1
        let margin = max(8, (bounds.hi - bounds.lo) / 4)
        let low = bounds.lo - margin
        let high = bounds.hi + margin
        return all.suffix(5).filter { result in
            guard sp2lResultFitsCurrentCandles(result) else { return false }
            let end = result.resolveIndex ?? lastIndex
            return end >= low && result.spikeStartIndex <= high
        }
    }

    private func sp2lResultFitsCurrentCandles(_ result: SP2LSetup.Result) -> Bool {
        let upper = candles.count - 1
        guard upper >= 0 else { return false }
        let required = [
            result.levelStartIndex,
            result.spikeStartIndex,
            result.spikeEndIndex,
            result.breakoutIndex,
            result.followThroughIndex,
            result.gapStartIndex,
            result.gapEndIndex
        ]
        guard required.allSatisfy({ $0 >= 0 && $0 <= upper }) else { return false }
        return [result.pullbackIndex, result.entryIndex, result.resolveIndex]
            .compactMap { $0 }
            .allSatisfy { $0 >= 0 && $0 <= upper }
    }

    private var microMapResults: [MicroMapSetup.Result] {
        guard indicators.contains(.microMapStrategy) else { return [] }
        let all = derived.microMapSetup(candles: candles, config: indicatorConfig)
        guard !all.isEmpty,
              let bounds = ChartWindow.visibleBounds(domain: effectiveXDomain, count: candles.count)
        else { return [] }
        let margin = max(8, (bounds.hi - bounds.lo) / 4)
        return all.suffix(5).filter { result in
            microMapResultFitsCurrentCandles(result) &&
            result.lastRelevantIndex >= bounds.lo - margin &&
            result.spikeStartIndex <= bounds.hi + margin
        }
    }

    private func microMapResultFitsCurrentCandles(_ result: MicroMapSetup.Result) -> Bool {
        let upper = candles.count - 1
        guard upper >= 0 else { return false }
        let indices = [
            result.spikeStartIndex,
            result.spikeEndIndex,
            result.microStartIndex,
            result.microEndIndex,
            result.lastRelevantIndex
        ] + result.attempts.flatMap {
            [$0.anchorIndex, $0.triggerIndex, $0.stopIndex, $0.targetIndex].compactMap { $0 }
        }
        return indices.allSatisfy { $0 >= 0 && $0 <= upper }
    }

    private var pinBarComboResults: [PinBarComboSetup.Result] {
        guard indicators.contains(.pinBarCombo) else { return [] }
        let bases = derived.sp2lSetup(candles: candles, config: indicatorConfig)
        let all = derived.pinBarComboSetup(
            candles: candles,
            sp2lResults: bases,
            config: indicatorConfig
        )
        guard !all.isEmpty,
              let bounds = ChartWindow.visibleBounds(domain: effectiveXDomain, count: candles.count)
        else { return [] }
        let margin = max(8, (bounds.hi - bounds.lo) / 4)
        return all.suffix(6).filter { result in
            pinBarComboResultFitsCurrentCandles(result)
                && result.lastRelevantIndex >= bounds.lo - margin
                && result.structureStartIndex <= bounds.hi + margin
        }
    }

    private func pinBarComboResultFitsCurrentCandles(_ result: PinBarComboSetup.Result) -> Bool {
        let upper = candles.count - 1
        guard upper >= 0 else { return false }
        let indices = [
            result.structureStartIndex,
            result.breakoutIndex,
            result.confirmationIndex
        ] + [result.resolveIndex].compactMap { $0 }
        return indices.allSatisfy { $0 >= 0 && $0 <= upper }
    }

    private var mtrResults: [MTRSetup.Result] {
        guard indicators.contains(.mtrStrategy) else { return [] }
        let all = derived.mtrSetup(candles: candles, config: indicatorConfig)
        guard !all.isEmpty,
              let bounds = ChartWindow.visibleBounds(domain: effectiveXDomain, count: candles.count)
        else { return [] }
        let margin = max(8, (bounds.hi - bounds.lo) / 4)
        return all.suffix(5).filter { result in
            mtrResultFitsCurrentCandles(result)
                && result.lastRelevantIndex >= bounds.lo - margin
                && result.channelStartIndex <= bounds.hi + margin
        }
    }

    private func mtrResultFitsCurrentCandles(_ result: MTRSetup.Result) -> Bool {
        let upper = candles.count - 1
        guard upper >= 0 else { return false }
        let required = [
            result.channelStartIndex,
            result.channelEndIndex,
            result.trendExtremeIndex,
            result.breakoutIndex,
            result.retestIndex,
            result.lastRelevantIndex
        ] + [result.confirmationIndex, result.resolveIndex].compactMap { $0 }
        return required.allSatisfy { $0 >= 0 && $0 <= upper }
    }

    private var volumeProfileSessions: [VolumeProfile.SessionVP] {
        guard indicators.contains(.volumeProfile), indicatorConfig.vpMode == "session" else { return [] }
        return derived.volumeProfile(
            candles: candles,
            bucketCount: indicatorConfig.vpBucketCount,
            valueAreaPct: indicatorConfig.vpValueAreaPct
        )
    }

    private var zigzagTrendVP: VolumeProfile.TrendVP? {
        guard indicators.contains(.volumeProfile), indicatorConfig.vpMode == "zigzag" else { return nil }
        return derived.zigzagVolumeProfile(
            candles: candles,
            bucketCount: indicatorConfig.vpBucketCount,
            valueAreaPct: indicatorConfig.vpValueAreaPct,
            zzDepth: indicatorConfig.vpZZDepth,
            zzMinChange: indicatorConfig.vpZZMinChange
        )
    }

    /// Visible-range Volume Profile: histogram of the bars currently in
    /// view plus ranked high-volume levels. Used in "visible" mode.
    private var visibleRangeVP: VolumeProfile.VisibleRangeVP? {
        guard indicators.contains(.volumeProfile), indicatorConfig.vpMode == "visible" else { return nil }
        let domain = effectiveXDomain
        let lo = max(0, Int(domain.lowerBound.rounded(.down)))
        let hi = min(candles.count - 1, Int(domain.upperBound.rounded(.up)))
        guard hi > lo else { return nil }
        return derived.visibleRangeVolumeProfile(
            candles: candles,
            barRange: lo...hi,
            bucketCount: indicatorConfig.vpBucketCount,
            valueAreaPct: indicatorConfig.vpValueAreaPct,
            levelCount: indicatorConfig.vpLevelCount
        )
    }

    private var zigzagPivots: [ZigZag.Pivot] {
        guard indicators.contains(.volumeProfile),
              indicatorConfig.vpMode == "zigzag",
              indicatorConfig.vpShowZigzag else { return [] }
        return derived.zigzagPivots(
            candles: candles,
            depth: indicatorConfig.vpZZDepth,
            minChange: indicatorConfig.vpZZMinChange
        )
    }

    private var chart: some View {
        Group {
            let indices = renderIndices
            // Range bounds for visible-index checks — avoids allocating
            // a Set<Int> on every frame (60-120×/sec during pan/zoom).
            let visLo = indices.first ?? 0
            let visHi = indices.last ?? 0

            Chart {
                if let last = displayCandles.last {
                    RuleMark(y: .value("Last", last.close))
                        .foregroundStyle(accent.opacity(0.45))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                        .annotation(position: .overlay, alignment: .trailing, spacing: 0) {
                            Text(Self.priceExact(last.close))
                                .font(.system(size: 10, weight: .bold).monospacedDigit())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(Capsule().fill(accent))
                        }
                }

                if replayActive, !displayCandles.isEmpty {
                    RuleMark(x: .value("Replay", Double(displayCandles.count - 1)))
                        .foregroundStyle(Theme.Color.warn.opacity(0.55))
                        .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [2, 3]))
                        .annotation(position: .top, alignment: .trailing, spacing: 0) {
                            Text("REPLAY")
                                .font(.system(size: 8, weight: .heavy))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 2)
                                .background(Capsule().fill(Theme.Color.warn))
                        }
                }

                sessionMarks
                volumeProfileMarks
                zigzagLineMarks
                setupMarks
                sp2lMarks
                pinBarComboMarks
                microMapMarks
                mtrMarks
                srLevelMarks
                fvgMarks
                indicatorFvgMarks
                supplyDemandMarks
                orderBlockMarks
                steroidOrderBlockMarks
                sonarlabOBMarks
                rankedOBMarks
                volumeFilteredOBMarks
                chochMarks
                htfChochMarks
                scenarioMarks
                tradeMarks
                journalMarks
                drawingMarks
                drawingPreviewMarks

                switch chartType {
                case .line:                  lineMarks(indices: indices)
                case .candle, .heikinAshi:   candleMarks(indices: indices)
                }

                indicatorMarks(visLo: visLo, visHi: visHi)
                utBotMarks(indices: indices, visLo: visLo, visHi: visHi)

                if let h = hovered, h.index < displayCandles.count {
                    let dc = displayCandles[h.index]
                    RuleMark(x: .value("Hover X", Double(h.index)))
                        .foregroundStyle(Color.white.opacity(0.18))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .annotation(position: .bottom, alignment: .center, spacing: 2) {
                            Text(Self.dateFormatter.string(from: h.candle.bucketStart))
                                .font(.system(size: 9, weight: .bold).monospacedDigit())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    RoundedRectangle(cornerRadius: 4)
                                        .fill(Theme.Color.surfaceMax)
                                )
                        }
                    RuleMark(y: .value("Hover Y", h.cursorPrice))
                        .foregroundStyle(Color.white.opacity(0.18))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                        .annotation(position: .overlay, alignment: .trailing, spacing: 0) {
                            Text(Self.priceExact(h.cursorPrice))
                                .font(.system(size: 10, weight: .bold).monospacedDigit())
                                .foregroundStyle(.white)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 3)
                                .background(
                                    Capsule().fill(Theme.Color.surfaceMax)
                                )
                        }
                    PointMark(
                        x: .value("Hover", Double(h.index)),
                        y: .value("Hover", dc.close)
                    )
                    .foregroundStyle(accent)
                    .symbolSize(70)
                }
            }
            .chartYScale(domain: effectiveYDomain)
            .chartXScale(domain: effectiveXDomain)
            .chartXAxis(content: xAxis)
            .chartYAxis(content: yAxis)
            .chartPlotStyle { plot in
                plot.background(
                    LinearGradient(
                        colors: [
                            Theme.Color.surface.opacity(0.0),
                            Theme.Color.surface.opacity(0.6),
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                )
            }
            .chartOverlay { proxy in
                GeometryReader { geo in
                    let plotFrame = geo[proxy.plotAreaFrame]
                    ZStack(alignment: .topLeading) {
                        Rectangle()
                            .fill(Color.clear)
                            .contentShape(Rectangle())
                            .onContinuousHover { phase in
                                switch phase {
                                case .active(let location):
                                    let x = location.x - plotFrame.origin.x
                                    let y = location.y - plotFrame.origin.y
                                    guard plotFrame.size.width > 0,
                                          x >= 0, x <= plotFrame.size.width,
                                          y >= 0, y <= plotFrame.size.height,
                                          let xValue: Double = proxy.value(atX: x)
                                    else { return }
                                    let idx = max(0, min(candles.count - 1, Int(xValue.rounded())))
                                    let yPrice: Double = proxy.value(atY: y) ?? candles[idx].close
                                    hovered = HoverState(
                                        candle: candles[idx],
                                        index: idx,
                                        cursor: location,
                                        cursorPrice: yPrice
                                    )
                                case .ended:
                                    hovered = nil
                                }
                            }
                            .simultaneousGesture(ipadDragGesture(
                                plotWidth: plotFrame.size.width,
                                plotHeight: plotFrame.size.height,
                                plotOrigin: plotFrame.origin,
                                proxy: proxy
                            ))
                            .simultaneousGesture(magnificationGesture())
                            .onTapGesture(count: 2) {
                                resetChart()
                            }
                            // Single-tap on a bottom-axis news flag opens
                            // its detail popover; a tap that misses every
                            // flag dismisses an open one. Runs alongside
                            // the double-tap-to-reset above.
                            .simultaneousGesture(
                                SpatialTapGesture(count: 1).onEnded { value in
                                    if let hit = newsHitTest(
                                        at: value.location,
                                        plotOrigin: plotFrame.origin,
                                        plotHeight: plotFrame.size.height,
                                        proxy: proxy
                                    ) {
                                        selectedNews = hit.event
                                        newsPopupAnchor = hit.anchor
                                    } else if selectedNews != nil {
                                        selectedNews = nil
                                    }
                                }
                            )

                        newsFlagsLayer(proxy: proxy, plotFrame: plotFrame)
                            .allowsHitTesting(false)

                        if let ev = selectedNews {
                            newsPopupLayer(event: ev, plotFrame: plotFrame)
                        }
                    }
                }
            }
        }
    }

    // MARK: - News layer (flags + popover)

    @ViewBuilder
    private func newsFlagsLayer(proxy: ChartProxy, plotFrame: CGRect) -> some View {
        ForEach(visibleNewsMarkers) { m in
            if let px = proxy.position(forX: m.barIndex) {
                NewsFlagView(color: m.color)
                    .position(x: plotFrame.origin.x + px, y: plotFrame.maxY - 9)
            }
        }
    }

    @ViewBuilder
    private func newsPopupLayer(event: ForexFactoryEvent, plotFrame: CGRect) -> some View {
        let cardWidth: CGFloat = 240
        let halfW = cardWidth / 2 + 6
        let clampedX = min(max(newsPopupAnchor.x, plotFrame.minX + halfW),
                           plotFrame.maxX - halfW)
        let clampedY = max(plotFrame.minY + 70, newsPopupAnchor.y - 84)
        NewsMarkerPopover(event: event, timeZone: newsTimeZone) {
            selectedNews = nil
        }
        .position(x: clampedX, y: clampedY)
    }

    /// Was a tap on a bottom-axis news flag? Returns the event + the
    /// flag's anchor (overlay coordinates). Only the bottom ~30px band
    /// is live (touch targets are bigger than the mouse's 26px).
    private func newsHitTest(
        at location: CGPoint,
        plotOrigin: CGPoint,
        plotHeight: CGFloat,
        proxy: ChartProxy
    ) -> (event: ForexFactoryEvent, anchor: CGPoint)? {
        guard location.y >= plotOrigin.y + plotHeight - 30 else { return nil }
        var best: (dist: CGFloat, event: ForexFactoryEvent, anchor: CGPoint)?
        for m in visibleNewsMarkers {
            guard let px = proxy.position(forX: m.barIndex) else { continue }
            let sx = plotOrigin.x + px
            let d = abs(location.x - sx)
            guard d <= 18 else { continue }
            if best == nil || d < best!.dist {
                best = (d, m.event, CGPoint(x: sx, y: plotOrigin.y + plotHeight - 9))
            }
        }
        guard let b = best else { return nil }
        return (b.event, b.anchor)
    }

    // MARK: - iPad drag (pan + draw)

    private enum AxisDragMode { case pan, scaleX, scaleY }

    /// One drag handler that dispatches to DRAW (a tool is armed), or in
    /// cursor mode to PAN / SCALE-X / SCALE-Y depending on where the drag
    /// began: the right price-axis gutter stretches the Y range, the
    /// bottom time-axis gutter stretches the X range (TradingView-style),
    /// and anywhere inside the plot pans. When a pinch is in flight
    /// (`magnifyStartDomain != nil`) this branch yields entirely so the
    /// two gestures don't fight over `xDomain`/`yDomain`. `minimumDistance`
    /// drops to 0 while drawing so a tap can commit a horizontal line.
    private func ipadDragGesture(
        plotWidth: CGFloat,
        plotHeight: CGFloat,
        plotOrigin: CGPoint,
        proxy: ChartProxy
    ) -> some Gesture {
        DragGesture(minimumDistance: activeTool == .none ? 5 : 0)
            .onChanged { value in
                // Drawing mode: capture endpoints for the live preview.
                if activeTool != .none {
                    if drawingStart == nil {
                        drawingStart = drawingPoint(at: value.startLocation, plotOrigin: plotOrigin, proxy: proxy)
                        hovered = nil
                    }
                    drawingEnd = drawingPoint(at: value.location, plotOrigin: plotOrigin, proxy: proxy)
                    return
                }

                // Pan / axis-scale mode — never while a pinch owns the domains.
                guard magnifyStartDomain == nil else { return }

                // Cursor mode: decide once, on the first frame, whether
                // this touch grabbed a handle, a drawing body, or the
                // chart itself. The choice sticks for the gesture so a
                // drag can't switch modes mid-flight.
                let alreadyChose =
                    editingDrawingID != nil ||
                    movingDrawingOriginal != nil ||
                    dragStartDomain != nil
                if !alreadyChose, !drawings.isEmpty {
                    if let sel = selectionTargetDrawing,
                       let anchor = hitTestHandle(
                            of: sel,
                            at: value.startLocation,
                            plotOrigin: plotOrigin,
                            proxy: proxy
                       ) {
                        editingDrawingID = sel.id
                        editingHandle = anchor
                        editingCursor = drawingPoint(at: value.startLocation, plotOrigin: plotOrigin, proxy: proxy)
                        hovered = nil
                    } else if let hit = hitTestDrawing(
                        at: value.startLocation,
                        plotOrigin: plotOrigin,
                        proxy: proxy
                    ) {
                        movingDrawingOriginal = hit
                        movingDeltaTime = 0
                        movingDeltaPrice = 0
                        hovered = nil
                    }
                }

                if editingDrawingID != nil {
                    editingCursor = drawingPoint(at: value.location, plotOrigin: plotOrigin, proxy: proxy)
                    dragHadMovement = true
                    return
                }
                if movingDrawingOriginal != nil {
                    if let s = drawingPoint(at: value.startLocation, plotOrigin: plotOrigin, proxy: proxy),
                       let n = drawingPoint(at: value.location, plotOrigin: plotOrigin, proxy: proxy) {
                        movingDeltaTime  = n.date.timeIntervalSince(s.date)
                        movingDeltaPrice = n.price - s.price
                        dragHadMovement = true
                    }
                    return
                }

                if dragStartDomain == nil {
                    dragStartDomain = effectiveXDomain
                    dragStartYDomain = effectiveYDomain
                    panLockedY = false
                    hovered = nil
                    dragHadMovement = false
                    // Lock in the mode from where the finger went down.
                    let sx = value.startLocation.x
                    let sy = value.startLocation.y
                    let inRightGutter  = plotWidth  > 0 && sx > plotOrigin.x + plotWidth
                    let inBottomGutter = plotHeight > 0 && sy > plotOrigin.y + plotHeight
                    if inBottomGutter {
                        axisDragMode = .scaleX
                    } else if inRightGutter {
                        axisDragMode = .scaleY
                    } else {
                        axisDragMode = .pan
                    }
                }

                switch axisDragMode {
                case .scaleY:
                    // Drag the price axis: up ⇒ zoom in (range shrinks),
                    // down ⇒ zoom out. Center held fixed.
                    guard let startY = dragStartYDomain else { return }
                    let center = (startY.lowerBound + startY.upperBound) / 2
                    let half   = (startY.upperBound - startY.lowerBound) / 2
                    let factor = exp(Double(value.translation.height) / 180)
                    let newHalf = max(half * factor, 0.0000001)
                    yDomain = (center - newHalf) ... (center + newHalf)

                case .scaleX:
                    // Drag the time axis: left ⇒ zoom in (fewer bars),
                    // right ⇒ zoom out. Center held fixed.
                    guard let startX = dragStartDomain else { return }
                    let center = (startX.lowerBound + startX.upperBound) / 2
                    let half   = (startX.upperBound - startX.lowerBound) / 2
                    let factor = exp(Double(value.translation.width) / 180)
                    let newHalf = max(half * factor, 1.5)
                    xDomain = (center - newHalf) ... (center + newHalf)

                case .pan:
                    let movedFar = abs(value.translation.width) > 3 || abs(value.translation.height) > 3
                    if movedFar { dragHadMovement = true }
                    guard dragHadMovement else { return }
                    guard let start = dragStartDomain, plotWidth > 0 else { return }

                    let span = start.upperBound - start.lowerBound
                    let unitsPerPoint = span / Double(plotWidth)
                    let deltaX = Double(value.translation.width) * unitsPerPoint

                    // Batch xDomain + yDomain into one update to avoid double recompute
                    let newXLower = start.lowerBound - deltaX
                    let newXUpper = start.upperBound - deltaX
                    xDomain = newXLower ... newXUpper

                    if !panLockedY, abs(value.translation.height) > 2 { panLockedY = true }
                    if panLockedY, let startY = dragStartYDomain, plotHeight > 0 {
                        let ySpan = startY.upperBound - startY.lowerBound
                        let pricePerPoint = ySpan / Double(plotHeight)
                        let shift = Double(value.translation.height) * pricePerPoint
                        yDomain = (startY.lowerBound + shift) ... (startY.upperBound + shift)
                    }
                }
            }
            .onEnded { value in
                let hadMovement = dragHadMovement
                dragHadMovement = false

                if activeTool != .none {
                    commitDrawing(value, plotOrigin: plotOrigin, proxy: proxy)
                    return
                }
                if editingDrawingID != nil {
                    handleResizeEnd()
                    return
                }
                if let moving = movingDrawingOriginal {
                    if hadMovement {
                        handleMoveEnd()
                    } else {
                        // A tap without movement means "select", not
                        // "move" — same rule as the Mac build.
                        onSelectDrawing?(moving.id)
                        movingDrawingOriginal = nil
                        movingDeltaTime = 0
                        movingDeltaPrice = 0
                    }
                    return
                }
                // Tap on empty chart clears the selection.
                if !hadMovement, selectedDrawingID != nil {
                    onSelectDrawing?(nil)
                }
                dragStartDomain = nil
                dragStartYDomain = nil
                panLockedY = false
                axisDragMode = .pan
            }
    }

    /// Resolve a touch location to a `(bar-date, price)` drawing point.
    /// The X axis is bar-indexed, so we round the proxy's X value to the
    /// nearest bar and store that bar's `bucketStart` (drawings persist by
    /// date; `barIndex(forDate:)` maps it back for rendering).
    private func drawingPoint(
        at location: CGPoint,
        plotOrigin: CGPoint,
        proxy: ChartProxy
    ) -> DrawingPoint? {
        guard !candles.isEmpty else { return nil }
        let xInPlot = location.x - plotOrigin.x
        let yInPlot = location.y - plotOrigin.y
        guard let barX: Double = proxy.value(atX: xInPlot),
              let priceY: Double = proxy.value(atY: yInPlot)
        else { return nil }
        // Past either end of the series, project the date off the bar
        // spacing instead of clamping — otherwise anything dragged into
        // the empty right margin pins onto the newest candle and a
        // drawing can never sit ahead of price.
        let lastIdx = candles.count - 1
        if let step = barIntervalSeconds {
            if barX > Double(lastIdx) {
                let ahead = barX - Double(lastIdx)
                return DrawingPoint(
                    date: candles[lastIdx].bucketStart.addingTimeInterval(ahead * step),
                    price: priceY
                )
            }
            if barX < 0 {
                return DrawingPoint(
                    date: candles[0].bucketStart.addingTimeInterval(barX * step),
                    price: priceY
                )
            }
        }
        let idx = max(0, min(lastIdx, Int(barX.rounded())))
        return DrawingPoint(date: candles[idx].bucketStart, price: priceY)
    }

    /// Seconds between consecutive bars, used to project dates past
    /// either end of the series. Median of the recent spacings so a
    /// trailing weekend/session gap doesn't fling right-margin
    /// drawings far into the future.
    private var barIntervalSeconds: TimeInterval? {
        let n = candles.count
        guard n >= 2 else { return nil }
        var diffs: [TimeInterval] = []
        diffs.reserveCapacity(min(n - 1, 20))
        for i in max(1, n - 20)..<n {
            let d = candles[i].bucketStart.timeIntervalSince(candles[i - 1].bucketStart)
            if d > 0 { diffs.append(d) }
        }
        guard !diffs.isEmpty else { return nil }
        diffs.sort()
        return diffs[diffs.count / 2]
    }

    /// Finalise the in-flight drawing and hand it to the dashboard.
    /// Two-point shapes require a real drag (~4pt) so a stray tap can't
    /// commit a zero-size rectangle; a horizontal line commits on tap.
    private func commitDrawing(
        _ value: DragGesture.Value,
        plotOrigin: CGPoint,
        proxy: ChartProxy
    ) {
        let startPoint = drawingStart ?? drawingPoint(at: value.startLocation, plotOrigin: plotOrigin, proxy: proxy)
        let endPoint   = drawingEnd   ?? drawingPoint(at: value.location,      plotOrigin: plotOrigin, proxy: proxy)
        drawingStart = nil
        drawingEnd = nil

        guard let start = startPoint else { return }
        let end = endPoint ?? start

        let dragDistSq = pow(value.translation.width, 2) + pow(value.translation.height, 2)
        let hasDrag = dragDistSq >= 16

        switch activeTool {
        case .none:
            return
        case .horizontalLine:
            onCommitDrawing?(ChartDrawing(kind: .horizontalLine, start: start, end: nil))
        case .trendLine:
            guard hasDrag else { return }
            onCommitDrawing?(ChartDrawing(kind: .trendLine, start: start, end: end))
        case .rectangle:
            guard hasDrag else { return }
            onCommitDrawing?(ChartDrawing(kind: .rectangle, start: start, end: end))
        case .volumeProfile:
            guard hasDrag else { return }
            onCommitDrawing?(ChartDrawing(kind: .volumeProfile, start: start, end: end))
        case .longPosition, .shortPosition:
            // Drag height sets the stop distance; a tap falls back to
            // 0.5% of price so the box is never zero-height (which
            // would divide by zero in the metrics).
            let dragged = abs(end.price - start.price)
            let stopDistance = dragged > 0 ? dragged : abs(start.price) * 0.005
            guard stopDistance > 0 else { return }
            let rightDate = end.date > start.date
                ? end.date
                : defaultPositionRightEdge(from: start.date)
            onCommitDrawing?(ChartDrawing.position(
                long: activeTool == .longPosition,
                entry: start,
                end: DrawingPoint(date: rightDate, price: start.price),
                stopDistance: stopDistance,
                balance: defaultPositionBalance,
                riskPercent: defaultPositionRisk
            ))
        }
    }

    /// Right edge for a position committed without a horizontal drag —
    /// far enough forward to be grabbable, clamped to the last candle.
    private func defaultPositionRightEdge(from start: Date) -> Date {
        guard let startIdx = barIndex(closestTo: start), !candles.isEmpty else { return start }
        let idx = min(candles.count - 1, startIdx + 20)
        return candles[idx].bucketStart
    }

    /// Seeded from the Risk Calculator's stored settings so a new
    /// position starts with the user's usual sizing; each position
    /// keeps its own copy afterwards.
    private var defaultPositionBalance: Double {
        let stored = UserDefaults.standard.double(forKey: "riskcalc.accountBalance")
        return stored > 0 ? stored : 10_000
    }

    private var defaultPositionRisk: Double {
        let stored = UserDefaults.standard.double(forKey: "riskcalc.riskPercent")
        return stored > 0 ? stored : 1.0
    }

    // MARK: - Pinch-to-zoom (throttled)

    private func magnificationGesture() -> some Gesture {
        MagnificationGesture(minimumScaleDelta: 0.02)
            .onChanged { value in
                if magnifyStartDomain == nil {
                    magnifyStartDomain = effectiveXDomain
                    magnifyStartYDomain = effectiveYDomain
                    hovered = nil
                }
                // X-axis zoom (horizontal pinch)
                if let start = magnifyStartDomain {
                    let center = (start.lowerBound + start.upperBound) / 2
                    let halfSpan = (start.upperBound - start.lowerBound) / 2
                    let scale = max(0.1, min(20, Double(value)))
                    let zoomedHalf = halfSpan / scale
                    xDomain = (center - zoomedHalf) ... (center + zoomedHalf)
                }
                // Y-axis zoom (vertical component of pinch)
                if let startY = magnifyStartYDomain {
                    let yCenter = (startY.lowerBound + startY.upperBound) / 2
                    let yHalfSpan = (startY.upperBound - startY.lowerBound) / 2
                    let yScale = max(0.1, min(20, Double(value)))
                    let yZoomedHalf = yHalfSpan / yScale
                    yDomain = (yCenter - yZoomedHalf) ... (yCenter + yZoomedHalf)
                }
            }
            .onEnded { _ in
                magnifyStartDomain = nil
                magnifyStartYDomain = nil
            }
    }

    // MARK: - Effective domains

    private var effectiveXDomain: ClosedRange<Double> {
        if let d = xDomain { return d }
        return ChartWindow.defaultDomain(count: candles.count)
    }

    /// Reset to the default recent-bars window with the price scale
    /// framed to the *candles* (not indicators/overlays), matching the
    /// Mac chart's Reset. Pins an explicit Y so the double-tap doesn't
    /// hand the axis back to the overlay-inclusive auto-fit.
    private func resetChart() {
        guard candles.count > 0 else { xDomain = nil; yDomain = nil; return }
        let domain = ChartWindow.defaultDomain(count: candles.count)
        yDomain = ChartWindow.candleYDomain(candles: candles, domain: domain)
        xDomain = domain
    }

    private var renderIndices: [Int] {
        ChartWindow.renderIndices(domain: effectiveXDomain, count: candles.count)
    }

    /// News events resolved to bar indices and clipped to the visible
    /// window (see `ChartView.visibleNewsMarkers` for the rationale).
    private var visibleNewsMarkers: [NewsChartMarker] {
        guard !newsEvents.isEmpty, candles.count > 1 else { return [] }
        let firstTs = candles.first!.bucketStart.timeIntervalSince1970
        let barSpan = candles[candles.count - 1].bucketStart
            .timeIntervalSince(candles[candles.count - 2].bucketStart)
        let lastTs = candles.last!.bucketStart.timeIntervalSince1970 + max(barSpan, 1)
        let domain = effectiveXDomain
        var markers: [NewsChartMarker] = []
        for ev in newsEvents {
            guard let at = ev.eventAt else { continue }
            let ts = at.timeIntervalSince1970
            guard ts >= firstTs, ts <= lastTs else { continue }
            guard let bx = barIndex(forDate: at) else { continue }
            guard bx >= domain.lowerBound - 1, bx <= domain.upperBound + 1 else { continue }
            markers.append(NewsChartMarker(id: ev.id, barIndex: bx, event: ev))
        }
        return markers
    }

    // MARK: - Line marks

    @ChartContentBuilder
    private func lineMarks(indices: [Int]) -> some ChartContent {
        let cs = displayCandles
        ForEach(indices, id: \.self) { i in
            let c = cs[i]
            AreaMark(
                x: .value("Bar", Double(i)),
                y: .value("Close", c.close)
            )
            .foregroundStyle(LinearGradient(
                colors: [accent.opacity(0.4), accent.opacity(0)],
                startPoint: .top, endPoint: .bottom
            ))
            .interpolationMethod(.monotone)

            LineMark(
                x: .value("Bar", Double(i)),
                y: .value("Close", c.close)
            )
            .foregroundStyle(accent)
            .lineStyle(StrokeStyle(lineWidth: 1.8, lineJoin: .round))
            .interpolationMethod(.monotone)
        }
        if cs.count == 1, let only = cs.first {
            PointMark(
                x: .value("Bar", 0.0),
                y: .value("Close", only.close)
            )
            .foregroundStyle(accent)
            .symbolSize(120)
        }
    }

    // MARK: - S/R levels

    @ChartContentBuilder
    private var srLevelMarks: some ChartContent {
        ForEach(srLevels.support, id: \.self) { level in
            RuleMark(y: .value("Support", level))
                .foregroundStyle(Theme.Color.success.opacity(0.55))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [6, 4]))
                .annotation(position: .overlay, alignment: .trailing, spacing: 0) {
                    srTag(price: level, isSupport: true)
                }
        }
        ForEach(srLevels.resistance, id: \.self) { level in
            RuleMark(y: .value("Resistance", level))
                .foregroundStyle(Theme.Color.danger.opacity(0.55))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [6, 4]))
                .annotation(position: .overlay, alignment: .trailing, spacing: 0) {
                    srTag(price: level, isSupport: false)
                }
        }
    }

    private func srTag(price: Double, isSupport: Bool) -> some View {
        HStack(spacing: 3) {
            Text(isSupport ? "S" : "R")
                .font(.system(size: 8, weight: .bold))
            Text(Self.priceShort(price))
                .font(.system(size: 9, weight: .bold).monospacedDigit())
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(
            Capsule().fill(isSupport ? Theme.Color.success : Theme.Color.danger)
        )
    }

    // MARK: - FVG marks

    @ChartContentBuilder
    private var fvgMarks: some ChartContent {
        let lastIndex = candles.count - 1
        ForEach(fvgZones) { zone in
            let xStart = Double(lastIndex + zone.barOffsetStart)
            let xEnd   = Double(lastIndex + zone.barOffsetEnd)
            RectangleMark(
                xStart: .value("FVG start", xStart),
                xEnd:   .value("FVG end",   xEnd),
                yStart: .value("Zone low",  zone.low),
                yEnd:   .value("Zone high", zone.high)
            )
            .foregroundStyle((zone.isBullish ? Theme.Color.success : Theme.Color.danger)
                              .opacity(zone.isMitigated ? 0.10 : 0.18))
            if zone.isMitigated {
                RuleMark(
                    xStart: .value("iFVG start hi", xStart),
                    xEnd:   .value("iFVG end hi",   xEnd),
                    y:      .value("iFVG hi",       zone.high)
                )
                .foregroundStyle((zone.isBullish ? Theme.Color.success : Theme.Color.danger).opacity(0.7))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                RuleMark(
                    xStart: .value("iFVG start lo", xStart),
                    xEnd:   .value("iFVG end lo",   xEnd),
                    y:      .value("iFVG lo",       zone.low)
                )
                .foregroundStyle((zone.isBullish ? Theme.Color.success : Theme.Color.danger).opacity(0.7))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }
        }
    }

    // MARK: - Indicator FVG marks

    @ChartContentBuilder
    private var indicatorFvgMarks: some ChartContent {
        let lastIndex = candles.count - 1
        ForEach(indicatorFvgZones) { zone in
            let color: Color = zone.isBullish ? Theme.Color.success : Theme.Color.danger
            let xStart = Double(zone.index)
            let xEnd   = Double(lastIndex)
            RectangleMark(
                xStart: .value("FVG start", xStart),
                xEnd:   .value("FVG end",   xEnd),
                yStart: .value("FVG low",   zone.low),
                yEnd:   .value("FVG high",  zone.high)
            )
            .foregroundStyle(color.opacity(zone.isMitigated ? 0.08 : 0.16))

            RuleMark(
                xStart: .value("FVG hi start", xStart),
                xEnd:   .value("FVG hi end",   xEnd),
                y:      .value("FVG hi",        zone.high)
            )
            .foregroundStyle(color.opacity(zone.isMitigated ? 0.35 : 0.65))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: zone.isMitigated ? [4, 3] : []))

            RuleMark(
                xStart: .value("FVG lo start", xStart),
                xEnd:   .value("FVG lo end",   xEnd),
                y:      .value("FVG lo",        zone.low)
            )
            .foregroundStyle(color.opacity(zone.isMitigated ? 0.35 : 0.65))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: zone.isMitigated ? [4, 3] : []))

            RuleMark(
                xStart: .value("FVG mid start", xStart),
                xEnd:   .value("FVG mid end",   xEnd),
                y:      .value("FVG mid",        zone.mid)
            )
            .foregroundStyle(color.opacity(0.35))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))

            PointMark(
                x: .value("FVG label", xEnd),
                y: .value("FVG hi",    zone.high)
            )
            .symbolSize(0)
            .annotation(position: .overlay, alignment: .trailing, spacing: 0) {
                Text(zone.isBullish ? "FVG↑" : "FVG↓")
                    .font(.system(size: 8, weight: .heavy))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(color.opacity(zone.isMitigated ? 0.55 : 0.95)))
            }
        }
    }

    // MARK: - Supply & Demand marks

    @ChartContentBuilder
    private var supplyDemandMarks: some ChartContent {
        let lastIndex = candles.count - 1
        ForEach(supplyDemandZones) { zone in
            let xStart = Double(lastIndex + zone.barOffsetStart)
            let xEnd   = Double(lastIndex + zone.barOffsetEnd)
            let baseColor: Color = zone.isDemand ? Theme.Color.success : Theme.Color.danger
            let fillOpacity: Double = {
                if !zone.isFresh { return 0.10 }
                switch zone.strength {
                case .weak:   return 0.14
                case .medium: return 0.20
                case .strong: return 0.28
                }
            }()
            RectangleMark(
                xStart: .value("Zone start", xStart),
                xEnd:   .value("Zone end",   xEnd),
                yStart: .value("Zone low",   zone.low),
                yEnd:   .value("Zone high",  zone.high)
            )
            .foregroundStyle(baseColor.opacity(fillOpacity))

            let lineWidth: CGFloat = {
                switch zone.strength {
                case .weak:   return 0.8
                case .medium: return 1.2
                case .strong: return 1.8
                }
            }()
            let dashStyle: [CGFloat] = zone.isFresh ? [] : [4, 3]
            RuleMark(
                xStart: .value("Zone start hi", xStart),
                xEnd:   .value("Zone end hi",   xEnd),
                y:      .value("Zone hi",       zone.high)
            )
            .foregroundStyle(baseColor.opacity(zone.isFresh ? 0.75 : 0.5))
            .lineStyle(StrokeStyle(lineWidth: lineWidth, dash: dashStyle))
            RuleMark(
                xStart: .value("Zone start lo", xStart),
                xEnd:   .value("Zone end lo",   xEnd),
                y:      .value("Zone lo",       zone.low)
            )
            .foregroundStyle(baseColor.opacity(zone.isFresh ? 0.75 : 0.5))
            .lineStyle(StrokeStyle(lineWidth: lineWidth, dash: dashStyle))

            PointMark(
                x: .value("Zone end label", xEnd),
                y: .value("Zone hi",        zone.high)
            )
            .symbolSize(0)
            .annotation(position: .overlay, alignment: .trailing, spacing: 0) {
                Text("\(zone.isDemand ? "D" : "S")·\(zone.strength.rawValue.prefix(1).uppercased())")
                    .font(.system(size: 8, weight: .heavy).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(
                        Capsule().fill(baseColor.opacity(zone.isFresh ? 0.95 : 0.6))
                    )
            }
        }
    }

    // MARK: - Trading session marks

    @ChartContentBuilder
    private var sessionMarks: some ChartContent {
        let cfg = indicatorConfig
        let lineEnd = Double(max(candles.count - 1, 0))
        ForEach(sessionRuns) { run in
            let xStart = Double(run.start)
            let xEnd   = Double(run.end)

            RectangleMark(
                xStart: .value("Session start", xStart),
                xEnd:   .value("Session end",   xEnd),
                yStart: .value("Session low",   run.low),
                yEnd:   .value("Session high",  run.high)
            )
            .foregroundStyle(run.color.opacity(0.12))

            RuleMark(
                xStart: .value("Sess high start", xStart),
                xEnd:   .value("Sess high end",   lineEnd),
                y:      .value("Sess high",       run.high)
            )
            .foregroundStyle(run.color.opacity(0.7))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [1, 3]))
            RuleMark(
                xStart: .value("Sess low start", xStart),
                xEnd:   .value("Sess low end",   lineEnd),
                y:      .value("Sess low",        run.low)
            )
            .foregroundStyle(run.color.opacity(0.7))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [1, 3]))

            if cfg.sessShowOpenClose {
                RuleMark(
                    xStart: .value("Sess open start", xStart),
                    xEnd:   .value("Sess open end",   xEnd),
                    y:      .value("Sess open",       run.open)
                )
                .foregroundStyle(run.color.opacity(0.85))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
                RuleMark(
                    xStart: .value("Sess close start", xStart),
                    xEnd:   .value("Sess close end",   xEnd),
                    y:      .value("Sess close",       run.close)
                )
                .foregroundStyle(run.color.opacity(0.85))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))
            }

            if cfg.sessShowAverage {
                RuleMark(
                    xStart: .value("Sess avg start", xStart),
                    xEnd:   .value("Sess avg end",   lineEnd),
                    y:      .value("Sess avg",       run.average)
                )
                .foregroundStyle(run.color.opacity(0.6))
                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [1, 3]))
            }

            if let text = sessionLabelText(run) {
                PointMark(
                    x: .value("Sess label x", xStart),
                    y: .value("Sess label y", run.low)
                )
                .symbolSize(0)
                .annotation(position: .bottom, alignment: .leading, spacing: 1) {
                    Text(text)
                        .font(.system(size: 8, weight: .bold).monospacedDigit())
                        .foregroundStyle(run.color)
                        .multilineTextAlignment(.leading)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(
                            RoundedRectangle(cornerRadius: 3)
                                .fill(Theme.Color.surfaceMax.opacity(0.7))
                        )
                        .fixedSize()
                }
            }
        }
    }

    private func sessionLabelText(_ run: TradingSessions.SessionRun) -> String? {
        var lines: [String] = []
        if indicatorConfig.sessShowRange   { lines.append("Rng \(Self.priceShort(run.range))") }
        if indicatorConfig.sessShowAverage { lines.append("Avg \(Self.priceShort(run.average))") }
        if indicatorConfig.sessShowNames   { lines.append(run.name) }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    // MARK: - Volume Profile marks

    /// Three modes, switched by `indicatorConfig.vpMode`: "session"
    /// (per-trading-day histograms), "zigzag" (last trend segment,
    /// right margin) and "visible" (visible window + ranked levels).
    @ChartContentBuilder
    private var volumeProfileMarks: some ChartContent {
        switch indicatorConfig.vpMode {
        case "session": sessionVPMarks
        case "visible": visibleRangeVPMarks
        default:        zigzagVPMarks
        }
    }

    /// Right-margin geometry for the margin-anchored modes: the
    /// histogram hugs the visible right edge so it stays on screen
    /// while panning.
    private var vpMargin: (rightEdge: Double, width: Double) {
        let domain = effectiveXDomain
        let width = max(6, min(24, (domain.upperBound - domain.lowerBound) * 0.18))
        return (domain.upperBound, width)
    }

    /// Two-tone histogram bars (up-volume success-tinted, down-volume
    /// danger-tinted), right-anchored; buckets outside the value area
    /// are dimmed, the POC row emphasised. POC/VA membership comes from
    /// the precomputed indices.
    @ChartContentBuilder
    private func vpHistogramMarks(
        buckets: [VolumeProfile.Bucket],
        bucketSize: Double,
        pocIndex: Int,
        vaLowIndex: Int,
        vaHighIndex: Int,
        rightEdge: Double,
        maxWidth: Double,
        tag: String
    ) -> some ChartContent {
        let maxVol = buckets.map(\.volume).max() ?? 1
        ForEach(Array(buckets.enumerated()), id: \.offset) { idx, bucket in
            let totalW = maxWidth * (bucket.volume / maxVol)
            let upW = maxWidth * (bucket.upVolume / maxVol)
            let inVA = idx >= vaLowIndex && idx <= vaHighIndex
            let opacity: Double = idx == pocIndex ? 0.85 : (inVA ? 0.55 : 0.25)
            RectangleMark(
                xStart: .value("\(tag) d0", rightEdge - totalW),
                xEnd:   .value("\(tag) d1", rightEdge - upW),
                yStart: .value("\(tag) dy0", bucket.priceLevel),
                yEnd:   .value("\(tag) dy1", bucket.priceLevel + bucketSize * 0.92)
            )
            .foregroundStyle(Theme.Color.danger.opacity(opacity))
            RectangleMark(
                xStart: .value("\(tag) u0", rightEdge - upW),
                xEnd:   .value("\(tag) u1", rightEdge),
                yStart: .value("\(tag) uy0", bucket.priceLevel),
                yEnd:   .value("\(tag) uy1", bucket.priceLevel + bucketSize * 0.92)
            )
            .foregroundStyle(Theme.Color.success.opacity(opacity))
        }
    }

    /// "No volume data" note — the profile is time-at-price, not true
    /// volume, when every candle lacked volume.
    @ChartContentBuilder
    private func vpTPONote(x: Double, y: Double) -> some ChartContent {
        PointMark(x: .value("VP TPO x", x), y: .value("VP TPO y", y))
            .symbolSize(0)
            .annotation(position: .top, alignment: .trailing, spacing: 2) {
                Text("TPO · no volume data")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(Theme.Color.textMuted)
            }
    }

    @ChartContentBuilder
    private var visibleRangeVPMarks: some ChartContent {
        if let vp = visibleRangeVP {
            let margin = vpMargin

            vpHistogramMarks(
                buckets: vp.buckets,
                bucketSize: vp.bucketSize,
                pocIndex: vp.pocIndex,
                vaLowIndex: vp.vaLowIndex,
                vaHighIndex: vp.vaHighIndex,
                rightEdge: margin.rightEdge,
                maxWidth: margin.width,
                tag: "VRVP"
            )

            ForEach(vp.levels, id: \.price) { level in
                RuleMark(
                    xStart: .value("VR L x0", Double(vp.startBar)),
                    xEnd:   .value("VR L x1", Double(vp.endBar)),
                    y:      .value("VR L y", level.price)
                )
                .foregroundStyle(
                    level.isPOC
                        ? Color(red: 0.96, green: 0.36, blue: 0.36).opacity(0.9)
                        : Theme.Color.info.opacity(0.25 + 0.55 * level.strength)
                )
                .lineStyle(StrokeStyle(
                    lineWidth: level.isPOC ? 2 : 1 + level.strength,
                    dash: level.isPOC ? [] : [6, 3]
                ))
                .annotation(position: .top, alignment: .trailing, spacing: 0) {
                    Text(Self.priceExact(level.price))
                        .font(.system(size: 8, weight: .medium))
                        .foregroundStyle(
                            level.isPOC ? Color(red: 0.96, green: 0.36, blue: 0.36) : Theme.Color.textMuted
                        )
                        .padding(.horizontal, 3)
                        .background(
                            Theme.Color.surfaceMax.opacity(0.85),
                            in: RoundedRectangle(cornerRadius: 3)
                        )
                }
            }

            if !vp.hasRealVolume {
                vpTPONote(x: margin.rightEdge, y: vp.vah)
            }
        }
    }

    @ChartContentBuilder
    private var zigzagVPMarks: some ChartContent {
        if let vp = zigzagTrendVP {
            let margin = vpMargin
            let lastBar = Double(candles.count - 1)

            vpHistogramMarks(
                buckets: vp.buckets,
                bucketSize: vp.bucketSize,
                pocIndex: vp.pocIndex,
                vaLowIndex: vp.vaLowIndex,
                vaHighIndex: vp.vaHighIndex,
                rightEdge: margin.rightEdge,
                maxWidth: margin.width,
                tag: "ZVP"
            )

            // POC — developing ray to the visible right edge.
            RuleMark(
                xStart: .value("ZVP POC x0", Double(vp.startBar)),
                xEnd:   .value("ZVP POC x1", margin.rightEdge),
                y:      .value("ZVP POC", vp.poc)
            )
            .foregroundStyle(Color(red: 0.96, green: 0.36, blue: 0.36))
            .lineStyle(StrokeStyle(lineWidth: 1.5))

            // VAH / VAL — scoped to the trend segment.
            RuleMark(
                xStart: .value("ZVP VAH x0", Double(vp.startBar)),
                xEnd:   .value("ZVP VAH x1", lastBar),
                y:      .value("ZVP VAH", vp.vah)
            )
            .foregroundStyle(Theme.Color.info.opacity(0.7))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))

            RuleMark(
                xStart: .value("ZVP VAL x0", Double(vp.startBar)),
                xEnd:   .value("ZVP VAL x1", lastBar),
                y:      .value("ZVP VAL", vp.val)
            )
            .foregroundStyle(Theme.Color.info.opacity(0.7))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))

            if !vp.hasRealVolume {
                vpTPONote(x: margin.rightEdge, y: vp.vah)
            }
        }
    }

    @ChartContentBuilder
    private var sessionVPMarks: some ChartContent {
        let sessions = volumeProfileSessions
        let lastBar = Double(candles.count - 1)
        ForEach(sessions) { session in
            let sessionWidth = Double(session.endBar - session.startBar)
            let maxBarWidth = max(2, sessionWidth * 0.25)
            let rightEdge = Double(session.endBar)
            let isLatest = session.id == sessions.last?.id
            let lineEnd = isLatest ? lastBar + 8 : rightEdge

            vpHistogramMarks(
                buckets: session.buckets,
                bucketSize: session.bucketSize,
                pocIndex: session.pocIndex,
                vaLowIndex: session.vaLowIndex,
                vaHighIndex: session.vaHighIndex,
                rightEdge: rightEdge,
                maxWidth: maxBarWidth,
                tag: "VP\(session.id)"
            )

            // POC / VAH / VAL — scoped to the session's bar range; the
            // latest session's levels project a few bars forward.
            RuleMark(
                xStart: .value("VP POC x0", Double(session.startBar)),
                xEnd:   .value("VP POC x1", lineEnd),
                y:      .value("VP POC", session.poc)
            )
            .foregroundStyle(Color(red: 0.96, green: 0.36, blue: 0.36))
            .lineStyle(StrokeStyle(lineWidth: 1.5))

            RuleMark(
                xStart: .value("VP VAH x0", Double(session.startBar)),
                xEnd:   .value("VP VAH x1", lineEnd),
                y:      .value("VP VAH", session.vah)
            )
            .foregroundStyle(Theme.Color.info.opacity(0.7))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))

            RuleMark(
                xStart: .value("VP VAL x0", Double(session.startBar)),
                xEnd:   .value("VP VAL x1", lineEnd),
                y:      .value("VP VAL", session.val)
            )
            .foregroundStyle(Theme.Color.info.opacity(0.7))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3]))

            if session.startBar > 0 {
                RuleMark(x: .value("VP sep", Double(session.startBar) - 0.5))
                    .foregroundStyle(Theme.Color.textMuted.opacity(0.15))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 4]))
            }
        }
        if let latest = sessions.last, !latest.hasRealVolume {
            vpTPONote(x: Double(latest.endBar), y: latest.vah)
        }
    }

    @ChartContentBuilder
    private var zigzagLineMarks: some ChartContent {
        let pivots = zigzagPivots
        if pivots.count >= 2 {
            ForEach(0..<(pivots.count - 1), id: \.self) { i in
                let p0 = pivots[i]
                let p1 = pivots[i + 1]
                let color = p1.isHigh
                    ? Color(red: 0.96, green: 0.36, blue: 0.36)
                    : Color(red: 0.30, green: 0.80, blue: 0.40)
                LineMark(
                    x: .value("ZZ x0", Double(p0.barIndex)),
                    y: .value("ZZ y0", p0.price),
                    series: .value("ZZ", i)
                )
                .foregroundStyle(color.opacity(0.7))
                .lineStyle(StrokeStyle(lineWidth: 1.5))
                LineMark(
                    x: .value("ZZ x1", Double(p1.barIndex)),
                    y: .value("ZZ y1", p1.price),
                    series: .value("ZZ", i)
                )
                .foregroundStyle(color.opacity(0.7))
                .lineStyle(StrokeStyle(lineWidth: 1.5))
            }
            ForEach(pivots) { pivot in
                let color = pivot.isHigh
                    ? Color(red: 0.96, green: 0.36, blue: 0.36)
                    : Color(red: 0.30, green: 0.80, blue: 0.40)
                PointMark(
                    x: .value("ZZ dot x", Double(pivot.barIndex)),
                    y: .value("ZZ dot y", pivot.price)
                )
                .foregroundStyle(color)
                .symbolSize(18)
            }
        }
    }

    // MARK: - NY Open Setup marks

    @ChartContentBuilder
    private var setupMarks: some ChartContent {
        let lastIndex = candles.count - 1
        ForEach(nySetupResults) { r in
            let dirColor = setupDirectionColor(r.direction)
            let orStart = Double(r.orStartIndex)
            let orEnd   = Double(r.orEndIndex)
            let rayEnd  = Double(r.resolveIndex ?? lastIndex)

            RectangleMark(
                xStart: .value("OR start", orStart),
                xEnd:   .value("OR end",   orEnd),
                yStart: .value("OR low",   r.orLow),
                yEnd:   .value("OR high",  r.orHigh)
            )
            .foregroundStyle(dirColor.opacity(0.14))

            RuleMark(xStart: .value("ORH s", orStart), xEnd: .value("ORH e", rayEnd),
                     y: .value("OR high", r.orHigh))
            .foregroundStyle(dirColor.opacity(0.55))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
            RuleMark(xStart: .value("ORL s", orStart), xEnd: .value("ORL e", rayEnd),
                     y: .value("OR low", r.orLow))
            .foregroundStyle(dirColor.opacity(0.55))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))

            PointMark(x: .value("NY High x", orStart), y: .value("NY High y", r.orHigh))
                .symbolSize(0)
                .annotation(position: .top, alignment: .leading, spacing: 1) {
                    setupTag("NY High", color: dirColor)
                }
            PointMark(x: .value("NY Low x", orStart), y: .value("NY Low y", r.orLow))
                .symbolSize(0)
                .annotation(position: .bottom, alignment: .leading, spacing: 1) {
                    setupTag("NY Low", color: dirColor)
                }

            if r.hasPlan,
               let fvgS = r.fvgStartIndex, let fvgE = r.fvgEndIndex,
               let fLo = r.fvgLow, let fHi = r.fvgHigh,
               let entry = r.entry, let sl = r.stopLoss, let tp = r.takeProfit {
                let planStart = Double(fvgE)
                let planEnd   = Double(r.resolveIndex ?? lastIndex)

                RectangleMark(
                    xStart: .value("FVG s", Double(fvgS)),
                    xEnd:   .value("FVG e", Double(fvgE)),
                    yStart: .value("FVG lo", fLo),
                    yEnd:   .value("FVG hi", fHi)
                )
                .foregroundStyle(dirColor.opacity(0.22))

                RuleMark(xStart: .value("E s", planStart), xEnd: .value("E e", planEnd),
                         y: .value("Entry", entry))
                .foregroundStyle(dirColor.opacity(0.9))
                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 3]))
                RuleMark(xStart: .value("SL s", planStart), xEnd: .value("SL e", planEnd),
                         y: .value("SL", sl))
                .foregroundStyle(Theme.Color.danger.opacity(0.9))
                .lineStyle(StrokeStyle(lineWidth: 1.5))
                RuleMark(xStart: .value("TP s", planStart), xEnd: .value("TP e", planEnd),
                         y: .value("TP", tp))
                .foregroundStyle(Theme.Color.success.opacity(0.9))
                .lineStyle(StrokeStyle(lineWidth: 1.5))

                PointMark(x: .value("Entry lbl x", planEnd), y: .value("Entry lbl y", entry))
                    .symbolSize(0)
                    .annotation(position: .overlay, alignment: .trailing, spacing: 0) {
                        setupTag("Entry \(r.direction == .long ? "↑" : "↓")", color: dirColor)
                    }
                PointMark(x: .value("SL lbl x", planEnd), y: .value("SL lbl y", sl))
                    .symbolSize(0)
                    .annotation(position: .overlay, alignment: .trailing, spacing: 0) {
                        setupTag("SL", color: Theme.Color.danger)
                    }
                PointMark(x: .value("TP lbl x", planEnd), y: .value("TP lbl y", tp))
                    .symbolSize(0)
                    .annotation(position: .overlay, alignment: .trailing, spacing: 0) {
                        setupTag("TP", color: Theme.Color.success)
                    }

                if let rt = r.retestIndex {
                    PointMark(x: .value("retest x", Double(rt)), y: .value("retest y", entry))
                        .symbolSize(40)
                        .foregroundStyle(dirColor)
                }
            }
        }
    }

    private func setupDirectionColor(_ dir: NYOpenSetup.Direction?) -> Color {
        switch dir {
        case .long:  return Theme.Color.success
        case .short: return Theme.Color.danger
        case nil:    return Theme.Color.warn
        }
    }

    // MARK: - SP2L marks

    @ChartContentBuilder
    private var sp2lMarks: some ChartContent {
        let lastIndex = candles.count - 1
        ForEach(sp2lResults) { result in
            let color = sp2lDirectionColor(result.direction)
            let spikeStart = Double(result.spikeStartIndex)
            let spikeEnd = Double(result.spikeEndIndex)
            let planEnd = Double(result.resolveIndex ?? lastIndex)
            let targets = result.takeProfits(count: indicatorConfig.sp2lTargetCount)

            RuleMark(
                xStart: .value("SP2L level start", Double(result.levelStartIndex)),
                xEnd: .value("SP2L level end", Double(result.followThroughIndex)),
                y: .value("SP2L broken level", result.brokenLevel)
            )
            .foregroundStyle(color.opacity(0.85))
            .lineStyle(StrokeStyle(lineWidth: 1.4, dash: [5, 3]))

            RectangleMark(
                xStart: .value("SP2L spike start", spikeStart),
                xEnd: .value("SP2L spike end", spikeEnd),
                yStart: .value("SP2L spike low", result.spikeLow),
                yEnd: .value("SP2L spike high", result.spikeHigh)
            )
            .foregroundStyle(color.opacity(0.10))

            PointMark(x: .value("SP2L title x", spikeStart),
                      y: .value("SP2L title y", result.spikeHigh))
                .symbolSize(0)
                .annotation(position: .top, alignment: .leading, spacing: 1) {
                    setupTag(result.direction == .long ? "SP2L LONG" : "SP2L SHORT", color: color)
                }

            if let ema = result.emaValue {
                RuleMark(
                    xStart: .value("SP2L EMA start", spikeStart),
                    xEnd: .value("SP2L EMA end", spikeEnd),
                    y: .value("SP2L EMA", ema)
                )
                .foregroundStyle(Theme.Color.warn.opacity(0.75))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
            }

            RuleMark(xStart: .value("SP2L entry start", spikeEnd),
                     xEnd: .value("SP2L entry end", planEnd),
                     y: .value("SP2L entry", result.entry))
                .foregroundStyle(color.opacity(result.entryIndex == nil ? 0.55 : 0.9))
                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: result.entryIndex == nil ? [2, 4] : [5, 3]))
            RuleMark(xStart: .value("SP2L SL start", spikeEnd),
                     xEnd: .value("SP2L SL end", planEnd),
                     y: .value("SP2L SL", result.stopLoss))
                .foregroundStyle(Theme.Color.danger.opacity(0.9))
                .lineStyle(StrokeStyle(lineWidth: 1.4))
            ForEach(Array(targets.enumerated()), id: \.offset) { offset, target in
                RuleMark(xStart: .value("SP2L TP\(offset + 1) start", spikeEnd),
                         xEnd: .value("SP2L TP\(offset + 1) end", planEnd),
                         y: .value("SP2L TP\(offset + 1)", target))
                    .foregroundStyle(Theme.Color.success.opacity(0.9 - Double(offset) * 0.12))
                    .lineStyle(StrokeStyle(lineWidth: 1.4, dash: offset == 0 ? [] : [5, 3]))
            }

            if result.stage == .limitPending {
                PointMark(x: .value("SP2L pending label x", planEnd),
                          y: .value("SP2L pending label y", result.entry))
                    .symbolSize(0)
                    .annotation(position: .overlay, alignment: .trailing, spacing: 0) {
                        setupTag("Limit pending", color: color)
                    }
            }
            PointMark(x: .value("SP2L SL label x", planEnd),
                      y: .value("SP2L SL label y", result.stopLoss))
                .symbolSize(0)
                .annotation(position: .overlay, alignment: .trailing, spacing: 0) {
                    setupTag("SL", color: Theme.Color.danger)
                }
            ForEach(Array(targets.enumerated()), id: \.offset) { offset, target in
                PointMark(x: .value("SP2L TP\(offset + 1) label x", planEnd),
                          y: .value("SP2L TP\(offset + 1) label y", target))
                    .symbolSize(0)
                    .annotation(position: .overlay, alignment: .trailing, spacing: 0) {
                        let ratio = indicatorConfig.sp2lRiskReward * Double(offset + 1)
                        setupTag(
                            "TP\(offset + 1) R\(String(format: "%.2g", ratio))",
                            color: Theme.Color.success
                        )
                    }
            }
        }
    }

    private func sp2lDirectionColor(_ direction: SP2LSetup.Direction) -> Color {
        direction == .long ? Theme.Color.success : Theme.Color.danger
    }

    // MARK: - MicroMap marks

    @ChartContentBuilder
    private var microMapMarks: some ChartContent {
        let lastIndex = max(0, candles.count - 1)
        ForEach(microMapResults) { result in
            let color = result.direction == .long ? Theme.Color.success : Theme.Color.danger
            RectangleMark(
                xStart: .value("MicroMap spike start", Double(result.spikeStartIndex)),
                xEnd: .value("MicroMap spike end", Double(result.spikeEndIndex)),
                yStart: .value("MicroMap spike low", result.spikeLow),
                yEnd: .value("MicroMap spike high", result.spikeHigh)
            )
            .foregroundStyle(color.opacity(0.09))

            if let gap = result.confluence.pressureGap {
                RectangleMark(
                    xStart: .value("MicroMap pressure gap start", Double(gap.startIndex)),
                    xEnd: .value("MicroMap pressure gap end", Double(gap.endIndex)),
                    yStart: .value("MicroMap pressure gap low", gap.low),
                    yEnd: .value("MicroMap pressure gap high", gap.high)
                )
                .foregroundStyle(Theme.Color.accentStart.opacity(0.20))
            }

            ForEach(Array(result.microStartIndex...result.microEndIndex), id: \.self) { index in
                LineMark(
                    x: .value("MicroMap channel bar", Double(index)),
                    y: .value("MicroMap channel", result.direction == .long ? candles[index].high : candles[index].low),
                    series: .value("MicroMap series", "micromap-\(result.id)")
                )
                .foregroundStyle(color.opacity(0.75))
                .lineStyle(StrokeStyle(lineWidth: 1.4, dash: [3, 2]))
            }

            PointMark(x: .value("MicroMap title x", Double(result.spikeStartIndex)),
                      y: .value("MicroMap title y", result.spikeHigh))
                .symbolSize(0)
                .annotation(position: .top, alignment: .leading, spacing: 1) {
                    setupTag(microMapTitle(result), color: color)
                }

            ForEach(result.attempts) { attempt in
                let start = Double(attempt.anchorIndex ?? result.microEndIndex)
                let end = Double(attempt.targetIndex ?? attempt.stopIndex ?? result.endIndex ?? lastIndex)
                let opacity: Double = attempt.status == .stopped ? 0.35 : (attempt.status == .active ? 0.95 : 0.65)
                let dash: [CGFloat] = attempt.status == .active || attempt.status == .succeeded ? [] : [3, 3]

                if let entry = attempt.entry,
                   let stop = attempt.stopLoss,
                   let target = attempt.takeProfit {
                    RuleMark(xStart: .value("MicroMap entry start", start),
                             xEnd: .value("MicroMap entry end", end),
                             y: .value("MicroMap entry", entry))
                        .foregroundStyle(color.opacity(opacity))
                        .lineStyle(StrokeStyle(lineWidth: 1.4, dash: dash))
                    RuleMark(xStart: .value("MicroMap stop start", start),
                             xEnd: .value("MicroMap stop end", end),
                             y: .value("MicroMap stop", stop))
                        .foregroundStyle(Theme.Color.danger.opacity(opacity))
                        .lineStyle(StrokeStyle(lineWidth: 1.1, dash: dash))
                    RuleMark(xStart: .value("MicroMap target start", start),
                             xEnd: .value("MicroMap target end", end),
                             y: .value("MicroMap target", target))
                        .foregroundStyle(Theme.Color.success.opacity(opacity))
                        .lineStyle(StrokeStyle(lineWidth: 1.1, dash: dash))
                    PointMark(x: .value("MicroMap label x", end),
                              y: .value("MicroMap label y", entry))
                        .symbolSize(0)
                        .annotation(position: .overlay, alignment: .trailing, spacing: 0) {
                            setupTag("Entry \(attempt.number)", color: color.opacity(opacity))
                        }
                } else {
                    RuleMark(xStart: .value("MicroMap pending start", start),
                             xEnd: .value("MicroMap pending end", end),
                             y: .value("MicroMap pending", attempt.triggerLevel))
                        .foregroundStyle(color.opacity(0.55))
                        .lineStyle(StrokeStyle(lineWidth: 1.1, dash: [3, 4]))
                }
            }

            if result.stage == .invalidated, let end = result.endIndex {
                PointMark(
                    x: .value("MicroMap invalid x", Double(end)),
                    y: .value("MicroMap invalid y", result.direction == .long ? candles[end].low : candles[end].high)
                )
                .symbolSize(55)
                .foregroundStyle(Theme.Color.danger)
                .annotation(position: result.direction == .long ? .bottom : .top, spacing: 2) {
                    setupTag("INVALID x3", color: Theme.Color.danger)
                }
            }
        }
    }

    private func microMapTitle(_ result: MicroMapSetup.Result) -> String {
        let direction = result.direction == .long ? "LONG" : "SHORT"
        let quality: String
        switch result.confluence.quality {
        case .standard: quality = "STANDARD"
        case .confirmed: quality = "CONFIRMED"
        case .strong: quality = "STRONG"
        }
        return "MICROMAP \(direction) · \(quality) \(result.confluence.score)/6"
    }

    // MARK: - Pin Bar Combo marks

    @ChartContentBuilder
    private var pinBarComboMarks: some ChartContent {
        let lastIndex = max(0, candles.count - 1)
        ForEach(pinBarComboResults) { result in
            let color = pinBarComboColor(result.direction)
            let confirmation = Double(result.confirmationIndex)
            let start = Double(result.breakoutIndex)
            let end = Double(result.resolveIndex ?? lastIndex)

            RuleMark(
                xStart: .value("Pin Bar level start", start),
                xEnd: .value("Pin Bar level end", end),
                y: .value("Pin Bar tested level", result.level)
            )
            .foregroundStyle(IndicatorKind.pinBarCombo.color.opacity(0.75))
            .lineStyle(StrokeStyle(lineWidth: 1.2, dash: [4, 3]))

            RectangleMark(
                xStart: .value("Pin Bar candle start", confirmation - 0.34),
                xEnd: .value("Pin Bar candle end", confirmation + 0.34),
                yStart: .value("Pin Bar low", result.pinBarLow),
                yEnd: .value("Pin Bar high", result.pinBarHigh)
            )
            .foregroundStyle(color.opacity(0.16))

            PointMark(
                x: .value("Pin Bar confirmation x", confirmation),
                y: .value(
                    "Pin Bar confirmation y",
                    result.direction == .long ? result.pinBarLow : result.pinBarHigh
                )
            )
            .symbolSize(68)
            .foregroundStyle(color)
            .annotation(
                position: result.direction == .long ? .bottom : .top,
                alignment: .center,
                spacing: 3
            ) {
                setupTag(result.kind == .sp2l ? "PIN · SP2L" : "PIN · BTB", color: color)
            }

            RuleMark(
                xStart: .value("Pin Bar entry start", confirmation),
                xEnd: .value("Pin Bar entry end", end),
                y: .value("Pin Bar entry", result.entry)
            )
            .foregroundStyle(color.opacity(0.95))
            .lineStyle(StrokeStyle(lineWidth: 1.5))

            RuleMark(
                xStart: .value("Pin Bar SL start", confirmation),
                xEnd: .value("Pin Bar SL end", end),
                y: .value("Pin Bar SL", result.stopLoss)
            )
            .foregroundStyle(Theme.Color.danger.opacity(0.9))
            .lineStyle(StrokeStyle(lineWidth: 1.2))

            RuleMark(
                xStart: .value("Pin Bar TP start", confirmation),
                xEnd: .value("Pin Bar TP end", end),
                y: .value("Pin Bar TP", result.takeProfit)
            )
            .foregroundStyle(Theme.Color.success.opacity(0.9))
            .lineStyle(StrokeStyle(lineWidth: 1.2))

            PointMark(
                x: .value("Pin Bar entry label x", end),
                y: .value("Pin Bar entry label y", result.entry)
            )
            .symbolSize(0)
            .annotation(position: .overlay, alignment: .trailing, spacing: 0) {
                setupTag(pinBarComboStatusLabel(result), color: color)
            }

            PointMark(
                x: .value("Pin Bar SL label x", end),
                y: .value("Pin Bar SL label y", result.stopLoss)
            )
            .symbolSize(0)
            .annotation(position: .overlay, alignment: .trailing, spacing: 0) {
                setupTag("SL", color: Theme.Color.danger)
            }

            PointMark(
                x: .value("Pin Bar TP label x", end),
                y: .value("Pin Bar TP label y", result.takeProfit)
            )
            .symbolSize(0)
            .annotation(position: .overlay, alignment: .trailing, spacing: 0) {
                setupTag(
                    "TP R\(String(format: "%.2g", indicatorConfig.pinBarRiskReward))",
                    color: Theme.Color.success
                )
            }
        }
    }

    private func pinBarComboColor(_ direction: PinBarComboSetup.Direction) -> Color {
        direction == .long ? Theme.Color.success : Theme.Color.danger
    }

    private func pinBarComboStatusLabel(_ result: PinBarComboSetup.Result) -> String {
        switch result.status {
        case .active: return result.direction == .long ? "LONG active" : "SHORT active"
        case .hitTP: return "Target hit"
        case .hitSL: return "Stopped"
        case .expired: return "Time exit"
        }
    }

    // MARK: - Major Trend Reversal marks

    @ChartContentBuilder
    private var mtrMarks: some ChartContent {
        let lastIndex = max(0, candles.count - 1)
        ForEach(mtrResults) { result in
            let color = mtrDirectionColor(result.direction)
            let isForming = result.stage == .forming
            let opacity = isForming ? 0.55 : (result.stage == .expired ? 0.30 : 0.90)
            let channelDelta = result.channelEndIndex - result.channelStartIndex
            let slope = channelDelta == 0 ? 0 :
                (result.channelEndPrice - result.channelStartPrice) / Double(channelDelta)
            let projectedMain = result.channelStartPrice
                + slope * Double(result.breakoutIndex - result.channelStartIndex)
            let parallelOffset = result.parallelStartPrice - result.channelStartPrice
            let projectedParallel = projectedMain + parallelOffset
            let planEnd = Double(result.resolveIndex ?? lastIndex)

            ForEach([0, 1], id: \.self) { endpoint in
                LineMark(
                    x: .value(
                        "MTR channel x",
                        endpoint == 0 ? Double(result.channelStartIndex) : Double(result.breakoutIndex)
                    ),
                    y: .value(
                        "MTR channel y",
                        endpoint == 0 ? result.channelStartPrice : projectedMain
                    ),
                    series: .value("MTR channel series", "mtr-main-\(result.id)")
                )
                .foregroundStyle(IndicatorKind.mtrStrategy.color.opacity(opacity))
                .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [5, 3]))

                LineMark(
                    x: .value(
                        "MTR parallel x",
                        endpoint == 0 ? Double(result.channelStartIndex) : Double(result.breakoutIndex)
                    ),
                    y: .value(
                        "MTR parallel y",
                        endpoint == 0 ? result.parallelStartPrice : projectedParallel
                    ),
                    series: .value("MTR parallel series", "mtr-parallel-\(result.id)")
                )
                .foregroundStyle(IndicatorKind.mtrStrategy.color.opacity(opacity * 0.65))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
            }

            RuleMark(
                xStart: .value("MTR old extreme start", Double(result.trendExtremeIndex)),
                xEnd: .value("MTR old extreme end", Double(result.retestIndex)),
                y: .value("MTR old extreme", result.trendExtremePrice)
            )
            .foregroundStyle(color.opacity(opacity * 0.65))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))

            RuleMark(
                xStart: .value("MTR neckline start", Double(result.breakoutIndex)),
                xEnd: .value("MTR neckline end", planEnd),
                y: .value("MTR neckline", result.neckline)
            )
            .foregroundStyle(color.opacity(opacity))
            .lineStyle(StrokeStyle(lineWidth: 1.4, dash: [5, 3]))

            PointMark(
                x: .value("MTR retest x", Double(result.retestIndex)),
                y: .value("MTR retest y", result.retestPrice)
            )
            .symbolSize(isForming ? 54 : 72)
            .foregroundStyle(color.opacity(opacity))
            .annotation(
                position: result.direction == .long ? .bottom : .top,
                alignment: .center,
                spacing: 3
            ) {
                setupTag("MTR · \(result.variant.label)", color: color.opacity(opacity))
            }

            if let confirmation = result.confirmationIndex {
                PointMark(
                    x: .value("MTR confirmation x", Double(confirmation)),
                    y: .value("MTR confirmation y", candles[confirmation].close)
                )
                .symbolSize(82)
                .foregroundStyle(color)
                .annotation(
                    position: result.direction == .long ? .top : .bottom,
                    alignment: .center,
                    spacing: 3
                ) {
                    setupTag(
                        result.direction == .long ? "MTR LONG confirmed" : "MTR SHORT confirmed",
                        color: color
                    )
                }
            }

            if let entry = result.entry,
               let stop = result.stopLoss,
               let target = result.takeProfit,
               let confirmation = result.confirmationIndex {
                let planStart = Double(confirmation)
                RuleMark(
                    xStart: .value("MTR entry start", planStart),
                    xEnd: .value("MTR entry end", planEnd),
                    y: .value("MTR entry", entry)
                )
                .foregroundStyle(color.opacity(opacity))
                .lineStyle(StrokeStyle(lineWidth: 1.5))

                RuleMark(
                    xStart: .value("MTR stop start", planStart),
                    xEnd: .value("MTR stop end", planEnd),
                    y: .value("MTR stop", stop)
                )
                .foregroundStyle(Theme.Color.danger.opacity(opacity))
                .lineStyle(StrokeStyle(lineWidth: 1.3))

                RuleMark(
                    xStart: .value("MTR target start", planStart),
                    xEnd: .value("MTR target end", planEnd),
                    y: .value("MTR target", target)
                )
                .foregroundStyle(Theme.Color.success.opacity(opacity))
                .lineStyle(StrokeStyle(lineWidth: 1.3))

                PointMark(x: .value("MTR status x", planEnd), y: .value("MTR status y", entry))
                    .symbolSize(0)
                    .annotation(position: .overlay, alignment: .trailing, spacing: 0) {
                        setupTag(mtrStatusLabel(result), color: color.opacity(opacity))
                    }
                PointMark(x: .value("MTR SL x", planEnd), y: .value("MTR SL y", stop))
                    .symbolSize(0)
                    .annotation(position: .overlay, alignment: .trailing, spacing: 0) {
                        setupTag("SL", color: Theme.Color.danger.opacity(opacity))
                    }
                PointMark(x: .value("MTR TP x", planEnd), y: .value("MTR TP y", target))
                    .symbolSize(0)
                    .annotation(position: .overlay, alignment: .trailing, spacing: 0) {
                        setupTag(
                            "TP R\(String(format: "%.2g", indicatorConfig.mtrRiskReward))",
                            color: Theme.Color.success.opacity(opacity)
                        )
                    }
            }
        }
    }

    private func mtrDirectionColor(_ direction: MTRSetup.Direction) -> Color {
        direction == .long ? Theme.Color.success : Theme.Color.danger
    }

    private func mtrStatusLabel(_ result: MTRSetup.Result) -> String {
        switch result.stage {
        case .forming: return "MTR forming"
        case .confirmed: return result.direction == .long ? "LONG active" : "SHORT active"
        case .hitTP: return "Target hit"
        case .hitSL: return "Stopped"
        case .expired: return "Expired"
        }
    }

    private func setupTag(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 8, weight: .heavy))
            .foregroundStyle(.white)
            .padding(.horizontal, 4)
            .padding(.vertical, 1)
            .background(Capsule().fill(color.opacity(0.95)))
            .fixedSize()
    }

    // MARK: - Order block marks

    @ChartContentBuilder
    private var orderBlockMarks: some ChartContent {
        let lastIndex = candles.count - 1
        ForEach(orderBlockZones) { zone in
            orderOBMark(for: zone, lastIndex: lastIndex)
        }
    }

    @ChartContentBuilder
    private func orderOBMark(for zone: OrderBlocks.Zone, lastIndex: Int) -> some ChartContent {
        let baseColor: Color = zone.isBullish ? Theme.Color.success : Theme.Color.danger
        let xStart = Double(zone.index)
        let xEnd   = Double(lastIndex)

        let (fillOp, borderOp, borderDash, labelText): (Double, Double, [CGFloat], String) = {
            switch zone.status {
            case .fresh:
                return (0.14, 0.7, [], zone.isBullish ? "OB↑" : "OB↓")
            case .tested:
                return (0.07, 0.35, [2, 2], zone.isBullish ? "OB↑ · Tested" : "OB↓ · Tested")
            case .exhausted:
                return (0.03, 0.18, [2, 6], zone.isBullish ? "OB↑ · Exhausted" : "OB↓ · Exhausted")
            }
        }()

        RectangleMark(
            xStart: .value("OB start", xStart),
            xEnd:   .value("OB end",   xEnd),
            yStart: .value("OB low",   zone.low),
            yEnd:   .value("OB high",  zone.high)
        )
        .foregroundStyle(baseColor.opacity(fillOp))

        RuleMark(
            xStart: .value("OB start hi", xStart),
            xEnd:   .value("OB end hi",   xEnd),
            y:      .value("OB hi",       zone.high)
        )
        .foregroundStyle(baseColor.opacity(borderOp))
        .lineStyle(StrokeStyle(lineWidth: 1, dash: borderDash))
        RuleMark(
            xStart: .value("OB start lo", xStart),
            xEnd:   .value("OB end lo",   xEnd),
            y:      .value("OB lo",       zone.low)
        )
        .foregroundStyle(baseColor.opacity(borderOp))
        .lineStyle(StrokeStyle(lineWidth: 1, dash: borderDash))

        RuleMark(
            xStart: .value("OB start avg", xStart),
            xEnd:   .value("OB end avg",   xEnd),
            y:      .value("OB avg",       zone.avg)
        )
        .foregroundStyle(baseColor.opacity(borderOp * 0.7))
        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))

        PointMark(
            x: .value("OB label", xEnd),
            y: .value("OB hi",    zone.high)
        )
        .symbolSize(0)
        .annotation(position: .overlay, alignment: .trailing, spacing: 0) {
            Text(labelText)
                .font(.system(size: 8, weight: .heavy))
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Capsule().fill(baseColor.opacity(zone.status == .fresh ? 0.95 : 0.6)))
        }
    }

    // MARK: - Steroid order block marks

    @ChartContentBuilder
    private var steroidOrderBlockMarks: some ChartContent {
        let lastIndex = candles.count - 1
        ForEach(steroidOrderBlockZones) { zone in
            let baseColor: Color = zone.isBullish ? Theme.Color.success : Theme.Color.danger
            let accentColor = IndicatorKind.steroidOrderBlock.color
            let xStart = Double(zone.index)
            let xEnd   = Double(lastIndex)

            let (fillOp, borderOp, borderDash, labelText): (Double, Double, [CGFloat], String) = {
                switch zone.status {
                case .fresh:
                    return (0.18, 0.85, [], zone.isBullish ? "⚡ SOB↑" : "⚡ SOB↓")
                case .tested:
                    return (0.09, 0.45, [3, 3], zone.isBullish ? "⚡ SOB↑ · Tested" : "⚡ SOB↓ · Tested")
                case .exhausted:
                    return (0.03, 0.18, [2, 6], zone.isBullish ? "⚡ SOB↑ · Exhausted" : "⚡ SOB↓ · Exhausted")
                }
            }()

            RectangleMark(
                xStart: .value("SOB start", xStart),
                xEnd:   .value("SOB end",   xEnd),
                yStart: .value("SOB low",   zone.low),
                yEnd:   .value("SOB high",  zone.high)
            )
            .foregroundStyle(baseColor.opacity(fillOp))

            RuleMark(xStart: .value("SOB start hi", xStart), xEnd: .value("SOB end hi", xEnd),
                     y: .value("SOB hi", zone.high))
            .foregroundStyle(baseColor.opacity(borderOp))
            .lineStyle(StrokeStyle(lineWidth: 1.2, dash: borderDash))
            RuleMark(xStart: .value("SOB start lo", xStart), xEnd: .value("SOB end lo", xEnd),
                     y: .value("SOB lo", zone.low))
            .foregroundStyle(baseColor.opacity(borderOp))
            .lineStyle(StrokeStyle(lineWidth: 1.2, dash: borderDash))

            RuleMark(xStart: .value("SOB start avg", xStart), xEnd: .value("SOB end avg", xEnd),
                     y: .value("SOB avg", zone.avg))
            .foregroundStyle(accentColor.opacity(0.8))
            .lineStyle(StrokeStyle(lineWidth: 1.2, dash: [4, 2]))

            PointMark(x: .value("SOB label", xEnd), y: .value("SOB hi", zone.high))
                .symbolSize(0)
                .annotation(position: .overlay, alignment: .trailing, spacing: 0) {
                    Text(labelText)
                        .font(.system(size: 8, weight: .heavy))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(accentColor))
                }
        }
    }

    // MARK: - Sonarlab order block marks

    @ChartContentBuilder
    private var sonarlabOBMarks: some ChartContent {
        let lastIndex = candles.count - 1
        ForEach(sonarlabOBZones) { zone in
            sonarlabOBMark(for: zone, lastIndex: lastIndex)
        }
    }

    @ChartContentBuilder
    private func sonarlabOBMark(for zone: SonarlabOrderBlocks.Zone, lastIndex: Int) -> some ChartContent {
        let baseColor: Color = zone.isBullish ? Theme.Color.success : Theme.Color.danger
        let accentColor = IndicatorKind.sonarlabOrderBlock.color
        let xStart = Double(zone.index)
        let xEnd   = Double(lastIndex)

        // Fill
        RectangleMark(
            xStart: .value("SOB start", xStart),
            xEnd:   .value("SOB end",   xEnd),
            yStart: .value("SOB low",   zone.low),
            yEnd:   .value("SOB high",  zone.high)
        )
        .foregroundStyle(baseColor.opacity(0.12))

        // Top edge
        RuleMark(
            xStart: .value("SOB start hi", xStart),
            xEnd:   .value("SOB end hi",   xEnd),
            y:      .value("SOB hi",       zone.high)
        )
        .foregroundStyle(baseColor.opacity(0.70))
        .lineStyle(StrokeStyle(lineWidth: 1.0))

        // Bottom edge
        RuleMark(
            xStart: .value("SOB start lo", xStart),
            xEnd:   .value("SOB end lo",   xEnd),
            y:      .value("SOB lo",       zone.low)
        )
        .foregroundStyle(baseColor.opacity(0.70))
        .lineStyle(StrokeStyle(lineWidth: 1.0))

        // Direction tag at the right edge
        let tagText = zone.isBullish ? "SOB↑" : "SOB↓"
        PointMark(
            x: .value("SOB label", xEnd),
            y: .value("SOB hi",    zone.high)
        )
        .symbolSize(0)
        .annotation(position: .overlay, alignment: .trailing, spacing: 0) {
            Text(tagText)
                .font(.system(size: 8, weight: .heavy))
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Capsule().fill(accentColor))
        }
    }


    // MARK: - Ranked order block marks

    /// Ranked Order Blocks. Unlike the other OB layers these carry a
    /// grade: A zones are drawn boldly, B at half strength, C in
    /// neutral grey. A breaker (price traded through it) stops at the
    /// break bar and switches to a dashed grey outline.
    @ChartContentBuilder
    private var rankedOBMarks: some ChartContent {
        let lastIndex = candles.count - 1
        ForEach(rankedOBZones) { zone in
            rankedOBMark(for: zone, lastIndex: lastIndex)
        }
    }

    @ChartContentBuilder
    private func rankedOBMark(for zone: RankedOrderBlocks.Zone, lastIndex: Int) -> some ChartContent {
        let style = Self.rankedOBStyle(for: zone)
        let xStart = Double(zone.startIndex)
        let xEnd   = Double(min(zone.endIndex, lastIndex))
        let edge = StrokeStyle(
            lineWidth: zone.isCombined ? 2 : 1,
            dash: zone.isBreaker ? [4, 3] : []
        )

        RectangleMark(
            xStart: .value("ROB start", xStart),
            xEnd:   .value("ROB end",   xEnd),
            yStart: .value("ROB low",   zone.bottom),
            yEnd:   .value("ROB high",  zone.top)
        )
        .foregroundStyle(style.base.opacity(style.fillOpacity))

        RuleMark(
            xStart: .value("ROB start hi", xStart),
            xEnd:   .value("ROB end hi",   xEnd),
            y:      .value("ROB hi",       zone.top)
        )
        .foregroundStyle(style.base.opacity(style.borderOpacity))
        .lineStyle(edge)

        RuleMark(
            xStart: .value("ROB start lo", xStart),
            xEnd:   .value("ROB end lo",   xEnd),
            y:      .value("ROB lo",       zone.bottom)
        )
        .foregroundStyle(style.base.opacity(style.borderOpacity))
        .lineStyle(edge)

        // Badge sits centred inside the zone, like the Pine original's
        // box text. Anchoring it at the right edge (as the other OB
        // layers do) puts it flush against the price axis, where the
        // plot area clips it away entirely.
        if indicatorConfig.robShowLabels {
            PointMark(
                x: .value("ROB label x", Self.rankedOBLabelX(
                    xStart: xStart, xEnd: xEnd, domain: effectiveXDomain
                )),
                y: .value("ROB label y", (zone.top + zone.bottom) / 2)
            )
            .symbolSize(0)
            .annotation(position: .overlay, alignment: .center, spacing: 0) {
                // `.fixedSize()` is load-bearing: an overlay annotation on
                // a zero-size PointMark is proposed zero width, which
                // truncates the badge down to an unreadable sliver.
                Text(Self.rankedOBBadge(for: zone))
                    .font(.system(size: 8, weight: .heavy))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .fixedSize()
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(style.base.opacity(0.85)))
            }
        }
    }

    /// Where along the zone to park its badge. Zones run from the order
    /// block to the right edge of the chart, so a plain midpoint lands
    /// off-screen on an old zone once the user pans. Clamp it into the
    /// part of the zone that is actually visible, inset from the plot
    /// edges so the capsule isn't clipped.
    private static func rankedOBLabelX(
        xStart: Double,
        xEnd: Double,
        domain: ClosedRange<Double>
    ) -> Double {
        let inset = (domain.upperBound - domain.lowerBound) * 0.05
        let lo = max(xStart, domain.lowerBound + inset)
        let hi = min(xEnd, domain.upperBound - inset)
        return lo <= hi ? (lo + hi) / 2 : (xStart + xEnd) / 2
    }

    /// Badge text: grade + score, with the zone's lifecycle state
    /// appended so a merged or broken zone reads at a glance.
    private static func rankedOBBadge(for zone: RankedOrderBlocks.Zone) -> String {
        var text = zone.badge
        if zone.isCombined { text += " ·M" }
        if zone.isBreaker  { text += " ·BRK" }
        return text
    }

    /// Grade → colour weight. Breakers desaturate to grey whatever grade
    /// they held; C-grade zones are grey from the start.
    private static func rankedOBStyle(
        for zone: RankedOrderBlocks.Zone
    ) -> (base: Color, fillOpacity: Double, borderOpacity: Double) {
        guard !zone.isBreaker else {
            return (Theme.Color.textMuted, 0.08, 0.55)
        }
        let directional = zone.isBullish ? Theme.Color.success : Theme.Color.danger
        switch zone.grade {
        case .a:        return (directional, 0.22, 0.95)
        case .b:        return (directional, 0.12, 0.65)
        case .c:        return (Theme.Color.textMuted, 0.10, 0.50)
        case .unranked: return (IndicatorKind.rankedOrderBlock.color, 0.12, 0.65)
        }
    }

    // MARK: - Change of Character marks

    /// CHoCH overlays: always a broken-structure line + "CHoCH↑/↓" capsule;
    /// the order block / displacement FVG / inverse FVG each draw as their
    /// own rectangle behind the show-OB / show-FVG / show-iFVG toggles.
    @ChartContentBuilder
    private var chochMarks: some ChartContent {
        let lastIndex = candles.count - 1
        ForEach(chochZones) { zone in
            chochMark(for: zone, lastIndex: lastIndex)
        }
    }

    @ChartContentBuilder
    private func chochZoneRect(
        id: String, xStart: Double, xEnd: Double,
        low: Double, high: Double, color: Color,
        fill: Double, dashed: Bool, tag: String
    ) -> some ChartContent {
        let edge: StrokeStyle = dashed
            ? StrokeStyle(lineWidth: 1.0, dash: [4, 3])
            : StrokeStyle(lineWidth: 1.0)
        RectangleMark(
            xStart: .value("\(id) x0", xStart), xEnd: .value("\(id) x1", xEnd),
            yStart: .value("\(id) y0", low),    yEnd: .value("\(id) y1", high)
        )
        .foregroundStyle(color.opacity(fill))
        RuleMark(xStart: .value("\(id) hx0", xStart), xEnd: .value("\(id) hx1", xEnd), y: .value("\(id) hy", high))
            .foregroundStyle(color.opacity(0.6)).lineStyle(edge)
        RuleMark(xStart: .value("\(id) lx0", xStart), xEnd: .value("\(id) lx1", xEnd), y: .value("\(id) ly", low))
            .foregroundStyle(color.opacity(0.6)).lineStyle(edge)
        PointMark(x: .value("\(id) tx", xEnd), y: .value("\(id) ty", high))
            .symbolSize(0)
            .annotation(position: .overlay, alignment: .trailing, spacing: 0) {
                Text(tag)
                    .font(.system(size: 7, weight: .heavy))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 3).padding(.vertical, 1)
                    .background(Capsule().fill(color))
            }
    }

    @ChartContentBuilder
    private func chochMark(for zone: ChangeOfCharacter.Zone, lastIndex: Int) -> some ChartContent {
        let baseColor: Color = zone.isBullish ? Theme.Color.success : Theme.Color.danger
        let accentColor = IndicatorKind.changeOfCharacter.color
        let fvgColor = Color(red: 0.30, green: 0.80, blue: 0.75)
        let xEnd = Double(lastIndex)
        let dim = zone.status == .fresh ? 1.0 : 0.6

        if indicatorConfig.chochShowOB {
            chochZoneRect(
                id: "\(zone.id)-OB", xStart: Double(zone.obIndex), xEnd: xEnd,
                low: zone.obLow, high: zone.obHigh, color: baseColor,
                fill: 0.12 * dim, dashed: !zone.hasFVG, tag: "OB"
            )
        }
        if indicatorConfig.chochShowFVG, let fl = zone.fvgLow, let fh = zone.fvgHigh, let fi = zone.fvgIndex {
            chochZoneRect(
                id: "\(zone.id)-FVG", xStart: Double(fi), xEnd: xEnd,
                low: fl, high: fh, color: fvgColor, fill: 0.16 * dim, dashed: false, tag: "FVG"
            )
        }
        if indicatorConfig.chochShowIFVG, let il = zone.ifvgLow, let ih = zone.ifvgHigh, let ii = zone.ifvgIndex {
            chochZoneRect(
                id: "\(zone.id)-IFVG", xStart: Double(ii), xEnd: xEnd,
                low: il, high: ih, color: accentColor, fill: 0.10 * dim, dashed: true, tag: "iFVG"
            )
        }

        RuleMark(
            xStart: .value("CHoCH lvl start", Double(zone.obIndex)),
            xEnd:   .value("CHoCH lvl end",   Double(zone.chochIndex)),
            y:      .value("CHoCH lvl",       zone.brokenLevel)
        )
        .foregroundStyle(accentColor.opacity(0.8))
        .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))

        let tagText = zone.isBullish ? "CHoCH↑" : "CHoCH↓"
        PointMark(
            x: .value("CHoCH label x", Double(zone.chochIndex)),
            y: .value("CHoCH label y", zone.brokenLevel)
        )
        .symbolSize(0)
        .annotation(position: zone.isBullish ? .top : .bottom, alignment: .center, spacing: 2) {
            Text(tagText)
                .font(.system(size: 8, weight: .heavy))
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Capsule().fill(accentColor))
        }
    }

    // MARK: - Higher-timeframe CHoCH marks

    @ChartContentBuilder
    private var htfChochMarks: some ChartContent {
        let xEnd = Double(max(0, candles.count - 1))
        ForEach(htfChochZones) { zone in
            htfChochMark(for: zone, xEnd: xEnd)
        }
    }

    @ChartContentBuilder
    private func htfChochMark(for zone: ChangeOfCharacter.DatedZone, xEnd: Double) -> some ChartContent {
        let baseColor: Color = zone.isBullish ? Theme.Color.success : Theme.Color.danger
        let accentColor = IndicatorKind.changeOfCharacter.color
        let fvgColor = Color(red: 0.30, green: 0.80, blue: 0.75)
        // HTF zones are context, not the live signal — halve every fill so
        // they sit visibly behind the current-timeframe CHoCH zones.
        let dim = (zone.status == .fresh ? 1.0 : 0.6) * 0.5
        let obX = barIndex(forDate: zone.obDate)
        let chochX = barIndex(forDate: zone.chochDate)

        // Order block layer.
        if indicatorConfig.chochShowOB, let obX {
            chochZoneRect(
                id: "\(zone.id)-HTFOB", xStart: obX, xEnd: xEnd,
                low: zone.obLow, high: zone.obHigh, color: baseColor,
                fill: 0.12 * dim, dashed: true, tag: "OB·HTF"
            )
        }
        // Displacement FVG layer.
        if indicatorConfig.chochShowFVG,
           let fl = zone.fvgLow, let fh = zone.fvgHigh,
           let fd = zone.fvgDate, let fx = barIndex(forDate: fd) {
            chochZoneRect(
                id: "\(zone.id)-HTFFVG", xStart: fx, xEnd: xEnd,
                low: fl, high: fh, color: fvgColor, fill: 0.16 * dim, dashed: true, tag: "FVG·HTF"
            )
        }
        // Inverse FVG layer.
        if indicatorConfig.chochShowIFVG,
           let il = zone.ifvgLow, let ih = zone.ifvgHigh,
           let idt = zone.ifvgDate, let ix = barIndex(forDate: idt) {
            chochZoneRect(
                id: "\(zone.id)-HTFIFVG", xStart: ix, xEnd: xEnd,
                low: il, high: ih, color: accentColor, fill: 0.10 * dim, dashed: true, tag: "iFVG·HTF"
            )
        }

        // Broken-structure level — dashed rule from the OB across to the break.
        if let obX, let chochX {
            RuleMark(
                xStart: .value("HTF CHoCH lvl start", obX),
                xEnd:   .value("HTF CHoCH lvl end",   chochX),
                y:      .value("HTF CHoCH lvl",       zone.brokenLevel)
            )
            .foregroundStyle(accentColor.opacity(0.5))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 3]))
        }

        // Break marker + label at the CHoCH bar.
        if let chochX {
            let tagText = zone.isBullish ? "CHoCH↑ HTF" : "CHoCH↓ HTF"
            PointMark(
                x: .value("HTF CHoCH label x", chochX),
                y: .value("HTF CHoCH label y", zone.brokenLevel)
            )
            .symbolSize(0)
            .annotation(position: zone.isBullish ? .top : .bottom, alignment: .center, spacing: 2) {
                Text(tagText)
                    .font(.system(size: 7, weight: .heavy))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 3)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(accentColor.opacity(0.85)))
            }
        }
    }

    // MARK: - Scenario marks

    @ChartContentBuilder
    private var scenarioMarks: some ChartContent {
        if let scenario = taScenario {
            scenarioOverlay(scenario, isAlt: false)
        }
        if let alt = taAltScenario {
            scenarioOverlay(alt, isAlt: true)
        }
    }

    @ChartContentBuilder
    private func scenarioOverlay(_ scenario: PromptBuilder.TAScenario, isAlt: Bool) -> some ChartContent {
        let tpOpacity: Double = isAlt ? 0.40 : 0.75
        let slOpacity: Double = isAlt ? 0.40 : 0.75
        let entryOpacity: Double = isAlt ? 0.55 : 0.85
        let lineWidth: CGFloat = isAlt ? 0.9 : 1.2
        let entryLineWidth: CGFloat = isAlt ? 1.0 : 1.4
        let dashPattern: [CGFloat] = isAlt ? [2, 5] : [4, 4]
        let entryDash: [CGFloat] = isAlt ? [1, 4] : [2, 3]
        let tpPrefix = isAlt ? "ALT TP" : "TP"
        let slPrefix = isAlt ? "ALT SL" : "SL"

        RuleMark(y: .value(tpPrefix, scenario.takeProfit))
            .foregroundStyle(Theme.Color.success.opacity(tpOpacity))
            .lineStyle(StrokeStyle(lineWidth: lineWidth, dash: dashPattern))
            .annotation(position: .overlay, alignment: .trailing, spacing: 0) {
                levelTag(text: "\(tpPrefix) \(Self.priceShort(scenario.takeProfit))",
                         color: Theme.Color.success.opacity(isAlt ? 0.7 : 1))
            }
        RuleMark(y: .value(slPrefix, scenario.stopLoss))
            .foregroundStyle(Theme.Color.danger.opacity(slOpacity))
            .lineStyle(StrokeStyle(lineWidth: lineWidth, dash: dashPattern))
            .annotation(position: .overlay, alignment: .trailing, spacing: 0) {
                levelTag(text: "\(slPrefix) \(Self.priceShort(scenario.stopLoss))",
                         color: Theme.Color.danger.opacity(isAlt ? 0.7 : 1))
            }
        if let entry = scenario.entry {
            RuleMark(y: .value(isAlt ? "Alt Entry" : "Entry", entry))
                .foregroundStyle(Theme.Color.warn.opacity(entryOpacity))
                .lineStyle(StrokeStyle(lineWidth: entryLineWidth, dash: entryDash))
                .annotation(position: .overlay, alignment: .trailing, spacing: 0) {
                    scenarioEntryTag(scenario: scenario, entry: entry, isAlt: isAlt)
                }
        }
    }

    private func scenarioEntryTag(
        scenario: PromptBuilder.TAScenario,
        entry: Double,
        isAlt: Bool
    ) -> some View {
        let biasLabel: String
        let biasColor: Color
        switch scenario.bias {
        case .long:    biasLabel = "LONG";    biasColor = Theme.Color.success
        case .short:   biasLabel = "SHORT";   biasColor = Theme.Color.danger
        case .neutral: biasLabel = "NEUTRAL"; biasColor = Theme.Color.textSecondary
        }
        let prefix = isAlt ? "ALT · " : ""
        let valid: Bool = livePrice.map { scenario.isValid(at: $0) } ?? true
        return HStack(spacing: 4) {
            Text(prefix + biasLabel)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Capsule().fill(biasColor.opacity(isAlt ? 0.7 : 1)))
            Text("ENTRY \(Self.priceShort(entry))")
                .font(.system(size: 9, weight: .bold).monospacedDigit())
                .foregroundStyle(.white)
                .strikethrough(!valid, color: Theme.Color.danger)
            Text(valid ? "✓ VALID" : "✗ INVALID")
                .font(.system(size: 7, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(
                    Capsule().fill(valid
                                   ? Theme.Color.success.opacity(0.85)
                                   : Theme.Color.danger.opacity(0.85))
                )
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(Capsule().fill(Color.black.opacity(0.55)))
    }

    private func levelTag(text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.85)))
    }

    // MARK: - Trade marks

    @ChartContentBuilder
    private var tradeMarks: some ChartContent {
        ForEach(trades) { trade in
            RuleMark(y: .value("Trade entry", trade.fillPrice ?? trade.entry))
                .foregroundStyle(tradeEntryColor(trade))
                .lineStyle(StrokeStyle(
                    lineWidth: trade.status == .active ? 1.6 : 1.3,
                    dash: trade.status == .pending ? [3, 3] : []
                ))
                .annotation(position: .overlay, alignment: .leading, spacing: 0) {
                    tradeEntryTag(trade)
                }

            RuleMark(y: .value("Trade TP", trade.takeProfit))
                .foregroundStyle(Theme.Color.success.opacity(0.6))
                .lineStyle(StrokeStyle(lineWidth: 1.0, dash: trade.status == .pending ? [3, 3] : [4, 4]))
                .annotation(position: .overlay, alignment: .trailing, spacing: 0) {
                    levelTag(text: "TP \(Self.priceShort(trade.takeProfit))", color: Theme.Color.success)
                }

            RuleMark(y: .value("Trade SL", trade.stopLoss))
                .foregroundStyle(Theme.Color.danger.opacity(0.6))
                .lineStyle(StrokeStyle(lineWidth: 1.0, dash: trade.status == .pending ? [3, 3] : [4, 4]))
                .annotation(position: .overlay, alignment: .trailing, spacing: 0) {
                    levelTag(text: "SL \(Self.priceShort(trade.stopLoss))", color: Theme.Color.danger)
                }
        }
    }

    private func tradeEntryColor(_ t: Trade) -> Color {
        switch t.status {
        case .pending: return Theme.Color.warn
        case .active:  return t.side == .short ? Theme.Color.danger : Theme.Color.success
        default:       return Theme.Color.textMuted
        }
    }

    private func tradeEntryTag(_ t: Trade) -> some View {
        let pl: Double = livePrice.map { t.currentPL(at: $0) } ?? 0
        let plText: String? = {
            guard t.status == .active, livePrice != nil else { return nil }
            let sign = pl >= 0 ? "+" : "−"
            return "\(sign)$\(String(format: "%.2f", abs(pl)))"
        }()
        return HStack(spacing: 4) {
            Text(t.sideLabel)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(.white)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(Capsule().fill(tradeEntryColor(t)))
            Text("\(String(format: "%.2f", t.lots)) · \(t.statusLabel.uppercased())")
                .font(.system(size: 9, weight: .bold).monospacedDigit())
                .foregroundStyle(.white)
            if let plText = plText {
                Text(plText)
                    .font(.system(size: 9, weight: .bold).monospacedDigit())
                    .foregroundStyle(pl >= 0 ? Theme.Color.success : Theme.Color.danger)
            }
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(Capsule().fill(Color.black.opacity(0.6)))
    }

    // MARK: - Journal marks

    @ChartContentBuilder
    private var journalMarks: some ChartContent {
        ForEach(journalEntries) { je in
            let sideColor: Color = je.side == .short ? Theme.Color.danger : Theme.Color.success
            let closeIdx: Int? = barIndex(closestTo: je.date)
            let openIdx: Int? = {
                if let od = je.openDate { return barIndex(closestTo: od) }
                guard let ci = closeIdx, let ep = je.entry else { return nil }
                return barIndexForEntryPrice(ep, before: ci)
            }()
            let xOpen  = Double(openIdx  ?? 0)
            let xClose = Double(closeIdx ?? max(0, candles.count - 1))
            let hasSpan = openIdx != nil && closeIdx != nil && openIdx != closeIdx

            if let ep = je.entry, let tp = je.takeProfit, hasSpan {
                RectangleMark(
                    xStart: .value("Open", xOpen), xEnd: .value("Close", xClose),
                    yStart: .value("Entry", ep), yEnd: .value("TP", tp)
                )
                .foregroundStyle(Theme.Color.success.opacity(0.12))
                RuleMark(xStart: .value("Open", xOpen), xEnd: .value("Close", xClose),
                         y: .value("TP", tp))
                .foregroundStyle(Theme.Color.success.opacity(0.8))
                .lineStyle(StrokeStyle(lineWidth: 1.2))
                .annotation(position: .overlay, alignment: .trailing, spacing: 0) {
                    journalLevelTag(text: "TP  \(Self.priceShort(tp))", bg: Theme.Color.success)
                }
            } else if let tp = je.takeProfit {
                RuleMark(y: .value("TP", tp))
                    .foregroundStyle(Theme.Color.success.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1.0, dash: [4, 4]))
                    .annotation(position: .overlay, alignment: .trailing, spacing: 0) {
                        journalLevelTag(text: "TP  \(Self.priceShort(tp))", bg: Theme.Color.success)
                    }
            }

            if let ep = je.entry, let sl = je.stopLoss, hasSpan {
                RectangleMark(
                    xStart: .value("Open", xOpen), xEnd: .value("Close", xClose),
                    yStart: .value("Entry", ep), yEnd: .value("SL", sl)
                )
                .foregroundStyle(Theme.Color.danger.opacity(0.12))
                RuleMark(xStart: .value("Open", xOpen), xEnd: .value("Close", xClose),
                         y: .value("SL", sl))
                .foregroundStyle(Theme.Color.danger.opacity(0.8))
                .lineStyle(StrokeStyle(lineWidth: 1.2))
                .annotation(position: .overlay, alignment: .trailing, spacing: 0) {
                    journalLevelTag(text: "SL  \(Self.priceShort(sl))", bg: Theme.Color.danger)
                }
            } else if let sl = je.stopLoss {
                RuleMark(y: .value("SL", sl))
                    .foregroundStyle(Theme.Color.danger.opacity(0.7))
                    .lineStyle(StrokeStyle(lineWidth: 1.0, dash: [4, 4]))
                    .annotation(position: .overlay, alignment: .trailing, spacing: 0) {
                        journalLevelTag(text: "SL  \(Self.priceShort(sl))", bg: Theme.Color.danger)
                    }
            }

            if let ep = je.entry {
                if hasSpan {
                    RuleMark(xStart: .value("Open", xOpen), xEnd: .value("Close", xClose),
                             y: .value("Entry", ep))
                    .foregroundStyle(sideColor.opacity(0.95))
                    .lineStyle(StrokeStyle(lineWidth: 1.6))
                    .annotation(position: .overlay, alignment: .trailing, spacing: 0) {
                        journalLevelTag(text: "Entry  \(Self.priceShort(ep))", bg: sideColor)
                    }
                } else {
                    RuleMark(y: .value("Entry", ep))
                        .foregroundStyle(sideColor.opacity(0.85))
                        .lineStyle(StrokeStyle(lineWidth: 1.4, dash: [3, 3]))
                        .annotation(position: .overlay, alignment: .trailing, spacing: 0) {
                            journalLevelTag(text: "Entry  \(Self.priceShort(ep))", bg: sideColor)
                        }
                }
            }
        }
    }

    private func journalLevelTag(text: String, bg: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold).monospacedDigit())
            .foregroundStyle(.white)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 3).fill(bg.opacity(0.85)))
    }

    // MARK: - Drawing marks

    private var renderableDrawings: [ChartDrawing] {
        let movingID = movingDrawingOriginal?.id
        let editingID = editingDrawingID
        var out = drawings.filter { d in
            d.visible && d.id != movingID && d.id != editingID
        }
        if let moving = movingDrawingOriginal, moving.visible {
            out.append(translated(moving))
        }
        if let id = editingID,
           let original = drawings.first(where: { $0.id == id }),
           original.visible,
           let cursor = editingCursor,
           let anchor = editingHandle {
            out.append(original.resized(anchor: anchor, to: cursor))
        }
        return out
    }

    @ChartContentBuilder
    private var drawingMarks: some ChartContent {
        ForEach(renderableDrawings) { d in
            let stroke = d.color.color
            let lw = CGFloat(d.lineWidth)
            switch d.kind {
            case .horizontalLine:
                RuleMark(y: .value("Drawing", d.start.price))
                    .foregroundStyle(stroke)
                    .lineStyle(StrokeStyle(lineWidth: lw, dash: [6, 3]))
            case .trendLine:
                if let end = d.end,
                   let xs = barIndex(forDate: d.start.date),
                   let xe = barIndex(forDate: end.date) {
                    LineMark(x: .value("Bar", xs), y: .value("Price", d.start.price),
                             series: .value("Drawing", d.id.uuidString))
                    .foregroundStyle(stroke)
                    .lineStyle(StrokeStyle(lineWidth: lw))
                    LineMark(x: .value("Bar", xe), y: .value("Price", end.price),
                             series: .value("Drawing", d.id.uuidString))
                    .foregroundStyle(stroke)
                    .lineStyle(StrokeStyle(lineWidth: lw))
                }
            case .rectangle:
                if let end = d.end,
                   let xs = barIndex(forDate: d.start.date),
                   let xe = barIndex(forDate: end.date) {
                    let x0 = min(xs, xe), x1 = max(xs, xe)
                    let y0 = min(d.start.price, end.price)
                    let y1 = max(d.start.price, end.price)
                    RectangleMark(
                        xStart: .value("X0", x0), xEnd: .value("X1", x1),
                        yStart: .value("Y0", y0), yEnd: .value("Y1", y1)
                    )
                    .foregroundStyle(stroke.opacity(d.color.alpha * 0.18))
                    let borderStyle = StrokeStyle(lineWidth: lw)
                    RuleMark(xStart: .value("T", x0), xEnd: .value("T", x1), y: .value("Top", y1))
                        .foregroundStyle(stroke).lineStyle(borderStyle)
                    RuleMark(xStart: .value("B", x0), xEnd: .value("B", x1), y: .value("Bot", y0))
                        .foregroundStyle(stroke).lineStyle(borderStyle)
                    RuleMark(x: .value("L", x0), yStart: .value("L0", y0), yEnd: .value("L1", y1))
                        .foregroundStyle(stroke).lineStyle(borderStyle)
                    RuleMark(x: .value("R", x1), yStart: .value("R0", y0), yEnd: .value("R1", y1))
                        .foregroundStyle(stroke).lineStyle(borderStyle)
                }
            case .volumeProfile:
                if let end = d.end,
                   let xs = barIndex(forDate: d.start.date),
                   let xe = barIndex(forDate: end.date) {
                    // Volume profile - simplified rectangle for iPad
                    RectangleMark(
                        xStart: .value("VP x0", min(xs, xe)),
                        xEnd:   .value("VP x1", max(xs, xe)),
                        yStart: .value("VP y0", min(d.start.price, end.price)),
                        yEnd:   .value("VP y1", max(d.start.price, end.price))
                    )
                    .foregroundStyle(stroke.opacity(0.15))
                }
            case .longPosition, .shortPosition:
                if let end = d.end,
                   let xs = barIndex(forDate: d.start.date),
                   let xe = barIndex(forDate: end.date) {
                    positionMarks(for: d, xs: xs, xe: xe)
                }
            }
        }
        selectionHandleMarks
    }

    // MARK: - Position tool

    /// Long/short position box: green reward zone entry→target, red
    /// risk zone entry→stop, dashed entry line, and a label with lot
    /// size and P/L. Drawn outward from entry so each side keeps its
    /// colour even if a level is dragged through the entry.
    @ChartContentBuilder
    private func positionMarks(for d: ChartDrawing, xs: Double, xe: Double) -> some ChartContent {
        let x0 = min(xs, xe), x1 = max(xs, xe)
        let entry = d.start.price

        if let target = d.targetPrice {
            RectangleMark(
                xStart: .value("X0", x0), xEnd: .value("X1", x1),
                yStart: .value("Y0", entry), yEnd: .value("Y1", target)
            )
            .foregroundStyle(DrawingPalette.profit.opacity(DrawingPalette.zoneAlpha))
            RuleMark(xStart: .value("T0", x0), xEnd: .value("T1", x1),
                     y: .value("Target", target))
                .foregroundStyle(DrawingPalette.profit)
                .lineStyle(StrokeStyle(lineWidth: 1))
        }

        if let stop = d.stopPrice {
            RectangleMark(
                xStart: .value("X0", x0), xEnd: .value("X1", x1),
                yStart: .value("Y0", entry), yEnd: .value("Y1", stop)
            )
            .foregroundStyle(DrawingPalette.loss.opacity(DrawingPalette.zoneAlpha))
            RuleMark(xStart: .value("S0", x0), xEnd: .value("S1", x1),
                     y: .value("Stop", stop))
                .foregroundStyle(DrawingPalette.loss)
                .lineStyle(StrokeStyle(lineWidth: 1))
        }

        RuleMark(xStart: .value("E0", x0), xEnd: .value("E1", x1),
                 y: .value("Entry", entry))
            .foregroundStyle(DrawingPalette.entryLine)
            .lineStyle(StrokeStyle(lineWidth: 1.2, dash: [5, 3]))
            .annotation(position: .topLeading, spacing: 2) {
                positionLabel(for: d)
            }
    }

    @ViewBuilder
    private func positionLabel(for d: ChartDrawing) -> some View {
        let metrics = d.positionMetrics(spec: contractSpec)
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(d.kind.isLong ? "LONG" : "SHORT")
                    .font(.system(size: 13, weight: .heavy))
                    .foregroundStyle(d.kind.isLong ? DrawingPalette.profit : DrawingPalette.loss)
                if let m = metrics {
                    Text(String(format: "%.3f lots", m.lots))
                        .font(.system(size: 13, weight: .semibold).monospacedDigit())
                        .foregroundStyle(Theme.Color.textPrimary)
                }
            }
            if let m = metrics {
                HStack(spacing: 5) {
                    Text("−" + Self.moneyShort(m.riskAmount))
                        .foregroundStyle(DrawingPalette.loss)
                    if let reward = m.reward {
                        Text("+" + Self.moneyShort(reward))
                            .foregroundStyle(DrawingPalette.profit)
                    }
                    if let rr = m.rr {
                        Text(String(format: "%.2fR", rr))
                            .foregroundStyle(Theme.Color.textMuted)
                    }
                }
                .font(.system(size: 12, weight: .medium).monospacedDigit())
                if m.belowMinLot {
                    Text("below min lot")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.Color.warn)
                }
            }
        }
        .padding(.horizontal, 7)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 5)
                .fill(Theme.Color.surfaceMax.opacity(0.85))
        )
    }

    static func moneyShort(_ v: Double) -> String {
        let a = Swift.abs(v)
        if a >= 1_000_000 { return String(format: "$%.2fM", v / 1_000_000) }
        if a >= 1_000     { return String(format: "$%.1fk", v / 1_000) }
        return String(format: "$%.0f", v)
    }

    /// Grab handles for the selected drawing. Sized larger than the Mac
    /// build — these are finger targets, not cursor targets.
    @ChartContentBuilder
    private var selectionHandleMarks: some ChartContent {
        if let sel = selectionTargetDrawing {
            ForEach(handlePositions(for: sel), id: \.self) { hp in
                PointMark(x: .value("Handle X", hp.x), y: .value("Handle Y", hp.y))
                    .symbol(.square)
                    .symbolSize(110)
                    .foregroundStyle(Color.white)
            }
        }
    }

    private var selectionTargetDrawing: ChartDrawing? {
        if let id = editingDrawingID,
           let d = drawings.first(where: { $0.id == id }) {
            if let cursor = editingCursor, let anchor = editingHandle {
                return d.resized(anchor: anchor, to: cursor)
            }
            return d
        }
        if let id = selectedDrawingID {
            return drawings.first(where: { $0.id == id && $0.visible })
        }
        return nil
    }

    struct HandlePoint: Hashable {
        let x: Double
        let y: Double
    }

    @ChartContentBuilder
    private var drawingPreviewMarks: some ChartContent {
        if let s = drawingStart {
            switch activeTool {
            case .none:
                RuleMark(y: .value("noop", s.price)).opacity(0)
            case .horizontalLine:
                RuleMark(y: .value("Preview", s.price))
                    .foregroundStyle(DrawingPalette.preview)
                    .lineStyle(StrokeStyle(lineWidth: 1.2, dash: [4, 4]))
            case .trendLine:
                if let e = drawingEnd,
                   let xs = barIndex(forDate: s.date),
                   let xe = barIndex(forDate: e.date) {
                    LineMark(x: .value("Bar", xs), y: .value("Price", s.price),
                             series: .value("Preview", "drawing-preview"))
                    .foregroundStyle(DrawingPalette.preview)
                    .lineStyle(StrokeStyle(lineWidth: 1.4, dash: [3, 3]))
                    LineMark(x: .value("Bar", xe), y: .value("Price", e.price),
                             series: .value("Preview", "drawing-preview"))
                    .foregroundStyle(DrawingPalette.preview)
                    .lineStyle(StrokeStyle(lineWidth: 1.4, dash: [3, 3]))
                }
            case .rectangle:
                if let e = drawingEnd,
                   let xs = barIndex(forDate: s.date),
                   let xe = barIndex(forDate: e.date) {
                    RectangleMark(
                        xStart: .value("Preview X start", min(xs, xe)),
                        xEnd:   .value("Preview X end",   max(xs, xe)),
                        yStart: .value("Preview Y start", min(s.price, e.price)),
                        yEnd:   .value("Preview Y end",   max(s.price, e.price))
                    )
                    .foregroundStyle(DrawingPalette.fill.opacity(0.6))
                }
            case .volumeProfile:
                if let e = drawingEnd,
                   let xs = barIndex(forDate: s.date),
                   let xe = barIndex(forDate: e.date) {
                    RectangleMark(
                        xStart: .value("VP Preview x0", min(xs, xe)),
                        xEnd:   .value("VP Preview x1", max(xs, xe)),
                        yStart: .value("VP Preview y0", min(s.price, e.price)),
                        yEnd:   .value("VP Preview y1", max(s.price, e.price))
                    )
                    .foregroundStyle(DrawingPalette.fill.opacity(0.25))
                }
            case .longPosition, .shortPosition:
                // Mirror what the commit will build: drag height is the
                // stop distance, target sits 2R the other side.
                if let e = drawingEnd,
                   let xs = barIndex(forDate: s.date),
                   let xe = barIndex(forDate: e.date) {
                    let long = activeTool == .longPosition
                    let dist = Swift.abs(e.price - s.price)
                    let stop   = long ? s.price - dist : s.price + dist
                    let target = long ? s.price + dist * 2 : s.price - dist * 2
                    RectangleMark(
                        xStart: .value("Pos preview x0", min(xs, xe)),
                        xEnd:   .value("Pos preview x1", max(xs, xe)),
                        yStart: .value("Pos preview y0", s.price),
                        yEnd:   .value("Pos preview y1", target)
                    )
                    .foregroundStyle(DrawingPalette.profit.opacity(0.14))
                    RectangleMark(
                        xStart: .value("Pos preview x2", min(xs, xe)),
                        xEnd:   .value("Pos preview x3", max(xs, xe)),
                        yStart: .value("Pos preview y2", s.price),
                        yEnd:   .value("Pos preview y3", stop)
                    )
                    .foregroundStyle(DrawingPalette.loss.opacity(0.14))
                }
            }
        }
    }

    // MARK: - Indicator marks

    @ChartContentBuilder
    private func indicatorMarks(visLo: Int, visHi: Int) -> some ChartContent {
        let instances = indicators.map { Self.makeIndicatorInstance(kind: $0, config: indicatorConfig) }
        let computed = derived.indicators(instances: instances, candles: candles)
        ForEach(computed, id: \.instance.id) { entry in
            ForEach(entry.points.filter { $0.index >= visLo && $0.index <= visHi }) { p in
                LineMark(
                    x: .value("Bar", Double(p.index)),
                    y: .value("Indicator", p.value),
                    series: .value("Series", "\(entry.instance.kind.rawValue)-\(p.band)")
                )
                .foregroundStyle(indicatorColor(for: entry.instance.kind, band: p.band))
                .lineStyle(StrokeStyle(
                    lineWidth: p.band == "bb_mid" ? 1 : 1.6,
                    dash: p.band == "bb_mid" ? [3, 3] : []
                ))
                .interpolationMethod(.monotone)
            }
        }
    }

    // MARK: - Volume-Filtered Order Blocks

    @ChartContentBuilder
    private var volumeFilteredOBMarks: some ChartContent {
        let lastIndex = candles.count - 1
        ForEach(volumeFilteredOBZones) { zone in
            volumeFilteredOBMark(zone, lastIndex: lastIndex)
        }
    }

    @ChartContentBuilder
    private func volumeFilteredOBMark(_ zone: VolumeFilteredOrderBlocks.Zone, lastIndex: Int) -> some ChartContent {
        let base: Color = zone.isBullish ? Theme.Color.success : Theme.Color.danger
        let fillOp = zone.breaker ? 0.08 : 0.20
        let borderOp = zone.breaker ? 0.35 : 0.75
        let xStart = Double(zone.startIndex)
        let xEnd   = Double(min(zone.endIndex, lastIndex))

        RectangleMark(
            xStart: .value("VFOB x0", xStart), xEnd: .value("VFOB x1", xEnd),
            yStart: .value("VFOB y0", zone.bottom), yEnd: .value("VFOB y1", zone.top)
        )
        .foregroundStyle(base.opacity(fillOp))

        RuleMark(xStart: .value("VFOB t0", xStart), xEnd: .value("VFOB t1", xEnd), y: .value("VFOB top", zone.top))
            .foregroundStyle(base.opacity(borderOp))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: zone.breaker ? [3, 3] : []))
        RuleMark(xStart: .value("VFOB b0", xStart), xEnd: .value("VFOB b1", xEnd), y: .value("VFOB bot", zone.bottom))
            .foregroundStyle(base.opacity(borderOp))
            .lineStyle(StrokeStyle(lineWidth: 1, dash: zone.breaker ? [3, 3] : []))

        if indicatorConfig.vfobVolumetricInfo, zone.volume > 0 {
            let mid = (zone.top + zone.bottom) / 2
            let span = max(1.0, xEnd - xStart)
            let barMax = min(span * 0.5, 8.0)
            let upW = barMax * (zone.highVolume / zone.volume)
            let dnW = barMax * (zone.lowVolume / zone.volume)
            RectangleMark(
                xStart: .value("VFOB uv0", xStart), xEnd: .value("VFOB uv1", xStart + upW),
                yStart: .value("VFOB uvy0", mid), yEnd: .value("VFOB uvy1", zone.top)
            )
            .foregroundStyle(Theme.Color.success.opacity(0.55))
            RectangleMark(
                xStart: .value("VFOB dv0", xStart), xEnd: .value("VFOB dv1", xStart + dnW),
                yStart: .value("VFOB dvy0", zone.bottom), yEnd: .value("VFOB dvy1", mid)
            )
            .foregroundStyle(Theme.Color.danger.opacity(0.55))

            PointMark(x: .value("VFOB lbl x", xEnd), y: .value("VFOB lbl y", zone.top))
                .symbolSize(0)
                .annotation(position: .overlay, alignment: .topTrailing, spacing: 0) {
                    Text("\(Self.volumeShort(zone.volume)) (\(zone.balancePct)%)")
                        .font(.system(size: 8, weight: .heavy))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 3)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(base.opacity(0.9)))
                }
        }
    }

    private static func volumeShort(_ v: Double) -> String {
        let a = abs(v)
        switch a {
        case 1_000_000_000...: return String(format: "%.1fB", v / 1_000_000_000)
        case 1_000_000...:     return String(format: "%.1fM", v / 1_000_000)
        case 1_000...:         return String(format: "%.1fK", v / 1_000)
        default:               return String(format: "%.0f", v)
        }
    }

    /// Stable IndicatorInstance per kind — deterministic UUID avoids
    /// SwiftUI diff churn on every body evaluation, and params from the
    /// current OscillatorConfig ensure the chart uses the user's chosen
    /// periods instead of hardcoded defaults.
    private static func makeIndicatorInstance(kind: IndicatorKind, config: OscillatorConfig) -> IndicatorInstance {
        // Derive a stable UUID from the rawValue so identity is
        // consistent across renders and app launches.
        let raw = kind.rawValue
        let padded = raw.padding(toLength: 12, withPad: "0", startingAt: 0)
        let stableID = UUID(uuidString: "00000000-0000-0000-0000-\(padded)") ?? UUID()
        var params: [String: ParamValue] = [:]
        switch kind {
        case .sma20:  params["period"] = .double(20)
        case .sma50:  params["period"] = .double(50)
        case .sma200: params["period"] = .double(200)
        case .ema9:   params["period"] = .double(9)
        case .ema21:  params["period"] = .double(21)
        case .bollinger:
            params["period"] = .double(20)
            params["stdDev"] = .double(2)
        case .utBot:
            params["keyValue"]      = .double(config.utKeyValue)
            params["atrPeriod"]     = .double(Double(config.utATRPeriod))
            params["useHeikinAshi"] = .bool(config.utUseHeikinAshi)
        default:
            break
        }
        return IndicatorInstance(id: stableID, kind: kind, params: params)
    }

    private func indicatorColor(for kind: IndicatorKind, band: String) -> Color {
        switch band {
        case "bb_upper", "bb_lower": return kind.color
        case "bb_mid":               return kind.color.opacity(0.55)
        default:                     return kind.color
        }
    }

    // MARK: - UT Bot marks

    @ChartContentBuilder
    private func utBotMarks(indices: [Int], visLo: Int, visHi: Int) -> some ChartContent {
        if let out = utBotOutput {
            if indicatorConfig.utShowTrailingStop {
                ForEach(indices, id: \.self) { i in
                    if i < out.trailingStop.count, let v = out.trailingStop[i] {
                        LineMark(
                            x: .value("Bar", Double(i)),
                            y: .value("UT Stop", v),
                            series: .value("Series", "utbot-trail")
                        )
                        .foregroundStyle(IndicatorKind.utBot.color)
                        .lineStyle(StrokeStyle(lineWidth: 1.4, lineJoin: .miter))
                        .interpolationMethod(.stepStart)
                    }
                }
            }
            let cs = displayCandles
            ForEach(out.signals.filter { $0.index >= visLo && $0.index <= visHi }) { sig in
                let c = cs[sig.index]
                PointMark(
                    x: .value("Bar", Double(sig.index)),
                    y: .value("Signal", sig.isBuy ? c.low : c.high)
                )
                .symbol(.circle)
                .symbolSize(0)
                .annotation(
                    position: sig.isBuy ? .bottom : .top,
                    alignment: .center,
                    spacing: 2
                ) {
                    Text(sig.isBuy ? "BUY" : "SELL")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(
                            Capsule().fill(sig.isBuy
                                           ? Theme.Color.success
                                           : Theme.Color.danger)
                        )
                }
            }
        }
    }

    // MARK: - Candle marks

    @ChartContentBuilder
    private func candleMarks(indices: [Int]) -> some ChartContent {
        let cs = displayCandles
        ForEach(indices, id: \.self) { i in
            let c = cs[i]
            RuleMark(
                x: .value("Bar", Double(i)),
                yStart: .value("Low", c.low),
                yEnd: .value("High", c.high)
            )
            .foregroundStyle(c.close >= c.open ? Theme.Color.success : Theme.Color.danger)
            .lineStyle(StrokeStyle(lineWidth: 1))

            RectangleMark(
                x: .value("Bar", Double(i)),
                yStart: .value("Body lo", min(c.open, c.close)),
                yEnd: .value("Body hi", max(c.open, c.close)),
                width: .fixed(candleBodyWidth)
            )
            .foregroundStyle(c.close >= c.open ? Theme.Color.success : Theme.Color.danger)
            .cornerRadius(1)
        }
    }

    // MARK: - Axes

    private func xAxis() -> some AxisContent {
        AxisMarks(preset: .aligned, values: xAxisLabelValues) { value in
            AxisGridLine().foregroundStyle(Color.white.opacity(0.04))
            AxisTick().foregroundStyle(Color.white.opacity(0.08))
            AxisValueLabel {
                if let idx = value.as(Double.self),
                   let label = labelForIndex(idx) {
                    Text(label)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(Theme.Color.textMuted)
                }
            }
        }
    }

    private var xAxisLabelValues: [Double] {
        let domain = effectiveXDomain
        let span = domain.upperBound - domain.lowerBound
        guard span > 0 else { return [] }
        let count = 6
        return (0...count).map { i in
            domain.lowerBound + (span * Double(i) / Double(count))
        }
    }

    private func labelForIndex(_ idx: Double) -> String? {
        let rounded = Int(idx.rounded())
        guard candles.indices.contains(rounded) else { return nil }
        return Self.axisFormatter.string(from: candles[rounded].bucketStart)
    }

    static let axisFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d HH:mm"
        return f
    }()

    private func yAxis() -> some AxisContent {
        AxisMarks(position: .trailing, values: .automatic(desiredCount: 6)) { value in
            AxisGridLine().foregroundStyle(Color.white.opacity(0.04))
            AxisValueLabel {
                if let d = value.as(Double.self) {
                    Text(Self.priceShort(d))
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(Theme.Color.textMuted)
                }
            }
        }
    }

    // MARK: - Hover tooltip

    @ViewBuilder
    private var hoverTooltip: some View {
        if let h = hovered {
            let c = h.candle
            let delta = c.close - c.open
            let pct = c.open > 0 ? (delta / c.open) * 100 : 0
            let isUp = c.close >= c.open

            VStack(alignment: .leading, spacing: 4) {
                Text(Self.dateFormatter.string(from: c.bucketStart))
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.Color.textMuted)
                HStack(spacing: 12) {
                    ohlcCell("O", c.open)
                    ohlcCell("H", c.high)
                    ohlcCell("L", c.low)
                    ohlcCell("C", c.close)
                }
                HStack(spacing: 4) {
                    Image(systemName: isUp ? "arrow.up.right" : "arrow.down.right")
                        .font(.system(size: 9, weight: .bold))
                    Text("\(isUp ? "+" : "")\(Self.priceShort(delta)) (\(String(format: "%+.2f", pct))%)")
                        .font(.system(size: 10, weight: .semibold).monospacedDigit())
                }
                .foregroundStyle(isUp ? Theme.Color.success : Theme.Color.danger)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Theme.Color.surfaceMax.opacity(0.96))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(Theme.Color.border, lineWidth: 1)
                    )
            )
            .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
            .padding(12)
            .transition(.opacity.animation(.easeOut(duration: 0.1)))
        }
    }

    private func ohlcCell(_ label: String, _ v: Double) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(label)
                .font(.system(size: 8, weight: .bold))
                .foregroundStyle(Theme.Color.textMuted)
            Text(Self.priceExact(v))
                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                .foregroundStyle(Theme.Color.textPrimary)
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: Theme.Spacing.sm) {
            Image(systemName: "chart.xyaxis.line")
                .font(.system(size: 40))
                .foregroundStyle(Theme.Color.textMuted)
            Text("No data for this timeframe")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Theme.Color.textSecondary)
            Text("Wait for the next fetch cycle.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.Color.textMuted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 320)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Y domain

    private var effectiveYDomain: ClosedRange<Double> {
        yDomain ?? autoYDomain
    }

    private var autoYDomain: ClosedRange<Double> {
        // Bind the (memoized) display candles once — this runs every
        // horizontal-pan frame, and each `displayCandles` access re-enters
        // the cache lookup.
        let cs = displayCandles
        let bounds = ChartWindow.visibleBounds(domain: effectiveXDomain, count: cs.count)
        let visibleCandles: ArraySlice<Candle>
        if let b = bounds {
            visibleCandles = cs[b.lo ... b.hi]
        } else {
            visibleCandles = cs[...]
        }
        // Single pass for the low/high extremes instead of two throwaway
        // `.map` arrays per frame.
        var lo = Double.greatestFiniteMagnitude
        var hi = -Double.greatestFiniteMagnitude
        for c in visibleCandles {
            if c.low  < lo { lo = c.low }
            if c.high > hi { hi = c.high }
        }
        if visibleCandles.isEmpty { lo = 0; hi = 1 }

        if !indicators.isEmpty, let b = bounds {
            let instances = indicators.map { Self.makeIndicatorInstance(kind: $0, config: indicatorConfig) }
            for entry in derived.indicators(instances: instances, candles: candles) {
                for p in entry.points where p.index >= b.lo && p.index <= b.hi {
                    if p.value < lo { lo = p.value }
                    if p.value > hi { hi = p.value }
                }
            }
        }

        if indicatorConfig.utShowTrailingStop,
           indicators.contains(.utBot),
           let b = bounds,
           let stops = utBotOutput?.trailingStop {
            for i in b.lo ... b.hi where i < stops.count {
                guard let v = stops[i] else { continue }
                if v < lo { lo = v }
                if v > hi { hi = v }
            }
        }

        // Overlay Y extremes — cached via ChartDerivedCache. The
        // overlay data (S/R levels, FVG zones, order blocks, drawings,
        // trades, etc.) rarely changes during pan/zoom, so the
        // signature check yields a synchronous cache hit on every
        // gesture frame. Only the candle-window scan above is uncached
        // (it depends on the visible xDomain).
        let instances = indicators.map { Self.makeIndicatorInstance(kind: $0, config: indicatorConfig) }
        let overlayData = ChartDerivedCache.OverlayData(
            candles: candles,
            indicatorInstances: instances,
            indicatorConfig: indicatorConfig,
            indicators: indicators,
            srLevels: srLevels,
            fvgZones: fvgZones,
            supplyDemandZones: supplyDemandZones,
            indicatorFvgZones: indicatorFvgZones,
            orderBlockZones: orderBlockZones,
            steroidOrderBlockZones: steroidOrderBlockZones,
            sonarlabOBZones: sonarlabOBZones,
            // Ichimoku is not wired into the iPad chart yet (Mac-only
            // for now) — empty values keep the yDomain scan correct.
            ichimokuOutput: .empty,
            ichimokuOBZones: [],
            rankedOBZones: rankedOBZones,
            volumeFilteredOBZones: volumeFilteredOBZones,
            chochZones: chochZones,
            htfChochZones: htfChochZones,
            sessionRuns: sessionRuns,
            nySetupResults: nySetupResults,
            sp2lResults: sp2lResults,
            pinBarComboResults: pinBarComboResults,
            microMapResults: microMapResults,
            mtrResults: mtrResults,
            volumeProfileSessions: volumeProfileSessions,
            zigzagTrendVP: zigzagTrendVP,
            visibleRangeVP: visibleRangeVP,
            zigzagPivots: zigzagPivots,
            taScenario: taScenario,
            taAltScenario: taAltScenario,
            drawings: drawings,
            trades: trades,
            journalEntries: journalEntries
        )
        let overlayExtremes = derived.overlayExtremes(overlayData)
        if overlayExtremes.lo < lo { lo = overlayExtremes.lo }
        if overlayExtremes.hi > hi { hi = overlayExtremes.hi }

        guard visibleCandles.isEmpty == false else { return 0...1 }
        let span = hi - lo
        if span <= 0 || visibleCandles.count == 1 {
            let pad = max(hi * 0.005, 1)
            return (lo - pad)...(hi + pad)
        }
        let pad = span * 0.05
        return (lo - pad)...(hi + pad)
    }

    // MARK: - Candle body width

    private var candleBodyWidth: CGFloat {
        let span = effectiveXDomain.upperBound - effectiveXDomain.lowerBound
        let visible = max(1, Int(span.rounded()))
        switch visible {
        case 0...3:    return 28
        case 4...10:   return 18
        case 11...30:  return 11
        case 31...80:  return 7
        case 81...200: return 4
        default:       return 2
        }
    }

    // MARK: - Drawing helpers

    private func barIndex(forDate date: Date) -> Double? {
        guard !candles.isEmpty else { return nil }
        let ts = date.timeIntervalSince1970
        // Mirror of `drawingPoint`: dates outside the series resolve to a
        // fractional index off the end rather than snapping to the edge
        // bar, so drawings placed ahead of price stay put.
        if let step = barIntervalSeconds {
            let lastTS = candles[candles.count - 1].bucketStart.timeIntervalSince1970
            if ts > lastTS {
                return Double(candles.count - 1) + (ts - lastTS) / step
            }
            let firstTS = candles[0].bucketStart.timeIntervalSince1970
            if ts < firstTS {
                return (ts - firstTS) / step
            }
        }
        var lo = 0
        var hi = candles.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if candles[mid].bucketStart.timeIntervalSince1970 < ts {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        if lo > 0 {
            let dLo = abs(candles[lo].bucketStart.timeIntervalSince(date))
            let dPrev = abs(candles[lo - 1].bucketStart.timeIntervalSince(date))
            if dPrev < dLo { return Double(lo - 1) }
        }
        return Double(lo)
    }

    private func barIndex(closestTo date: Date) -> Int? {
        guard !candles.isEmpty else { return nil }
        let ts = date.timeIntervalSince1970
        var lo = 0
        var hi = candles.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if candles[mid].bucketStart.timeIntervalSince1970 < ts {
                lo = mid + 1
            } else {
                hi = mid
            }
        }
        if lo > 0 {
            let dLo = abs(candles[lo].bucketStart.timeIntervalSince(date))
            let dPrev = abs(candles[lo - 1].bucketStart.timeIntervalSince(date))
            if dPrev < dLo { return lo - 1 }
        }
        return lo
    }

    private func barIndexForEntryPrice(_ price: Double, before fromIndex: Int) -> Int? {
        guard fromIndex >= 0, fromIndex < candles.count else { return nil }
        for i in stride(from: fromIndex, through: 0, by: -1) {
            let c = candles[i]
            if price >= c.low && price <= c.high { return i }
        }
        return nil
    }

    /// Mutates a copy so non-geometry fields (colour, line width, a
    /// position's risk settings) survive the move — rebuilding from
    /// scratch used to reset them.
    private func translated(_ d: ChartDrawing) -> ChartDrawing {
        var copy = d
        copy.start = DrawingPoint(
            date: d.start.date.addingTimeInterval(movingDeltaTime),
            price: d.start.price + movingDeltaPrice
        )
        copy.end = d.end.map { e in
            DrawingPoint(
                date: e.date.addingTimeInterval(movingDeltaTime),
                price: e.price + movingDeltaPrice
            )
        }
        // Stop/target are absolute prices, so they must travel with the
        // entry or a drag would reshape the trade instead of moving it.
        if d.kind.isPosition {
            copy.stopPrice   = d.stopPrice.map   { $0 + movingDeltaPrice }
            copy.targetPrice = d.targetPrice.map { $0 + movingDeltaPrice }
        }
        return copy
    }

    // MARK: - Drawing hit-testing (touch)

    /// Handle grab points for a drawing, paired positionally with
    /// `handleAnchors(for:)`.
    private func handlePositions(for d: ChartDrawing) -> [HandlePoint] {
        switch d.kind {
        case .horizontalLine:
            return [HandlePoint(x: effectiveXDomain.upperBound - 0.5, y: d.start.price)]
        case .trendLine:
            guard let end = d.end,
                  let xs = barIndex(forDate: d.start.date),
                  let xe = barIndex(forDate: end.date) else { return [] }
            return [HandlePoint(x: xs, y: d.start.price), HandlePoint(x: xe, y: end.price)]
        case .rectangle, .volumeProfile:
            guard let end = d.end,
                  let xs = barIndex(forDate: d.start.date),
                  let xe = barIndex(forDate: end.date) else { return [] }
            return [
                HandlePoint(x: xs, y: d.start.price),
                HandlePoint(x: xe, y: d.start.price),
                HandlePoint(x: xs, y: end.price),
                HandlePoint(x: xe, y: end.price)
            ]
        case .longPosition, .shortPosition:
            guard let end = d.end,
                  let xs = barIndex(forDate: d.start.date),
                  let xe = barIndex(forDate: end.date) else { return [] }
            var pts = [HandlePoint(x: xs, y: d.start.price)]
            if let stop = d.stopPrice     { pts.append(HandlePoint(x: xs, y: stop)) }
            if let target = d.targetPrice { pts.append(HandlePoint(x: xs, y: target)) }
            pts.append(HandlePoint(x: xe, y: d.start.price))
            return pts
        }
    }

    /// Must stay positionally in step with `handlePositions(for:)` —
    /// the two are zipped, so conditional handles need conditional
    /// anchors or a missing stop maps the target handle onto `.stop`.
    private func handleAnchors(for d: ChartDrawing) -> [ChartDrawing.Handle] {
        switch d.kind {
        case .horizontalLine: return [.start]
        case .trendLine:      return [.start, .end]
        case .rectangle, .volumeProfile:
            return [.topLeft, .topRight, .bottomLeft, .bottomRight]
        case .longPosition, .shortPosition:
            var anchors: [ChartDrawing.Handle] = [.entry]
            if d.stopPrice != nil   { anchors.append(.stop) }
            if d.targetPrice != nil { anchors.append(.target) }
            anchors.append(.timeEnd)
            return anchors
        }
    }

    /// Touch targets are bigger than cursor targets — 22pt vs the Mac
    /// build's 10pt, roughly a fingertip.
    private func hitTestHandle(
        of d: ChartDrawing,
        at location: CGPoint,
        plotOrigin: CGPoint,
        proxy: ChartProxy,
        threshold: CGFloat = 22
    ) -> ChartDrawing.Handle? {
        let p = CGPoint(x: location.x - plotOrigin.x, y: location.y - plotOrigin.y)
        for (hp, anchor) in zip(handlePositions(for: d), handleAnchors(for: d)) {
            guard let hx: CGFloat = proxy.position(forX: hp.x),
                  let hy: CGFloat = proxy.position(forY: hp.y) else { continue }
            if hypot(p.x - hx, p.y - hy) <= threshold { return anchor }
        }
        return nil
    }

    private func hitTestDrawing(
        at location: CGPoint,
        plotOrigin: CGPoint,
        proxy: ChartProxy,
        threshold: CGFloat = 16
    ) -> ChartDrawing? {
        let p = CGPoint(x: location.x - plotOrigin.x, y: location.y - plotOrigin.y)
        var best: (ChartDrawing, CGFloat)?
        for d in drawings where d.visible {
            guard let dist = drawingDistance(d, at: p, proxy: proxy) else { continue }
            if dist <= threshold, best == nil || dist < best!.1 { best = (d, dist) }
        }
        return best?.0
    }

    private func drawingDistance(
        _ d: ChartDrawing,
        at p: CGPoint,
        proxy: ChartProxy
    ) -> CGFloat? {
        switch d.kind {
        case .horizontalLine:
            guard let lineY = proxy.position(forY: d.start.price) else { return nil }
            return Swift.abs(p.y - lineY)
        case .trendLine:
            guard let end = d.end,
                  let xs = barIndex(forDate: d.start.date),
                  let xe = barIndex(forDate: end.date),
                  let xsS: CGFloat = proxy.position(forX: xs),
                  let xeS: CGFloat = proxy.position(forX: xe),
                  let ysS = proxy.position(forY: d.start.price),
                  let yeS = proxy.position(forY: end.price) else { return nil }
            return Self.distanceToSegment(p, CGPoint(x: xsS, y: ysS), CGPoint(x: xeS, y: yeS))
        case .rectangle, .volumeProfile:
            guard let end = d.end,
                  let xs = barIndex(forDate: d.start.date),
                  let xe = barIndex(forDate: end.date),
                  let xsS: CGFloat = proxy.position(forX: xs),
                  let xeS: CGFloat = proxy.position(forX: xe),
                  let ysS = proxy.position(forY: d.start.price),
                  let yeS = proxy.position(forY: end.price) else { return nil }
            return Self.distanceToRect(p, xsS, xeS, ysS, yeS)
        case .longPosition, .shortPosition:
            // Whole box is grabbable: stop edge to target edge.
            guard let end = d.end,
                  let xs = barIndex(forDate: d.start.date),
                  let xe = barIndex(forDate: end.date),
                  let xsS: CGFloat = proxy.position(forX: xs),
                  let xeS: CGFloat = proxy.position(forX: xe) else { return nil }
            let levels = [d.start.price, d.stopPrice, d.targetPrice].compactMap { $0 }
            guard let lo = levels.min(), let hi = levels.max(),
                  let loS = proxy.position(forY: lo),
                  let hiS = proxy.position(forY: hi) else { return nil }
            return Self.distanceToRect(p, xsS, xeS, loS, hiS)
        }
    }

    private static func distanceToRect(
        _ p: CGPoint, _ x0: CGFloat, _ x1: CGFloat, _ y0: CGFloat, _ y1: CGFloat
    ) -> CGFloat {
        let rect = CGRect(
            x: min(x0, x1), y: min(y0, y1),
            width: Swift.abs(x1 - x0), height: Swift.abs(y1 - y0)
        )
        if rect.contains(p) { return 0 }
        let dx = max(rect.minX - p.x, 0, p.x - rect.maxX)
        let dy = max(rect.minY - p.y, 0, p.y - rect.maxY)
        return hypot(dx, dy)
    }

    private static func distanceToSegment(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len2 = dx * dx + dy * dy
        if len2 == 0 { return hypot(p.x - a.x, p.y - a.y) }
        let t = max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2))
        return hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy))
    }

    /// Commit an in-flight handle drag.
    private func handleResizeEnd() {
        defer {
            editingDrawingID = nil
            editingHandle = nil
            editingCursor = nil
        }
        guard let id = editingDrawingID,
              let original = drawings.first(where: { $0.id == id }),
              let anchor = editingHandle,
              let cursor = editingCursor else { return }
        let resized = original.resized(anchor: anchor, to: cursor)
        if resized == original { return }
        onMoveDrawing?(resized)
    }

    /// Commit an in-flight body drag.
    private func handleMoveEnd() {
        defer {
            movingDrawingOriginal = nil
            movingDeltaTime = 0
            movingDeltaPrice = 0
        }
        guard let original = movingDrawingOriginal else { return }
        if movingDeltaTime == 0 && movingDeltaPrice == 0 { return }
        onMoveDrawing?(translated(original))
    }

    // MARK: - Formatting

    static func priceShort(_ v: Double) -> String {
        let abs = Swift.abs(v)
        if abs >= 1_000_000_000 { return String(format: "%.2fB", v / 1_000_000_000) }
        if abs >= 1_000_000     { return String(format: "%.2fM", v / 1_000_000) }
        if abs >= 10_000        { return String(format: "%.0fK", v / 1_000) }
        if abs >= 100           { return v.formatted(.number.precision(.fractionLength(0))) }
        if abs >= 1             { return v.formatted(.number.precision(.fractionLength(2))) }
        return String(format: "%.4f", v)
    }

    static func priceExact(_ v: Double) -> String {
        let abs = Swift.abs(v)
        let digits: Int
        if abs >= 1_000_000 { digits = 0 }
        else if abs >= 100  { digits = 2 }
        else if abs >= 1    { digits = 4 }
        else                { digits = 5 }
        return v.formatted(.number.precision(.fractionLength(digits)))
    }

    static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMM d · HH:mm"
        return f
    }()
}

// MARK: - Equatable (re-render isolation)

/// Mirrors the macOS `ChartView` perf treatment. The iPad chart is just as
/// expensive (Apple Charts re-lays out its whole mark tree on every body
/// evaluation) and is re-evaluated far more often than its *drawn* inputs
/// change: every `YahooScheduler` `objectWillChange` (~1 Hz live ticks,
/// plus every unrelated `@Published` field) invalidates the owning
/// `ChartPlotiPad` and cascades a full re-eval — the Charts layout pass —
/// down into here even when nothing moved. That constant relayout was the
/// dominant driver of the "High" energy impact on device.
///
/// Conforming to `Equatable` + wrapping the call site in `.equatable()`
/// lets SwiftUI skip re-invoking `body` when no render-affecting input
/// changed. Closures (`onCommitDrawing`, …) and internal `@State` (hover,
/// in-flight drawing, crosshair) are deliberately excluded: closures don't
/// affect what's drawn, and self-`@State` changes bypass this gate anyway
/// (crosshair + live drawing previews still redraw normally). The candle
/// series compares via `Candle.seriesEqual` (O(1)) so the hot pan/zoom
/// path — which changes `xDomain` and legitimately forces a redraw — stays
/// cheap on years of history.
extension ChartViewiPad: Equatable {
    static func == (l: ChartViewiPad, r: ChartViewiPad) -> Bool {
        Candle.seriesEqual(l.candles, r.candles)
            && l.chartType == r.chartType
            && l.accent == r.accent
            && l.xDomain == r.xDomain
            && l.yDomain == r.yDomain
            && l.indicators == r.indicators
            && l.indicatorConfig == r.indicatorConfig
            && l.htfChochZones == r.htfChochZones
            && l.srLevels == r.srLevels
            && l.fvgZones == r.fvgZones
            && l.supplyDemandZones == r.supplyDemandZones
            && l.taScenario == r.taScenario
            && l.taAltScenario == r.taAltScenario
            && l.drawings == r.drawings
            && l.activeTool == r.activeTool
            && l.selectedDrawingID == r.selectedDrawingID
            && l.trades == r.trades
            && l.journalEntries == r.journalEntries
            && l.livePrice == r.livePrice
            && l.replayActive == r.replayActive
            && Self.newsEqual(l.newsEvents, r.newsEvents)
            && l.newsTimeZone == r.newsTimeZone
    }

    /// Same cheap news-list compare as the Mac chart: ids in order +
    /// `actual` values, so live actuals refresh the popover without a
    /// full event compare on every tick.
    private static func newsEqual(_ a: [ForexFactoryEvent], _ b: [ForexFactoryEvent]) -> Bool {
        guard a.count == b.count else { return false }
        for i in a.indices where a[i].id != b[i].id || a[i].actual != b[i].actual {
            return false
        }
        return true
    }
}
