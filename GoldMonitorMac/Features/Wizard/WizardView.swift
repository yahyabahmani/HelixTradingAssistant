import SwiftUI

/// First-run setup wizard. Walks the user through three steps:
///   1. **Welcome** — explainer + permission ask.
///   2. **Claude** — detect the `claude` CLI; offer install + auth
///      instructions when missing.
///   3. **Data sources** — Twelve Data API key, calendar URL,
///      proxy. Everything that used to be hardcoded is editable
///      here.
///   4. **Done** — confirmation + start trading.
///
/// Triggered automatically on first launch (when
/// `setup.completed` is false) and re-runnable from the
/// Settings page or the sidebar's footer button. State is local
/// to the wizard; only the final Save action mutates the
/// `DataSourceConfig` singleton and writes `setup.completed`.
struct WizardView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var dataConfig: DataSourceConfig
    @Environment(\.dismiss) private var dismiss

    @State private var step: Step = .welcome
    @State private var claudeStatus: ClaudeStatus = .checking
    @State private var twelveDataKeyDraft: String = ""
    @State private var forexURLDraft: String = ""
    @State private var claudePathDraft: String = ""
    @AppStorage("setup.completed") private var setupCompleted: Bool = false

    enum Step: Int, CaseIterable {
        case welcome = 0
        case claude = 1
        case dataSources = 2
        case done = 3

        var label: String {
            switch self {
            case .welcome:     return "Welcome"
            case .claude:      return "Claude"
            case .dataSources: return "Data sources"
            case .done:        return "Done"
            }
        }
    }

    enum ClaudeStatus: Equatable {
        case checking
        case found(path: String, version: String?)
        case notFound
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Theme.Color.border)
            ScrollView {
                stepBody
                    .padding(Theme.Spacing.xl)
                    .frame(maxWidth: 560)
                    .frame(maxWidth: .infinity)
            }
            Divider().background(Theme.Color.border)
            footer
        }
        .frame(minWidth: 640, idealWidth: 720, minHeight: 520, idealHeight: 580)
        .background(Theme.Color.canvas)
        .onAppear {
            // Seed the drafts from the live config so re-opening
            // the wizard shows what's currently saved (and lets
            // the user tweak).
            twelveDataKeyDraft = dataConfig.twelveDataAPIKey
            forexURLDraft = dataConfig.forexFactoryURL
            claudePathDraft = dataConfig.claudeBinaryPath
            detectClaude()
        }
    }

    // ── Header ─────────────────────────────────────────────────────
    private var header: some View {
        HStack(spacing: Theme.Spacing.md) {
            Label("Setup wizard", systemImage: "wand.and.stars")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(Theme.Color.textPrimary)
            Spacer()
            stepIndicator
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.Color.textSecondary)
                    .frame(width: 24, height: 24)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Theme.Color.surface))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.vertical, Theme.Spacing.md)
    }

    private var stepIndicator: some View {
        HStack(spacing: 4) {
            ForEach(Step.allCases, id: \.self) { s in
                Circle()
                    .fill(s.rawValue <= step.rawValue
                          ? Theme.Color.accentStart
                          : Theme.Color.textMuted.opacity(0.3))
                    .frame(width: 8, height: 8)
            }
        }
    }

    // ── Step body ──────────────────────────────────────────────────
    @ViewBuilder
    private var stepBody: some View {
        switch step {
        case .welcome:     welcomeStep
        case .claude:      claudeStep
        case .dataSources: dataSourcesStep
        case .done:        doneStep
        }
    }

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            Image(systemName: "sparkles")
                .font(.system(size: 36))
                .foregroundStyle(Theme.accentGradient)
            Text("Welcome to Helix Trading")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(Theme.Color.textPrimary)
            Text("A SwiftUI macOS app for charting gold + crypto with AI-driven technical analysis. Before you start, we'll set up:")
                .font(.system(size: 13))
                .foregroundStyle(Theme.Color.textSecondary)

            bulletRow(icon: "terminal.fill",  title: "Claude CLI",       subtitle: "Powers every AI analysis — we'll detect or help install it.")
            bulletRow(icon: "antenna.radiowaves.left.and.right", title: "Live data feeds", subtitle: "Twelve Data for crypto live ticks, Yahoo for OHLC history.")
            bulletRow(icon: "calendar",       title: "Economic calendar", subtitle: "ForexFactory feed for FOMC / CPI / NFP event warnings.")

            Text("All values stay on your machine — there are no telemetry calls and no Helix-controlled servers. You can re-run this wizard at any time from Settings.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.Color.textMuted)
                .padding(.top, Theme.Spacing.sm)
        }
    }

    private func bulletRow(icon: String, title: String, subtitle: String) -> some View {
        HStack(alignment: .top, spacing: Theme.Spacing.md) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Theme.Color.accentStart)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.Color.textPrimary)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Color.textSecondary)
            }
            Spacer()
        }
    }

    // ── Claude step ────────────────────────────────────────────────
    private var claudeStep: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            stepHeader(
                icon: "terminal.fill",
                title: "Claude CLI",
                subtitle: "Helix shells out to the Claude Code CLI for every AI analysis — no API key needed, it reuses your CLI session."
            )

            // Status card.
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                switch claudeStatus {
                case .checking:
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Looking for `claude` on your PATH and common install paths…")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.Color.textSecondary)
                    }
                case .found(let path, let version):
                    HStack(spacing: 8) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(Theme.Color.success)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Claude CLI found")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(Theme.Color.textPrimary)
                            Text(path)
                                .font(.system(size: 11).monospaced())
                                .foregroundStyle(Theme.Color.textMuted)
                            if let v = version {
                                Text(v)
                                    .font(.system(size: 10).monospaced())
                                    .foregroundStyle(Theme.Color.textMuted)
                            }
                        }
                        Spacer()
                    }
                case .notFound:
                    notFoundCard
                }
            }
            .padding(Theme.Spacing.md)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.md)
                    .fill(Theme.Color.surface)
            )

            // Override path field — always available, so users on
            // an unusual install (custom shell init, nix, …) can
            // point us at their binary directly.
            VStack(alignment: .leading, spacing: 6) {
                Text("OVERRIDE BINARY PATH (OPTIONAL)")
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(Theme.Color.textMuted)
                TextField("/usr/local/bin/claude", text: $claudePathDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12).monospaced())
                Text("Leave blank to use auto-detection. Useful if you've installed Claude under a custom prefix.")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.Color.textMuted)
            }

            HStack {
                Button("Re-detect") { detectClaude() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.Color.accentStart)
                Spacer()
            }
        }
    }

    private var notFoundCard: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.Color.warn)
                Text("Claude CLI not found")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.Color.textPrimary)
                Spacer()
            }
            Text("Install Claude Code in your terminal first:")
                .font(.system(size: 11))
                .foregroundStyle(Theme.Color.textSecondary)
            HStack(spacing: 8) {
                Text("npm install -g @anthropic-ai/claude-code")
                    .font(.system(size: 11).monospaced())
                    .foregroundStyle(Theme.Color.textPrimary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 4).fill(Theme.Color.surfaceHi))
                Button {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString("npm install -g @anthropic-ai/claude-code", forType: .string)
                } label: {
                    Image(systemName: "doc.on.doc")
                        .foregroundStyle(Theme.Color.textSecondary)
                }
                .buttonStyle(.plain)
                .help("Copy")
            }
            Text("Then authenticate once with `claude` and run `claude /status` to confirm. After that, re-detect below.")
                .font(.system(size: 11))
                .foregroundStyle(Theme.Color.textSecondary)
            HStack(spacing: 8) {
                Button("Open Claude Code site") {
                    if let url = URL(string: "https://docs.claude.com/en/docs/claude-code/overview") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.Color.accentStart)
                Button("Open Terminal") {
                    if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.plain)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.Color.accentStart)
            }
        }
    }

    // ── Data sources step ──────────────────────────────────────────
    private var dataSourcesStep: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            stepHeader(
                icon: "antenna.radiowaves.left.and.right",
                title: "Data sources",
                subtitle: "Endpoints + keys for the live data feeds. Sensible defaults are pre-filled — only the Twelve Data API key is mandatory for crypto live prices."
            )

            // Twelve Data — the only secret.
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("TWELVE DATA API KEY")
                        .font(.system(size: 9, weight: .bold))
                        .tracking(0.8)
                        .foregroundStyle(Theme.Color.textMuted)
                    Spacer()
                    Button("Get a free key →") {
                        if let url = URL(string: "https://twelvedata.com/pricing") {
                            NSWorkspace.shared.open(url)
                        }
                    }
                    .buttonStyle(.plain)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.Color.accentStart)
                }
                SecureField("Paste your Twelve Data API key", text: $twelveDataKeyDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12).monospaced())
                Text("Free tier covers crypto + forex WebSocket streams. Without a key, the live ticker for BTC / ETH / SOL stays offline; the chart still works from Yahoo history.")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.Color.textMuted)
            }

            // ForexFactory.
            VStack(alignment: .leading, spacing: 6) {
                Text("FOREXFACTORY CALENDAR URL")
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(Theme.Color.textMuted)
                TextField("https://nfs.faireconomy.media/ff_calendar_thisweek.xml", text: $forexURLDraft)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12).monospaced())
                Text("Public weekly event feed. Default points at the free mirror; swap in a paid feed or mirror if you have one.")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.Color.textMuted)
            }

            // Reminder about proxy.
            VStack(alignment: .leading, spacing: 6) {
                Text("OTHER SETTINGS")
                    .font(.system(size: 9, weight: .bold))
                    .tracking(0.8)
                    .foregroundStyle(Theme.Color.textMuted)
                Text("The SOCKS5 proxy is configured under Settings → Proxy once setup completes. You don't need it to use the app.")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Color.textSecondary)
            }
        }
    }

    // ── Done step ──────────────────────────────────────────────────
    private var doneStep: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 36))
                .foregroundStyle(Theme.Color.success)
            Text("All set")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(Theme.Color.textPrimary)
            Text("Live data will start streaming once you close this wizard. Use the Analyze button on the chart header to run an AI analysis.")
                .font(.system(size: 13))
                .foregroundStyle(Theme.Color.textSecondary)
            VStack(alignment: .leading, spacing: 4) {
                Text("You can re-run this wizard any time from:")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Color.textMuted)
                Text("Sidebar → Setup wizard")
                    .font(.system(size: 11, weight: .semibold).monospaced())
                    .foregroundStyle(Theme.Color.textSecondary)
                Text("Settings → Setup wizard → Re-run")
                    .font(.system(size: 11, weight: .semibold).monospaced())
                    .foregroundStyle(Theme.Color.textSecondary)
            }
        }
    }

    // ── Step header helper ────────────────────────────────────────
    private func stepHeader(icon: String, title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.accentGradient)
                Text(title)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Theme.Color.textPrimary)
            }
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(Theme.Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // ── Footer ─────────────────────────────────────────────────────
    private var footer: some View {
        HStack {
            if step != .welcome {
                SecondaryButton(title: "Back") {
                    step = Step(rawValue: step.rawValue - 1) ?? .welcome
                }
            }
            Spacer()

            if step != .done {
                PrimaryButton(primaryLabel) {
                    advance()
                }
            } else {
                PrimaryButton("Start trading", systemImage: "play.fill") {
                    finish()
                }
            }
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.vertical, Theme.Spacing.md)
    }

    private var primaryLabel: String {
        switch step {
        case .dataSources: return "Save & continue"
        default:           return "Continue"
        }
    }

    /// Save the relevant draft for the current step, then move to
    /// the next. Each step that has editable state writes through
    /// its own subset.
    private func advance() {
        switch step {
        case .dataSources:
            dataConfig.update(
                twelveDataAPIKey: twelveDataKeyDraft,
                forexFactoryURL:  forexURLDraft,
                claudeBinaryPath: claudePathDraft
            )
            step = .done
        case .welcome, .claude:
            step = Step(rawValue: step.rawValue + 1) ?? .done
        case .done:
            return
        }
    }

    private func finish() {
        setupCompleted = true
        app.showWizard = false
        dismiss()
    }

    // ── Claude detection ───────────────────────────────────────────

    private func detectClaude() {
        claudeStatus = .checking
        // If the user has explicitly set a path, prefer it. Otherwise
        // walk the candidate list.
        let override = claudePathDraft.trimmingCharacters(in: .whitespaces)
        Task.detached {
            let path = !override.isEmpty && FileManager.default.isExecutableFile(atPath: override)
                ? override
                : findClaudeBinary()
            guard let path = path else {
                await MainActor.run { self.claudeStatus = .notFound }
                return
            }
            let version = await runVersion(at: path)
            await MainActor.run {
                self.claudeStatus = .found(path: path, version: version)
            }
        }
    }

    private nonisolated func findClaudeBinary() -> String? {
        let candidates = [
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            NSHomeDirectory() + "/.claude/local/claude",
            NSHomeDirectory() + "/.local/bin/claude",
            NSHomeDirectory() + "/.npm-global/bin/claude",
            NSHomeDirectory() + "/.bun/bin/claude",
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private nonisolated func runVersion(at path: String) async -> String? {
        await withCheckedContinuation { cont in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = ["--version"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            do {
                try process.run()
                process.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let s = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                cont.resume(returning: s?.isEmpty == false ? s : nil)
            } catch {
                cont.resume(returning: nil)
            }
        }
    }
}
