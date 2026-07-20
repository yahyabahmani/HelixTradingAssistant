import SwiftUI

struct SettingsViewiPad: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var dataConfig: DataSourceConfig

    @AppStorage("ai.opencode.model") private var opencodeModel: String = OpenCodeModelCatalog.defaultModelID
    @AppStorage("ai.opencode.useRemote") private var opencodeUseRemote: Bool = true
    @AppStorage("ai.opencode.serverURL") private var opencodeServerURL: String = ""
    @State private var opencodeServerPassword: String = ""
    @State private var opencodeServerPasswordDirty: Bool = false

    @AppStorage("markets.forex.enabled")   private var forexEnabled: Bool = true
    @AppStorage("markets.crypto.enabled")  private var cryptoEnabled: Bool = true
    @AppStorage("markets.indices.enabled") private var indicesEnabled: Bool = true

    @State private var testState: TestState = .idle
    enum TestState: Equatable { case idle, working, ok, failed(String) }

    // Data source drafts
    @State private var twelveDataKeyDraft: String = ""
    @State private var goldSourceDraft: GoldDataSource = .twelveData
    @State private var farazTokenDraft: String = ""
    @State private var farazAPIURLDraft: String = ""
    @State private var dataDirty: Bool = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.Spacing.lg) {
                // Header
                HStack {
                    Text("Settings")
                        .font(.system(size: 22, weight: .bold))
                        .foregroundStyle(Theme.Color.textPrimary)
                    Spacer()
                }
                .padding(.horizontal, Theme.Spacing.xl)
                .padding(.top, Theme.Spacing.lg)

                // Data Sources card
                dataSourcesCard

                // OpenCode card
                opencodeCard

                // Markets card
                marketsCard

                // About card
                aboutCard
            }
            .padding(.bottom, Theme.Spacing.xxl)
        }
        .background(Theme.Color.canvas)
        .onAppear {
            // Defer state seeding to the next run loop so SwiftUI
            // finishes the current view update before we mutate
            // multiple @State/@AppStorage properties. Avoids the
            // "Modifying state during view update" cascade.
            DispatchQueue.main.async {
                if opencodeServerURL.isEmpty {
                    opencodeServerURL = "http://ntsn.teleincognito.com:4096"
                }
                if opencodeServerPassword.isEmpty {
                    opencodeServerPassword = KeychainHelper.get(.opencodeServerPass) ?? ""
                }
                seedDataFromConfig()
            }
        }
        .onDisappear {
            saveOpenCodeSettings()
        }
    }

    // MARK: - Data Sources Card

    private var dataSourcesCard: some View {
        settingsCard(title: "Data Sources", icon: "antenna.radiowaves.left.and.right") {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                // Gold source picker
                VStack(alignment: .leading, spacing: 6) {
                    Text("PRICE DATA SOURCE (XAU · BTC · SOL · ETH)")
                        .font(.system(size: 9, weight: .bold))
                        .tracking(0.8)
                        .foregroundStyle(Theme.Color.textMuted)
                    Picker("", selection: $goldSourceDraft) {
                        ForEach(GoldDataSource.allCases) { src in
                            Text(src.displayName).tag(src)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .onChange(of: goldSourceDraft) { _ in dataDirty = true }

                    if goldSourceDraft == .faraz {
                        Text("FARAZ SESSION COOKIE")
                            .font(.system(size: 9, weight: .bold))
                            .tracking(0.8)
                            .foregroundStyle(Theme.Color.textMuted)
                            .padding(.top, 2)
                        SecureField("Cookie header value from a logged-in faraz.io tab", text: $farazTokenDraft)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12).monospaced())
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.Color.surface))
                            .onChange(of: farazTokenDraft) { _ in dataDirty = true }

                        Button {
                            FarazAuthCoordinator.shared.presentLoginManually()
                        } label: {
                            Label("Log in to Faraz…", systemImage: "person.crop.circle.badge.checkmark")
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 14)
                                .frame(height: 40)
                                .background(Capsule().fill(Theme.accentGradient))
                        }
                        .buttonStyle(.plain)
                        Text("Log in to capture your session automatically. A 401 re-opens this login on its own.")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.Color.textMuted)

                        Text("FARAZ API BASE URL")
                            .font(.system(size: 9, weight: .bold))
                            .tracking(0.8)
                            .foregroundStyle(Theme.Color.textMuted)
                            .padding(.top, 2)
                        TextField(DataSourceConfig.defaultFarazAPIURL, text: $farazAPIURLDraft)
                            .textFieldStyle(.plain)
                            .font(.system(size: 12).monospaced())
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 10)
                            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.Color.surface))
                            .onChange(of: farazAPIURLDraft) { _ in dataDirty = true }
                    } else {
                        Text("Gold + BTC/SOL/ETH use Twelve Data live ticks with Yahoo Finance history. Indices always use Yahoo.")
                            .font(.system(size: 10))
                            .foregroundStyle(Theme.Color.textMuted)
                    }
                }

                Divider().background(Theme.Color.border.opacity(0.4))

                // Twelve Data API Key
                settingsField(label: "TWELVE DATA API KEY", text: $twelveDataKeyDraft, placeholder: "Enter your API key")
                    .onChange(of: twelveDataKeyDraft) { _ in dataDirty = true }

                // Save button
                HStack {
                    Spacer()
                    Button {
                        saveDataSources()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: dataDirty ? "checkmark.circle.fill" : "checkmark.circle")
                            Text(dataDirty ? "Save Changes" : "Saved")
                        }
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(dataDirty ? .white : Theme.Color.textSecondary)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                        .background(
                            Capsule().fill(dataDirty
                                           ? AnyShapeStyle(Theme.accentGradient)
                                           : AnyShapeStyle(Theme.Color.surface))
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - OpenCode Card

    private var opencodeCard: some View {
        settingsCard(title: "OpenCode AI", icon: "terminal.fill") {
            VStack(alignment: .leading, spacing: Theme.Spacing.md) {
                Toggle("Remote Server", isOn: $opencodeUseRemote)
                    .tint(Theme.Color.accentStart)

                if opencodeUseRemote {
                    // Server URL
                    VStack(alignment: .leading, spacing: 6) {
                        Text("SERVER URL")
                            .font(.system(size: 9, weight: .bold))
                            .tracking(0.8)
                            .foregroundStyle(Theme.Color.textMuted)
                        HStack(spacing: Theme.Spacing.sm) {
                            TextField("http://your-vps-ip:4096", text: $opencodeServerURL)
                                .textFieldStyle(.plain)
                                .font(.system(size: 12, design: .monospaced))
                                .autocapitalization(.none)
                                .disableAutocorrection(true)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.Color.surface))
                            Button { testConnection() } label: {
                                if testState == .working {
                                    ProgressView().scaleEffect(0.8)
                                } else {
                                    Text("Test")
                                        .font(.system(size: 11, weight: .semibold))
                                        .foregroundStyle(Theme.Color.accentStart)
                                        .padding(.horizontal, 12)
                                        .padding(.vertical, 10)
                                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.Color.surface))
                                }
                            }
                            .buttonStyle(.plain)
                        }
                        if testState == .ok {
                            Label("Connected", systemImage: "checkmark.circle.fill")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Theme.Color.success)
                        }
                        if case .failed(let msg) = testState {
                            Label(msg, systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(Theme.Color.danger)
                                .lineLimit(2)
                        }
                    }

                    // Server Password
                    VStack(alignment: .leading, spacing: 6) {
                        Text("SERVER PASSWORD")
                            .font(.system(size: 9, weight: .bold))
                            .tracking(0.8)
                            .foregroundStyle(Theme.Color.textMuted)
                        HStack(spacing: Theme.Spacing.sm) {
                            SecureField("Optional password", text: $opencodeServerPassword)
                                .textFieldStyle(.plain)
                                .font(.system(size: 12, design: .monospaced))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.Color.surface))
                                .onChange(of: opencodeServerPassword) { _ in opencodeServerPasswordDirty = true }
                            Button {
                                KeychainHelper.set(.opencodeServerPass, opencodeServerPassword)
                                opencodeServerPasswordDirty = false
                            } label: {
                                Text(opencodeServerPasswordDirty ? "Save" : "Saved")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(opencodeServerPasswordDirty ? .white : Theme.Color.textSecondary)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 10)
                                    .background(
                                        RoundedRectangle(cornerRadius: 8)
                                            .fill(opencodeServerPasswordDirty
                                                  ? AnyShapeStyle(Theme.accentGradient)
                                                  : AnyShapeStyle(Theme.Color.surface))
                                    )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Divider().background(Theme.Color.border.opacity(0.4))

                // Model picker — grouped by provider
                VStack(alignment: .leading, spacing: 6) {
                    Text("MODEL")
                        .font(.system(size: 9, weight: .bold))
                        .tracking(0.8)
                        .foregroundStyle(Theme.Color.textMuted)
                    modelPickerMenu
                }
            }
        }
    }

    // MARK: - Markets Card

    private var marketsCard: some View {
        settingsCard(title: "Markets", icon: "chart.bar.fill") {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                marketToggle("Forex", subtitle: "XAU/USD ounce", isOn: $forexEnabled)
                marketToggle("Crypto", subtitle: "BTC / SOL / ETH", isOn: $cryptoEnabled)
                marketToggle("Indices", subtitle: "Dow Jones (DJI) / Dollar Index (DXY)", isOn: $indicesEnabled)
            }
        }
    }

    // MARK: - About Card

    private var aboutCard: some View {
        settingsCard(title: "About", icon: "info.circle") {
            VStack(alignment: .leading, spacing: Theme.Spacing.sm) {
                aboutRow("Version", value: "1.0 (iPad)")
                aboutRow("Bundle", value: "club.helixtrading.app.ipad")
            }
        }
    }

    // MARK: - Components

    private func settingsCard<Content: View>(title: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.md) {
            Label(title, systemImage: icon)
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(Theme.Color.textMuted)
            content()
        }
        .padding(Theme.Spacing.lg)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.lg)
                .fill(Theme.Color.surfaceHi)
                .overlay(
                    RoundedRectangle(cornerRadius: Theme.Radius.lg)
                        .strokeBorder(Theme.Color.border, lineWidth: 1)
                )
        )
        .padding(.horizontal, Theme.Spacing.xl)
    }

    private func settingsField(label: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.system(size: 9, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(Theme.Color.textMuted)
            TextField(placeholder, text: text)
                .textFieldStyle(.plain)
                .font(.system(size: 12).monospaced())
                .autocapitalization(.none)
                .disableAutocorrection(true)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.Color.surface))
        }
    }

    private func marketToggle(_ title: String, subtitle: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Theme.Color.textPrimary)
                Text(subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.Color.textMuted)
            }
        }
        .toggleStyle(.switch)
        .tint(Theme.Color.accentStart)
    }

    private func aboutRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 13))
                .foregroundStyle(Theme.Color.textSecondary)
            Spacer()
            Text(value)
                .font(.system(size: 12).monospaced())
                .foregroundStyle(Theme.Color.textMuted)
        }
    }

    private var modelPickerMenu: some View {
        Menu {
            modelMenuContent
        } label: {
            HStack {
                Text(OpenCodeModelCatalog.label(forModelID: opencodeModel))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Theme.Color.textPrimary)
                Spacer()
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.Color.textMuted)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.Color.surface))
        }
    }

    @ViewBuilder
    private var modelMenuContent: some View {
        let groups = OpenCodeModelCatalog.allModelsByProvider
        ForEach(groups.indices, id: \.self) { gi in
            let group = groups[gi]
            Section(header: Text(group.provider)) {
                ForEach(group.models) { model in
                    Button { opencodeModel = model.id } label: {
                        HStack {
                            Text(model.label)
                            if model.id == opencodeModel {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
            }
        }
    }

    // MARK: - Data Source Actions

    private func seedDataFromConfig() {
        twelveDataKeyDraft = dataConfig.twelveDataAPIKey
        goldSourceDraft = dataConfig.goldSource
        farazTokenDraft = dataConfig.farazCookie
        farazAPIURLDraft = dataConfig.farazAPIURL
        dataDirty = false
    }

    private func saveDataSources() {
        dataConfig.twelveDataAPIKey = twelveDataKeyDraft
        dataConfig.updateGoldSource(
            goldSourceDraft,
            farazCookie: farazTokenDraft,
            farazAPIURL: farazAPIURLDraft
        )
        dataDirty = false
    }

    // MARK: - OpenCode Actions

    private func saveOpenCodeSettings() {
        if opencodeServerPasswordDirty {
            KeychainHelper.set(.opencodeServerPass, opencodeServerPassword)
            opencodeServerPasswordDirty = false
        }
    }

    private func testConnection() {
        guard let url = URL(string: opencodeServerURL) else {
            testState = .failed("Invalid URL")
            return
        }
        testState = .working

        let healthURL = url.appendingPathComponent("global/health")
        var request = URLRequest(url: healthURL)
        request.timeoutInterval = 10
        if !opencodeServerPassword.isEmpty {
            let credentials = "opencode:\(opencodeServerPassword)"
            let base64 = Data(credentials.utf8).base64EncodedString()
            request.setValue("Basic \(base64)", forHTTPHeaderField: "Authorization")
        }

        URLSession.shared.dataTask(with: request) { _, response, error in
            DispatchQueue.main.async {
                if let error = error {
                    testState = .failed(error.localizedDescription)
                    return
                }
                if let http = response as? HTTPURLResponse {
                    if http.statusCode == 200 {
                        testState = .ok
                    } else if http.statusCode == 401 {
                        testState = .failed("Auth failed")
                    } else {
                        testState = .failed("HTTP \(http.statusCode)")
                    }
                } else {
                    testState = .failed("Invalid response")
                }
            }
        }.resume()
    }
}
