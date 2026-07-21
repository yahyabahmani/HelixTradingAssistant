import SwiftUI

/// Settings page — macOS System Settings-style two-column layout:
/// a left rail of category buttons plus the selected category's
/// cards on the right. Every wizard-collected value is also
/// editable here, plus everything that was only ever in settings
/// (markets toggles, Claude model + effort, SOCKS5 proxy,
/// bridge).
struct SettingsView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var notificationInbox: NotificationInbox

    // ── State ─────────────────────────────────────────────────────

    /// Source of truth lifted to `AppState.settingsCategory` so
    /// the dashboard's auto-trader gear button can deep-link
    /// into a specific category (e.g. jump straight to
    /// Auto-trader with the current symbol's row expanded).
    /// Sidebar clicks below set it through the same path.
    private var selectedSettingsCategory: SettingsCategory {
        get { app.settingsCategory }
        nonmutating set { app.settingsCategory = newValue }
    }

    @State private var proxy: ProxyConfig = ProxyConfig.load()
    @State private var proxyDirty = false
    @State private var proxyTestState: TestState = .idle

    enum TestState { case idle, working, ok, failed(String) }

    // Markets — toggles read by the sidebar's pair filter.
    @AppStorage("markets.forex.enabled")   private var forexEnabled: Bool = true
    @AppStorage("markets.crypto.enabled")  private var cryptoEnabled: Bool = true
    @AppStorage("markets.indices.enabled") private var indicesEnabled: Bool = true

    // Strategy formation alerts. DashboardView reads the same key and
    // suppresses both inbox records and macOS banners when disabled.
    @AppStorage("notifications.strategySignals.enabled")
    private var strategyNotificationsEnabled: Bool = true

    // Codex model + effort. Mirrors the Claude keys; read by
    // CodexEngine at run time. Defaults match the user's frontier
    // Codex model + a high reasoning effort.
    @AppStorage("ai.codex.model")  private var codexModel: String = "gpt-5.5"
    @AppStorage("ai.codex.effort") private var codexEffort: String = "high"

    // OpenCode model. Read by OpenCodeEngine at run time.
    @AppStorage("ai.opencode.model") private var opencodeModel: String = OpenCodeModelCatalog.defaultModelID

    // OpenCode API key — loaded from / saved to Keychain.
    // Initialized empty; loaded once in .onAppear to avoid
    // triggering a keychain password prompt on every SwiftUI
    // body re-evaluation. (Keychain prompt fix.)
    @State private var opencodeAPIKey: String = ""
    @State private var opencodeAPIKeyDirty: Bool = false

    // OpenCode remote server settings.
    @AppStorage("ai.opencode.useRemote") private var opencodeUseRemote: Bool = false
    @AppStorage("ai.opencode.serverURL") private var opencodeServerURL: String = ""
    @State private var opencodeServerPassword: String = ""
    @State private var opencodeServerPasswordDirty: Bool = false
    @State private var opencodeServerTestState: TestState = .idle

    // Token usage counters (rolled per-render).
    @AppStorage("ai.claude.tokens.today")   private var tokensToday: Int = 0
    @AppStorage("ai.claude.tokens.week")    private var tokensWeek: Int = 0
    @AppStorage("ai.claude.tokens.dayKey")  private var tokensDayKey: String = ""
    @AppStorage("ai.claude.tokens.weekKey") private var tokensWeekKey: String = ""

    // ── Layout ────────────────────────────────────────────────────

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider().background(Theme.Color.border)
            content
        }
        .background(Theme.Color.canvas)
        .onAppear {
            notificationInbox.refreshSystemNotificationPermission()
            // Load keychain values once on first appear, not in
            // @State initializers (which re-run on every SwiftUI
            // body re-evaluation and trigger password prompts).
            if opencodeAPIKey.isEmpty {
                opencodeAPIKey = KeychainHelper.get(.opencodeAPIKey) ?? ""
            }
            if opencodeServerPassword.isEmpty {
                opencodeServerPassword = KeychainHelper.get(.opencodeServerPass) ?? ""
            }
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            sidebarHeader
            Divider().background(Theme.Color.border)
                .padding(.vertical, Theme.Spacing.sm)
            ForEach(SettingsCategory.allCases) { cat in
                categoryRow(cat)
            }
            Spacer()
        }
        .padding(.horizontal, Theme.Spacing.sm)
        .padding(.vertical, Theme.Spacing.md)
        .frame(width: 220)
        .background(Theme.Color.surface)
    }

    private var sidebarHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Settings")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(Theme.Color.textPrimary)
            Text("Configure data sources, AI, and network.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.Color.textSecondary)
        }
        .padding(.horizontal, Theme.Spacing.md)
        .padding(.top, Theme.Spacing.sm)
    }

    private func categoryRow(_ cat: SettingsCategory) -> some View {
        let isSelected = selectedSettingsCategory == cat
        return Button {
            selectedSettingsCategory = cat
        } label: {
            HStack(spacing: Theme.Spacing.md) {
                Image(systemName: cat.symbol)
                    .font(.system(size: 13, weight: isSelected ? .semibold : .regular))
                    .frame(width: 20)
                Text(cat.label)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .medium))
                Spacer()
            }
            .foregroundStyle(isSelected ? Theme.Color.textPrimary : Theme.Color.textSecondary)
            .padding(.horizontal, Theme.Spacing.md)
            .padding(.vertical, 7)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.md, style: .continuous)
                    .fill(isSelected ? Theme.Color.surfaceHi : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                contentHeader
                contentBody
            }
            .padding(Theme.Spacing.xl)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private var contentHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: selectedSettingsCategory.symbol)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.accentGradient)
                Text(selectedSettingsCategory.label)
                    .font(.system(size: 22, weight: .bold))
                    .foregroundStyle(Theme.Color.textPrimary)
            }
            Text(selectedSettingsCategory.blurb)
                .font(.system(size: 12))
                .foregroundStyle(Theme.Color.textSecondary)
        }
        .padding(.bottom, Theme.Spacing.sm)
    }

    @ViewBuilder
    private var contentBody: some View {
        switch selectedSettingsCategory {
        case .general:    generalSection
        case .notifications: notificationsSection
        case .data:       DataSourcesCard()
        case .ai:         aiSection
        case .network:    proxyCard
        case .autoTrader: AutoTraderCard()
        case .about:      UpdatesCard()
        }
    }

    // ── General section ───────────────────────────────────────────

    private var generalSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            wizardCard
            marketsCard
        }
    }

    // ── Notifications section ─────────────────────────────────────

    private var notificationsSection: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                sectionTitle(
                    icon: "point.3.connected.trianglepath.dotted",
                    title: "Strategy signals",
                    subtitle: "The eye icon on each chart layer controls its alerts. This switch silences or enables all strategy notifications."
                )

                Toggle(isOn: $strategyNotificationsEnabled) {
                    HStack(spacing: Theme.Spacing.sm) {
                        Image(systemName: "bell.and.waves.left.and.right.fill")
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Theme.Color.textSecondary)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Strategy formation notifications")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Theme.Color.textPrimary)
                            Text("Visible SP2L, Pin Bar, BTB, MicroMap, MTR and CHoCH layers")
                                .font(.system(size: 11))
                                .foregroundStyle(Theme.Color.textMuted)
                        }
                    }
                }
                .toggleStyle(.switch)
                .tint(Theme.Color.accentStart)

                if notificationInbox.systemPermissionChecked {
                    Label(
                        notificationInbox.systemPermissionGranted
                            ? "macOS notification permission is enabled"
                            : "macOS notification permission is disabled in System Settings",
                        systemImage: notificationInbox.systemPermissionGranted
                            ? "checkmark.circle.fill"
                            : "exclamationmark.triangle.fill"
                    )
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(
                        notificationInbox.systemPermissionGranted
                            ? Theme.Color.success
                            : Theme.Color.accentStart
                    )
                }
            }
        }
    }

    private var wizardCard: some View {
        Card {
            HStack(spacing: Theme.Spacing.md) {
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Theme.accentGradient)
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Setup wizard")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Theme.Color.textPrimary)
                    Text("Re-run the first-launch flow to re-detect Claude or swap your Twelve Data key.")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Color.textSecondary)
                }
                Spacer()
                SecondaryButton(title: "Re-run") {
                    app.showWizard = true
                }
            }
        }
    }

    private var marketsCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                sectionTitle(
                    icon: "square.grid.2x2",
                    title: "Markets",
                    subtitle: "Toggle which categories appear in the sidebar. Off markets stay in the catalog — re-enabling restores them immediately."
                )

                Toggle(isOn: $forexEnabled) {
                    marketRow(
                        symbol: "dollarsign.circle.fill",
                        title: "Forex",
                        subtitle: "XAU/USD ounce via Yahoo / Twelve Data"
                    )
                }
                .toggleStyle(.switch)
                .tint(Theme.Color.accentStart)

                Toggle(isOn: $cryptoEnabled) {
                    marketRow(
                        symbol: "bitcoinsign.circle.fill",
                        title: "Crypto",
                        subtitle: "BTC / SOL / ETH via Twelve Data"
                    )
                }
                .toggleStyle(.switch)
                .tint(Theme.Color.accentStart)

                Toggle(isOn: $indicesEnabled) {
                    marketRow(
                        symbol: "chart.line.uptrend.xyaxis",
                        title: "Indices",
                        subtitle: "Dow Jones (DJI) via Yahoo polling — 15m delayed; DXY via Faraz"
                    )
                }
                .toggleStyle(.switch)
                .tint(Theme.Color.accentStart)
            }
        }
    }

    private func marketRow(symbol: String, title: String, subtitle: String) -> some View {
        HStack(spacing: Theme.Spacing.sm) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Theme.Color.textSecondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.Color.textPrimary)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Color.textMuted)
            }
        }
    }

    // ── AI section (Claude + Codex) ───────────────────────────────

    /// Both engine cards stacked. The analysis page's engine picker
    /// chooses which one runs; these cards configure each.
    private var aiSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            claudeCard
            codexCard
            opencodeCard
        }
    }

    // ── Codex card ────────────────────────────────────────────────

    private var codexCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                sectionTitle(
                    icon: "chevron.left.forwardslash.chevron.right",
                    title: "Codex (AI analysis)",
                    subtitle: "Model + reasoning effort for the Codex CLI engine. Uses your local `codex` login — no API key. Pick Codex in the engine selector on the analysis page."
                )

                if !codexInstalled {
                    Label("Codex CLI not found on this machine. Install with `npm i -g @openai/codex` (or `brew install codex`), then restart.",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.Color.warn)
                        .fixedSize(horizontal: false, vertical: true)
                }

                codexModelPicker
                codexEffortPicker
            }
        }
    }

    // ── OpenCode card ─────────────────────────────────────────────

    private var opencodeCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                sectionTitle(
                    icon: "terminal.fill",
                    title: "OpenCode (AI analysis)",
                    subtitle: "Free models included via OpenCode Zen, or bring your own provider keys. Pick OpenCode in the engine selector on the analysis page."
                )

                opencodeRemoteToggle

                if opencodeUseRemote {
                    opencodeRemoteServerSection
                } else {
                    if !opencodeInstalled {
                        Label("OpenCode CLI not found. Install with `curl -fsSL https://opencode.ai/install | bash`, then restart.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Theme.Color.warn)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    opencodeAPIKeySection
                }

                opencodeModelPicker
                opencodeUsageSection
            }
        }
    }

    private var opencodeInstalled: Bool { OpenCodeEngine.locateBinary() != nil }

    private var opencodeRemoteToggle: some View {
        Toggle(isOn: $opencodeUseRemote) {
            HStack(spacing: Theme.Spacing.sm) {
                Image(systemName: "network")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.Color.textSecondary)
                    .frame(width: 18)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Use Remote Server")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.Color.textPrimary)
                    Text("Connect to a remote OpenCode server instead of the local CLI")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.Color.textMuted)
                }
            }
        }
        .toggleStyle(.switch)
        .tint(Theme.Color.accentStart)
    }

    private var opencodeRemoteServerSection: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            // Server URL
            VStack(alignment: .leading, spacing: 6) {
                Text("SERVER URL")
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(Theme.Color.textMuted)
                HStack(spacing: Theme.Spacing.sm) {
                    TextField("http://your-vps-ip:4096", text: $opencodeServerURL)
                        .textFieldStyle(.plain)
                        .padding(Theme.Spacing.sm)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.Radius.sm)
                                .fill(Theme.Color.surface)
                        )
                        .foregroundStyle(Theme.Color.textPrimary)
                        .font(.system(size: 12, design: .monospaced))
                    Button {
                        testRemoteServer()
                    } label: {
                        if case .working = opencodeServerTestState {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Text("Test")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Theme.Color.accentStart)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 6)
                                .background(
                                    RoundedRectangle(cornerRadius: 6)
                                        .fill(Theme.Color.surface)
                                )
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(opencodeServerURL.isEmpty)
                }
                if case .ok = opencodeServerTestState {
                    Label("Connected successfully", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.Color.success)
                }
                if case .failed(let msg) = opencodeServerTestState {
                    Label(msg, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.Color.danger)
                        .lineLimit(2)
                }
                Text("Run `opencode serve --port 4096 --hostname 0.0.0.0` on your VPS to start the server.")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.Color.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Server Password
            VStack(alignment: .leading, spacing: 6) {
                Text("SERVER PASSWORD")
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(Theme.Color.textMuted)
                HStack(spacing: Theme.Spacing.sm) {
                    SecureField("Optional password (OPENCODE_SERVER_PASSWORD)", text: $opencodeServerPassword)
                        .textFieldStyle(.plain)
                        .padding(Theme.Spacing.sm)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.Radius.sm)
                                .fill(Theme.Color.surface)
                        )
                        .foregroundStyle(Theme.Color.textPrimary)
                        .font(.system(size: 12, design: .monospaced))
                        .onChange(of: opencodeServerPassword) { _ in opencodeServerPasswordDirty = true }
                    Button {
                        let pass = opencodeServerPassword.trimmingCharacters(in: .whitespacesAndNewlines)
                        KeychainHelper.set(.opencodeServerPass, pass)
                        opencodeServerPasswordDirty = false
                    } label: {
                        Text(opencodeServerPasswordDirty ? "Save" : "Saved")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(opencodeServerPasswordDirty ? .white : Theme.Color.textSecondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(opencodeServerPasswordDirty
                                          ? AnyShapeStyle(Theme.accentGradient)
                                          : AnyShapeStyle(Theme.Color.surface))
                            )
                    }
                    .buttonStyle(.plain)
                }
                Text("Set `OPENCODE_SERVER_PASSWORD` on the server for secure connections. Username defaults to `opencode`.")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.Color.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func testRemoteServer() {
        guard let serverURL = URL(string: opencodeServerURL) else {
            opencodeServerTestState = .failed("Invalid URL")
            return
        }

        opencodeServerTestState = .working
        Task {
            do {
                let healthURL = serverURL.appendingPathComponent("global/health")
                var request = URLRequest(url: healthURL)
                request.timeoutInterval = 10

                // Add basic auth if password is set
                let password = opencodeServerPassword.trimmingCharacters(in: .whitespacesAndNewlines)
                if !password.isEmpty {
                    let credentials = "opencode:\(password)"
                    let base64 = Data(credentials.utf8).base64EncodedString()
                    request.setValue("Basic \(base64)", forHTTPHeaderField: "Authorization")
                }

                let (data, response) = try await URLSession.shared.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    await MainActor.run { opencodeServerTestState = .failed("Invalid response") }
                    return
                }

                if http.statusCode == 200 {
                    await MainActor.run { opencodeServerTestState = .ok }
                } else if http.statusCode == 401 {
                    await MainActor.run { opencodeServerTestState = .failed("Authentication failed. Check password.") }
                } else {
                    await MainActor.run { opencodeServerTestState = .failed("Server returned \(http.statusCode)") }
                }
            } catch {
                await MainActor.run {
                    opencodeServerTestState = .failed("Connection failed: \(error.localizedDescription)")
                }
            }
        }
    }

    private var opencodeAPIKeySection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("API KEY")
                .font(.system(size: 9, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(Theme.Color.textMuted)
            HStack(spacing: Theme.Spacing.sm) {
                TextField("sk-… or paste from opencode.ai/auth", text: $opencodeAPIKey)
                    .textFieldStyle(.plain)
                    .padding(Theme.Spacing.sm)
                    .background(
                        RoundedRectangle(cornerRadius: Theme.Radius.sm)
                            .fill(Theme.Color.surface)
                    )
                    .foregroundStyle(Theme.Color.textPrimary)
                    .font(.system(size: 12, design: .monospaced))
                    .onChange(of: opencodeAPIKey) { _ in opencodeAPIKeyDirty = true }
                Button {
                    let key = opencodeAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
                    KeychainHelper.set(.opencodeAPIKey, key)
                    opencodeAPIKeyDirty = false
                } label: {
                    Text(opencodeAPIKeyDirty ? "Save" : "Saved")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(opencodeAPIKeyDirty ? .white : Theme.Color.textSecondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(opencodeAPIKeyDirty
                                      ? AnyShapeStyle(Theme.accentGradient)
                                      : AnyShapeStyle(Theme.Color.surface))
                        )
                }
                .buttonStyle(.plain)
            }
            Text("Get your key at opencode.ai/auth. Free models work without a key if you've run `opencode auth login` in your terminal.")
                .font(.system(size: 10))
                .foregroundStyle(Theme.Color.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var opencodeModelPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("MODEL")
                .font(.system(size: 9, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(Theme.Color.textMuted)
            Picker("", selection: $opencodeModel) {
                Section("FREE") {
                    ForEach(OpenCodeModelCatalog.freeModels) { m in
                        Text(m.label).tag(m.id)
                    }
                }
                ForEach(OpenCodeModelCatalog.providerOrder, id: \.self) { provider in
                    if let group = OpenCodeModelCatalog.paidModelsByProvider.first(where: { $0.provider == provider }) {
                        Section(provider) {
                            ForEach(group.models) { m in
                                Text(m.label).tag(m.id)
                            }
                        }
                    }
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: 320, alignment: .leading)

            if let model = OpenCodeModelCatalog.allModels.first(where: { $0.id == opencodeModel }) {
                Text(model.hint)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.Color.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var opencodeUsageSection: some View {
        let _ = rollOpenCodeUsageWindows()
        return VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("USAGE")
                .font(.system(size: 9, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(Theme.Color.textMuted)
            HStack(spacing: Theme.Spacing.xl) {
                usageStat(label: "Today",     value: formatTokens(opencodeTokensToday))
                usageStat(label: "This week", value: formatTokens(opencodeTokensWeek))
            }
            HStack {
                Button {
                    if let url = URL(string: "https://opencode.ai/auth") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label("Open OpenCode billing", systemImage: "arrow.up.right.square")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.Color.accentStart)
                }
                .buttonStyle(.plain)
                Spacer()
                Button("Reset counters") {
                    opencodeTokensToday = 0
                    opencodeTokensWeek  = 0
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(Theme.Color.textMuted)
            }
        }
    }

    // OpenCode token usage counters (rolled per-render).
    @AppStorage("ai.opencode.tokens.today")   private var opencodeTokensToday: Int = 0
    @AppStorage("ai.opencode.tokens.week")    private var opencodeTokensWeek: Int = 0
    @AppStorage("ai.opencode.tokens.dayKey")  private var opencodeTokensDayKey: String = ""
    @AppStorage("ai.opencode.tokens.weekKey") private var opencodeTokensWeekKey: String = ""

    private func rollOpenCodeUsageWindows() -> Bool {
        let cal = Calendar(identifier: .iso8601)
        let now = Date()
        let dayKey = Self.dayKeyFmt.string(from: now)
        if dayKey != opencodeTokensDayKey {
            opencodeTokensDayKey = dayKey
            opencodeTokensToday = 0
        }
        let comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)
        let weekKey = "\(comps.yearForWeekOfYear ?? 0)-W\(comps.weekOfYear ?? 0)"
        if weekKey != opencodeTokensWeekKey {
            opencodeTokensWeekKey = weekKey
            opencodeTokensWeek = 0
        }
        return true
    }

    private var codexInstalled: Bool { CodexEngine.locateBinary() != nil }

    private var codexModelPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("MODEL")
                .font(.system(size: 9, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(Theme.Color.textMuted)
            Picker("", selection: $codexModel) {
                ForEach(Self.availableCodexModels, id: \.id) { m in
                    Text(m.label).tag(m.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: 320, alignment: .leading)

            Text("Passed to `codex exec -m`. Anything your `codex` login can run works here — edit the list in code to add more.")
                .font(.system(size: 10))
                .foregroundStyle(Theme.Color.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var codexEffortPicker: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("REASONING EFFORT")
                .font(.system(size: 9, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(Theme.Color.textMuted)
            HStack(spacing: 6) {
                ForEach(Self.codexEffortLevels, id: \.id) { e in
                    Button {
                        codexEffort = e.id
                    } label: {
                        Text(e.label)
                            .font(.system(size: 11, weight: codexEffort == e.id ? .bold : .medium))
                            .foregroundStyle(codexEffort == e.id ? .white : Theme.Color.textSecondary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 5)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(codexEffort == e.id
                                          ? AnyShapeStyle(Theme.accentGradient)
                                          : AnyShapeStyle(Theme.Color.surface))
                            )
                    }
                    .buttonStyle(.plain)
                    .help(e.tooltip)
                }
                Spacer()
            }
        }
    }

    /// User-visible Codex models (from the CLI's models cache). Codex
    /// passes these straight to `-m`; the effort levels include
    /// `xhigh` which the GPT-5.x line supports beyond Claude's three.
    private static let availableCodexModels: [ClaudeModelOption] = [
        .init(id: "gpt-5.5",        label: "GPT-5.5 (frontier)"),
        .init(id: "gpt-5.4",        label: "GPT-5.4"),
        .init(id: "gpt-5.4-mini",   label: "GPT-5.4 Mini"),
        .init(id: "gpt-5.3-codex",  label: "GPT-5.3 Codex"),
        .init(id: "gpt-5.2",        label: "GPT-5.2"),
    ]

    private static let codexEffortLevels: [EffortOption] = [
        .init(id: "low",     label: "Low",     tooltip: "Fast, lighter reasoning."),
        .init(id: "medium",  label: "Medium",  tooltip: "Balanced default."),
        .init(id: "high",    label: "High",    tooltip: "Deeper reasoning."),
        .init(id: "xhigh",   label: "X-High",  tooltip: "Maximum reasoning depth (GPT-5.x)."),
    ]

    // ── AI / Claude card ──────────────────────────────────────────

    private var claudeCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                sectionTitle(
                    icon: "sparkles",
                    title: "Claude (AI analysis)",
                    subtitle: "Token usage rolls up here from each completed run. Pick the model + reasoning effort from the engine selector on the analysis page."
                )

                usageRow
            }
        }
    }

    private var usageRow: some View {
        let _ = rollUsageWindows()
        return VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            Text("USAGE")
                .font(.system(size: 9, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(Theme.Color.textMuted)
            HStack(spacing: Theme.Spacing.xl) {
                usageStat(label: "Today",       value: formatTokens(tokensToday))
                usageStat(label: "This week",   value: formatTokens(tokensWeek))
            }
            Text("Anthropic enforces 5-hour and weekly limits per plan. The values above are token totals from your local Helix runs — a useful proxy, not the canonical limit numbers.")
                .font(.system(size: 10))
                .foregroundStyle(Theme.Color.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button {
                    if let url = URL(string: "https://console.anthropic.com/settings/usage") {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    Label("Open Anthropic usage", systemImage: "arrow.up.right.square")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.Color.accentStart)
                }
                .buttonStyle(.plain)
                Spacer()
                Button("Reset counters") {
                    tokensToday = 0
                    tokensWeek  = 0
                }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(Theme.Color.textMuted)
            }
        }
    }

    private func usageStat(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .heavy))
                .tracking(0.6)
                .foregroundStyle(Theme.Color.textMuted)
            Text(value)
                .font(.system(size: 18, weight: .bold).monospacedDigit())
                .foregroundStyle(Theme.Color.textPrimary)
        }
    }

    private func rollUsageWindows() -> Bool {
        let cal = Calendar(identifier: .iso8601)
        let now = Date()
        let dayKey = Self.dayKeyFmt.string(from: now)
        if dayKey != tokensDayKey {
            tokensDayKey = dayKey
            tokensToday = 0
        }
        let comps = cal.dateComponents([.yearForWeekOfYear, .weekOfYear], from: now)
        let weekKey = "\(comps.yearForWeekOfYear ?? 0)-W\(comps.weekOfYear ?? 0)"
        if weekKey != tokensWeekKey {
            tokensWeekKey = weekKey
            tokensWeek = 0
        }
        return true
    }

    private static let dayKeyFmt: DateFormatter = {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .iso8601)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    private func formatTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.2fM", Double(n) / 1_000_000) }
        if n >= 1_000     { return String(format: "%.1fK", Double(n) / 1_000) }
        return "\(n)"
    }

    /// Lightweight option types reused by the Codex card's pickers. The
    /// Claude model/effort catalog moved to `ClaudeModelCatalog` (AI
    /// layer) when those controls moved to the analysis-page engine
    /// dropdown.
    private struct ClaudeModelOption: Hashable { let id: String; let label: String }
    private struct EffortOption: Hashable { let id: String; let label: String; let tooltip: String }

    // ── Network / proxy card ──────────────────────────────────────

    private var proxyCard: some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                sectionTitle(
                    icon: "network.badge.shield.half.filled",
                    title: "SOCKS5 Proxy",
                    subtitle: "Routes outbound HTTP through a SOCKS5 proxy. Useful when a data source is region-locked or when running behind a corporate proxy."
                )

                Toggle(isOn: proxyBinding(\.enabled)) {
                    Text("Enable proxy")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(Theme.Color.textPrimary)
                }
                .toggleStyle(.switch)
                .tint(Theme.Color.accentStart)

                HStack(spacing: Theme.Spacing.md) {
                    labelled("Host", text: proxyBinding(\.host), placeholder: "127.0.0.1")
                        .frame(maxWidth: .infinity)
                    labelled("Port", number: Binding(
                        get: { proxy.port },
                        set: { proxy.port = $0; proxyDirty = true }
                    ))
                    .frame(width: 110)
                }

                HStack {
                    if case .working = proxyTestState {
                        ProgressView().controlSize(.small)
                    }
                    if case .ok = proxyTestState {
                        Label("Reached Yahoo via proxy", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(Theme.Color.success)
                            .font(.system(size: 11, weight: .medium))
                    }
                    if case .failed(let msg) = proxyTestState {
                        Label(msg, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(Theme.Color.danger)
                            .font(.system(size: 11, weight: .medium))
                            .lineLimit(2)
                    }
                    Spacer()
                    SecondaryButton(title: "Test") { testProxy() }
                    PrimaryButton(proxyDirty ? "Apply" : "Saved",
                                  systemImage: proxyDirty ? "checkmark" : nil) {
                        applyProxy()
                    }
                }
            }
        }
    }

    // ── Helpers ────────────────────────────────────────────────────

    private func sectionTitle(icon: String, title: String, subtitle: String) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.md) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.accentGradient)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.Color.textPrimary)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Color.textSecondary)
            }
            Spacer()
        }
    }

    private func labelled(
        _ label: String,
        text: Binding<String>? = nil,
        number: Binding<Int>? = nil,
        placeholder: String = ""
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label.uppercased())
                .font(.system(size: 9, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(Theme.Color.textMuted)
            Group {
                if let text = text {
                    TextField(placeholder, text: text)
                } else if let number = number {
                    TextField("", value: number, format: .number)
                        .multilineTextAlignment(.trailing)
                }
            }
            .textFieldStyle(.plain)
            .padding(Theme.Spacing.sm)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.sm)
                    .fill(Theme.Color.surface)
            )
            .foregroundStyle(Theme.Color.textPrimary)
            .font(.system(size: 12, design: .monospaced))
        }
    }

    private func proxyBinding<V>(_ keyPath: WritableKeyPath<ProxyConfig, V>) -> Binding<V> {
        Binding(
            get: { proxy[keyPath: keyPath] },
            set: { proxy[keyPath: keyPath] = $0; proxyDirty = true }
        )
    }

    private func applyProxy() {
        proxy.save()
        ProxyTransport.shared.configure(proxy)
        proxyDirty = false
    }

    private func testProxy() {
        proxyTestState = .working
        ProxyTransport.shared.configure(proxy)
        Task {
            do {
                let url = URL(string: "https://query2.finance.yahoo.com/v8/finance/chart/BTC-USD?interval=1d&range=1d")!
                let (_, resp) = try await ProxyTransport.shared.urlSession.data(from: url)
                if let http = resp as? HTTPURLResponse, http.statusCode == 200 {
                    await MainActor.run { proxyTestState = .ok }
                } else {
                    await MainActor.run { proxyTestState = .failed("Unexpected status from Yahoo") }
                }
            } catch {
                await MainActor.run { proxyTestState = .failed(error.localizedDescription) }
            }
        }
    }
}

// ── SettingsCategory model ─────────────────────────────────────────────────

// SettingsCategory is defined in SettingsCategory.swift
