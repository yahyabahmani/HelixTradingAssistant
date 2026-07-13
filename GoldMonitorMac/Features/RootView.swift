import SwiftUI

/// Root layout: sidebar | main area. Replaces the default
/// `NavigationSplitView` because we want the CleanMyMac X look — fixed
/// sidebar (no auto-collapse), no system title bar reveal — which
/// `NavigationSplitView` fights us on at the moment.
struct RootView: View {
    @EnvironmentObject private var app: AppState

    /// Drives the in-app Faraz re-login sheet when a 401 is reported.
    @ObservedObject private var farazAuth = FarazAuthCoordinator.shared

    /// One-shot guard so we only auto-toggle fullscreen on the very first
    /// `WindowConfigurator` callback. Without this, things like sheet
    /// dismissals (which can re-trigger the view's NSView lifecycle)
    /// would yank the user back into fullscreen every time.
    @State private var didEnterFullscreen = false

    /// Last app version whose "What's New" popup the user dismissed. When
    /// it differs from the running version, the popup fires once on launch.
    @AppStorage("whatsNew.lastSeenVersion") private var lastSeenVersion = ""
    @State private var showWhatsNew = false

    var body: some View {
        HStack(spacing: 0) {
            // Sidebar collapses entirely when the dashboard enters chart
            // fullscreen mode. Animation makes the transition feel like
            // the chart is sliding into place rather than the sidebar
            // popping out of existence.
            if !app.isChartFullscreen {
                SidebarView()
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
            mainArea
        }
        .animation(.easeInOut(duration: 0.22), value: app.isChartFullscreen)
        .background(Theme.Color.canvas)
        .ignoresSafeArea()
        // Auto-enter macOS fullscreen on first launch. The didEnterFullscreen
        // flag prevents us yanking the user back into fullscreen if they
        // manually exited mid-session.
        .background(
            WindowConfigurator { window in
                guard !didEnterFullscreen else { return }
                didEnterFullscreen = true
                if !window.styleMask.contains(.fullScreen) {
                    window.toggleFullScreen(nil)
                }
            }
        )
        // Hidden title bar trick — keep the traffic-light buttons but lose
        // the chrome. Equivalent to .windowStyle(.hiddenTitleBar) plus
        // a thin top inset for them.
        .overlay(alignment: .topLeading) { trafficLightSpacer }
        .sheet(isPresented: Binding(
            get: { app.showWizard },
            set: { app.showWizard = $0 }
        )) {
            WizardView()
        }
        .alert("Error", isPresented: errorBinding) {
            Button("OK") { app.lastError = nil }
        } message: {
            Text(app.lastError ?? "")
        }
        .sheet(isPresented: $showWhatsNew) {
            WhatsNewView(notes: .latest) {
                lastSeenVersion = AppInfo.version
                showWhatsNew = false
            }
        }
        .sheet(isPresented: $farazAuth.isPresentingLogin) {
            FarazLoginSheet(
                reason: farazAuth.lastReason,
                onCapture: { farazAuth.completeLogin(cookieHeader: $0) },
                onCancel: { farazAuth.cancel() }
            )
        }
        .onAppear {
            // Fire the What's New popup once when the running version is
            // newer than the last one the user saw. Defer while the
            // first-run wizard is up so the two sheets don't collide —
            // it'll surface on the next launch instead.
            if !app.showWizard, lastSeenVersion != AppInfo.version {
                showWhatsNew = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .helixNotificationOpened)) { note in
            guard let target = note.userInfo?["target"] as? NotificationChartTarget else { return }
            app.openNotificationChart(target)
        }
    }

    // The hidden title bar option in WindowGroup leaves room for the
    // traffic lights but doesn't draw the bar background. Without this
    // 28pt spacer at the top, our sidebar would render under the lights.
    private var trafficLightSpacer: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(height: 28)
    }

    @ViewBuilder
    private var mainArea: some View {
        switch app.selectedSidebarItem {
        case .dashboard, .none:
            DashboardView()
        case .news:
            NewsView()
        case .portfolio:
            AnalyticsView()
        case .journal:
            JournalView()
        case .inbox:
            NotificationInboxView()
        case .settings:
            SettingsView()
        }
    }

    private func placeholder(title: String, subtitle: String) -> some View {
        VStack(spacing: Theme.Spacing.md) {
            Spacer()
            Image(systemName: "wrench.and.screwdriver")
                .font(.system(size: 56))
                .foregroundStyle(Theme.Color.textMuted)
            Text(title)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Theme.Color.textPrimary)
            Text(subtitle)
                .font(.system(size: 12))
                .foregroundStyle(Theme.Color.textMuted)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Color.canvas)
    }

    /// Bridge `app.lastError` (optional String) into a Bool binding for
    /// `.alert(isPresented:)`. Setting false clears the error.
    private var errorBinding: Binding<Bool> {
        Binding(
            get: { app.lastError != nil },
            set: { newVal in
                if !newVal { app.lastError = nil }
            }
        )
    }
}
