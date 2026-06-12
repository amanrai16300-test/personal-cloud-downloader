import SwiftUI

/// CloudBox Network: an infrastructure telemetry monitor in the same visual
/// language as the redesigned Home dashboard, floating tab bar, and Settings
/// hub — flat raised navy panels, hairline strokes, tracked section headers,
/// monospaced counters, one blue accent. All data, API calls, refresh
/// behavior, and calculations are unchanged; only the presentation moved.
struct NetworkUsageView: View {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var usage: NetworkUsageResponse?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var autoRefreshTask: Task<Void, Never>?
    @State private var isVisible = false
    @State private var refreshGeneration = 0

    // MARK: Palette — mirrored from the Home redesign tokens.
    private let screenBackground = Color(red: 0.008, green: 0.022, blue: 0.055)
    private let surface = Color(red: 0.035, green: 0.065, blue: 0.125)
    private let surfaceRaised = Color(red: 0.055, green: 0.095, blue: 0.175)
    private let hairline = Color.white.opacity(0.08)
    private let mutedText = Color(red: 0.56, green: 0.64, blue: 0.78)
    private let premiumBlue = Color(red: 0.30, green: 0.59, blue: 1.0)
    private let todayCyan = Color(red: 0.36, green: 0.78, blue: 0.90)
    private let warningOrange = Color(red: 1.0, green: 0.62, blue: 0.26)

    var body: some View {
        NavigationStack {
            Group {
                if isLoading && usage == nil {
                    loadingView
                } else if let usage {
                    usageContent(usage)
                } else {
                    unavailableView
                }
            }
            .background(networkBackground)
            .navigationTitle("Network")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
            .refreshable {
                await loadUsage()
            }
            .onAppear {
                isVisible = true
                startAutoRefresh()
            }
            .onDisappear {
                isVisible = false
                stopAutoRefresh()
            }
            .onChange(of: scenePhase) { phase in
                if phase == .active {
                    guard isVisible else { return }
                    // Mirror the tab-switch recovery: a request suspended
                    // mid-flight can resume on a dead Tailscale socket and
                    // hold isLoading, which would make loadUsage() bail out.
                    // Cancel it, invalidate its generation, and restart the
                    // loop after the Tailscale warm-up delay.
                    stopAutoRefresh()
                    refreshGeneration += 1
                    isLoading = false
                    Task {
                        try? await Task.sleep(nanoseconds: 750_000_000)
                        guard !Task.isCancelled, isVisible else { return }
                        startAutoRefresh()
                    }
                } else {
                    stopAutoRefresh()
                }
            }
        }
    }

    // MARK: Background — deep navy, one accent bloom (Home recipe).

    private var networkBackground: some View {
        ZStack {
            screenBackground.ignoresSafeArea()
            RadialGradient(
                colors: [premiumBlue.opacity(0.12), .clear],
                center: .init(x: 0.9, y: -0.05),
                startRadius: 10,
                endRadius: 380
            )
            .ignoresSafeArea()
        }
    }

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .tint(premiumBlue)
                .scaleEffect(1.15)
            VStack(spacing: 5) {
                Text("Loading network usage")
                    .font(.system(size: 19, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                Text("Checking the CloudBox link")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(mutedText)
            }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(networkBackground)
    }

    private var unavailableView: some View {
        VStack(spacing: 14) {
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(mutedText)
                .frame(width: 76, height: 76)
                .background(surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .stroke(hairline, lineWidth: 1)
                }
            Text("Network usage unavailable")
                .font(.system(size: 20, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            Text(errorMessage ?? "Pull to refresh or check the server connection.")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(mutedText)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 18)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(networkBackground)
    }

    @ViewBuilder
    private func usageContent(_ usage: NetworkUsageResponse) -> some View {
        if let raw = usage.raw, !raw.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    monitorPanel(usage)
                    summaryTiles(usage)
                    storageCard(usage.storage)
                    section("Raw Counters") {
                        rawOutputCard(raw)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 14)
                .padding(.bottom, 34)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.28), value: usage.updatedAt)
            }
            .background(networkBackground)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    monitorPanel(usage)
                    summaryTiles(usage)
                    storageCard(usage.storage)

                    if let month = usage.month {
                        usageSection(title: "Current Month", row: month, showEstimate: true)
                    }

                    if let today = usage.today {
                        usageSection(title: "Today", row: today, showEstimate: false)
                    }

                    let dailyRows = usage.latestDailyRows
                    if !dailyRows.isEmpty {
                        section("Daily Usage") {
                            VStack(spacing: 0) {
                                ForEach(dailyRows) { row in
                                    dailyRow(row)
                                    if row.id != dailyRows.last?.id {
                                        rowDivider
                                    }
                                }
                            }
                            .background(panelSurface)
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 14)
                .padding(.bottom, 34)
                .animation(reduceMotion ? nil : .easeOut(duration: 0.28), value: usage.updatedAt)
            }
            .background(networkBackground)
        }
    }

    // MARK: Section scaffold — tracked uppercase header, shared with Settings.

    private func section(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title.uppercased())
                .font(.system(size: 11, weight: .bold))
                .tracking(1.6)
                .foregroundStyle(premiumBlue)
                .padding(.horizontal, 2)

            content()
        }
    }

    // MARK: Monitor panel — the telemetry centerpiece (Home server-panel kin).

    /// Live monitor header: tracked tag + pulse dot, monospaced interface name,
    /// and an updated/refresh footer. Carries the refresh-failure warning so
    /// status reads in one place.
    private func monitorPanel(_ usage: NetworkUsageResponse) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("LIVE MONITOR")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(1.6)
                    .foregroundStyle(premiumBlue)

                Spacer(minLength: 8)

                LivePulseDot(
                    color: errorMessage == nil ? premiumBlue : warningOrange,
                    animates: !reduceMotion
                )

                Text(isLoading ? "Refreshing" : "Live")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                    .foregroundStyle(errorMessage == nil ? premiumBlue : warningOrange)
                    .contentTransition(.opacity)
            }
            .padding(.bottom, 14)

            HStack(spacing: 10) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(premiumBlue)
                    .accessibilityHidden(true)

                Text(usage.interface)
                    .font(.system(size: 23, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                    .accessibilityLabel("Interface \(usage.interface)")

                Spacer(minLength: 0)
            }
            .padding(.bottom, 14)

            Rectangle()
                .fill(hairline)
                .frame(height: 1)
                .padding(.bottom, 11)

            HStack(spacing: 6) {
                Image(systemName: isLoading ? "arrow.triangle.2.circlepath" : "clock")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(mutedText)
                    .accessibilityHidden(true)

                Text(isLoading ? "Refreshing latest counters" : "Updated")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(mutedText)

                if !isLoading {
                    Text(usage.updatedAtDisplay)
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.92))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .contentTransition(.opacity)
                }

                Spacer(minLength: 8)

                Text("vnstat · Oracle")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(mutedText.opacity(0.85))
            }

            if let errorMessage {
                warningLine(errorMessage)
                    .padding(.top, 10)
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(surface)

                DotGridTexture()
                    .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))

                RadialGradient(
                    colors: [premiumBlue.opacity(0.16), .clear],
                    center: .topTrailing,
                    startRadius: 4,
                    endRadius: 240
                )
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [premiumBlue.opacity(0.45), hairline],
                        startPoint: .topTrailing,
                        endPoint: .bottomLeading
                    ),
                    lineWidth: 1
                )
        }
    }

    // MARK: Summary tiles — flat raised pair, no gradients or glow.

    @ViewBuilder
    private func summaryTiles(_ usage: NetworkUsageResponse) -> some View {
        if usage.month != nil || usage.today != nil {
            HStack(spacing: 12) {
                if let month = usage.month {
                    summaryTile(
                        icon: "arrow.up.right",
                        title: "Monthly Outgoing",
                        value: month.tx,
                        detail: "TX this month",
                        tint: premiumBlue
                    )
                }
                if let today = usage.today {
                    summaryTile(
                        icon: "arrow.up.arrow.down",
                        title: "Today",
                        value: today.total,
                        detail: "Total traffic",
                        tint: todayCyan
                    )
                }
            }
        }
    }

    private func summaryTile(icon: String, title: String, value: String, detail: String, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                iconChip(icon, tint: tint)
                Spacer(minLength: 0)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(mutedText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Text(value)
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(Color.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.62)
                    .contentTransition(.opacity)

                Text(detail)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(mutedText)
                    .lineLimit(1)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(metricSurface(tint: tint))
        .accessibilityElement(children: .combine)
    }

    /// Shared raised metric surface with a whisper of tint at the top edge —
    /// the same recipe as the Home bento cards.
    private func metricSurface(tint: Color) -> some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(surfaceRaised)
            .overlay(alignment: .top) {
                LinearGradient(
                    colors: [tint.opacity(0.14), .clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 54)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(hairline, lineWidth: 1)
            }
    }

    private func iconChip(_ systemName: String, tint: Color) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(tint)
            .frame(width: 32, height: 32)
            .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(tint.opacity(0.30), lineWidth: 1)
            }
            .accessibilityHidden(true)
    }

    // MARK: Usage sections — RX/TX/Total/Avg metric chips in a panel.

    private func usageSection(title: String, row: NetworkUsageRow, showEstimate: Bool) -> some View {
        section(title) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 108), spacing: 8)], spacing: 8) {
                metric("RX", row.rx)
                metric("TX", row.tx)
                metric("Total", row.total)
                metric("Avg Rate", row.avgRate)
                if showEstimate, let estimated = row.estimatedTotal {
                    metric("Est. Monthly Total", estimated)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(panelSurface)
        }
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(mutedText)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
            Text(value)
                .font(.system(size: 15, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.white.opacity(0.94))
                .lineLimit(1)
                .minimumScaleFactor(0.66)
                .contentTransition(.opacity)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(surfaceRaised.opacity(0.7), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(hairline, lineWidth: 1)
        }
    }

    // MARK: Storage panel

    @ViewBuilder
    private func storageCard(_ storage: StorageUsage?) -> some View {
        if let disk = storage?.rootDisk {
            section("Storage") {
                VStack(alignment: .leading, spacing: 13) {
                    HStack(alignment: .center, spacing: 12) {
                        iconChip("internaldrive.fill", tint: premiumBlue)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("Boot Volume")
                                .font(.system(size: 14, weight: .bold, design: .rounded))
                                .foregroundStyle(Color.white)
                            Text("\(disk.mount) (\(disk.path))")
                                .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
                                .foregroundStyle(mutedText)
                                .lineLimit(1)
                                .minimumScaleFactor(0.74)
                        }

                        Spacer(minLength: 8)

                        Text("\(disk.usedPercentDisplay)%")
                            .font(.system(size: 27, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(Color.white)
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                            .contentTransition(.opacity)
                    }

                    storageProgress(disk.progress)

                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                        metric("Used", disk.used)
                        metric("Total", disk.total)
                        metric("Available", disk.available)
                        metric("Percentage", "\(disk.usedPercentDisplay)%")
                    }

                    if let error = storage?.error {
                        warningLine(error)
                    }
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(panelSurface)
            }
        } else if let error = storage?.error {
            warningCard(error)
        }
    }

    private func storageProgress(_ value: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.10))
                Capsule()
                    .fill(premiumBlue)
                    .frame(width: geo.size.width * CGFloat(min(max(value, 0), 1)))
            }
        }
        .frame(height: 6)
        .accessibilityHidden(true)
    }

    // MARK: Daily rows

    private func dailyRow(_ row: NetworkUsageRow) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(row.date)
                    .font(.system(size: 13.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(Color.white)
                    .lineLimit(1)
                Spacer()
                Text(row.total)
                    .font(.system(size: 14, weight: .bold, design: .monospaced))
                    .foregroundStyle(premiumBlue)
                    .lineLimit(1)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    dailyPill("RX \(row.rx)")
                    dailyPill("TX \(row.tx)")
                    dailyPill(row.avgRate)
                }

                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        dailyPill("RX \(row.rx)")
                        dailyPill("TX \(row.tx)")
                    }
                    dailyPill(row.avgRate)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func dailyPill(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5, weight: .semibold, design: .monospaced))
            .foregroundStyle(mutedText)
            .lineLimit(1)
            .minimumScaleFactor(0.72)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity)
            .background(surfaceRaised.opacity(0.7), in: Capsule())
            .overlay(Capsule().stroke(hairline, lineWidth: 1))
    }

    private var rowDivider: some View {
        Rectangle()
            .fill(hairline)
            .frame(height: 1)
            .padding(.leading, 14)
    }

    // MARK: Raw output — terminal-style, kept from the old layout.

    private func rawOutputCard(_ raw: String) -> some View {
        Text(raw)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(Color(red: 0.47, green: 0.92, blue: 0.63))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Color.black.opacity(0.58), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(hairline, lineWidth: 1)
            }
    }

    // MARK: Warnings + shared surfaces

    private func warningLine(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(warningOrange)
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func warningCard(_ text: String) -> some View {
        warningLine(text)
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(surface, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(warningOrange.opacity(0.34), lineWidth: 1)
            }
    }

    private var panelSurface: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(surface)
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(hairline, lineWidth: 1)
            }
    }

    // MARK: Refresh (unchanged behavior)

    private func startAutoRefresh() {
        guard autoRefreshTask == nil else { return }
        autoRefreshTask = Task {
            await loadUsage()
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 12_000_000_000)
                if Task.isCancelled { break }
                await loadUsage()
            }
        }
    }

    private func stopAutoRefresh() {
        autoRefreshTask?.cancel()
        autoRefreshTask = nil
    }

    @MainActor
    private func loadUsage() async {
        if isLoading {
            return
        }
        refreshGeneration += 1
        let generation = refreshGeneration
        isLoading = true
        defer {
            if generation == refreshGeneration {
                isLoading = false
            }
        }
        if usage == nil {
            errorMessage = nil
        }
        do {
            let response = try await NetworkUsageAPI.fetch()
            guard generation == refreshGeneration else { return }
            usage = response
            errorMessage = nil
        } catch is CancellationError {
            return
        } catch {
            guard generation == refreshGeneration else { return }
            errorMessage = usage == nil ? "Could not load network usage." : "Last refresh failed."
        }
    }
}

/// Live indicator: solid dot with a slow expanding pulse ring — the same
/// decorative pattern as the Home status orb. Transform/opacity only and
/// disabled entirely under Reduce Motion.
private struct LivePulseDot: View {
    let color: Color
    let animates: Bool

    @State private var pulsing = false

    var body: some View {
        ZStack {
            Circle()
                .stroke(color.opacity(0.55), lineWidth: 1)
                .frame(width: 9, height: 9)
                .scaleEffect(pulsing ? 2.1 : 1)
                .opacity(pulsing ? 0 : 0.8)

            Circle()
                .fill(color)
                .frame(width: 9, height: 9)
        }
        .frame(width: 20, height: 20)
        .onAppear {
            guard animates else { return }
            withAnimation(.easeOut(duration: 1.8).repeatForever(autoreverses: false)) {
                pulsing = true
            }
        }
        .accessibilityHidden(true)
    }
}

/// Static dot-grid texture for the monitor panel — same quiet infrastructure
/// nod as the Home server panel. Drawn once per layout, no hit testing.
private struct DotGridTexture: View {
    var body: some View {
        Canvas { context, size in
            let step: CGFloat = 19
            var y: CGFloat = 8
            while y < size.height {
                var x: CGFloat = 8
                while x < size.width {
                    context.fill(
                        Path(ellipseIn: CGRect(x: x, y: y, width: 1.6, height: 1.6)),
                        with: .color(.white.opacity(0.045))
                    )
                    x += step
                }
                y += step
            }
        }
        .allowsHitTesting(false)
    }
}

private enum NetworkUsageAPI {
    static func fetch() async throws -> NetworkUsageResponse {
        guard let url = URL(string: "\(CompletedFilesAPI.baseURL)/api/network-usage") else {
            throw URLError(.badURL)
        }

        // Dead Tailscale sockets after a foreground wake should fail fast so
        // the 12s auto-refresh loop can retry, instead of hanging for the
        // default 60s request timeout.
        var request = URLRequest(url: url)
        request.timeoutInterval = 10

        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }

        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(NetworkUsageResponse.self, from: data)
    }
}

private struct NetworkUsageResponse: Decodable {
    let status: String
    let interface: String
    let updatedAt: String
    let format: String?
    let month: NetworkUsageRow?
    let today: NetworkUsageRow?
    let daily: [NetworkUsageRow]
    let raw: String?
    let storage: StorageUsage?

    var updatedAtDisplay: String {
        guard let date = ISO8601DateFormatter().date(from: updatedAt) else {
            return updatedAt
        }
        return date.formatted(date: .abbreviated, time: .shortened)
    }

    var latestDailyRows: [NetworkUsageRow] {
        Array(daily.sorted { $0.date > $1.date }.prefix(10))
    }

    private enum CodingKeys: String, CodingKey {
        case status
        case interface
        case updatedAt
        case format
        case month
        case today
        case daily
        case raw
        case storage
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        status = try container.decode(String.self, forKey: .status)
        interface = try container.decode(String.self, forKey: .interface)
        updatedAt = try container.decode(String.self, forKey: .updatedAt)
        format = try container.decodeIfPresent(String.self, forKey: .format)
        month = try container.decodeIfPresent(NetworkUsageRow.self, forKey: .month)
        today = try container.decodeIfPresent(NetworkUsageRow.self, forKey: .today)
        daily = try container.decodeIfPresent([NetworkUsageRow].self, forKey: .daily) ?? []
        raw = try container.decodeIfPresent(String.self, forKey: .raw)
        storage = try container.decodeIfPresent(StorageUsage.self, forKey: .storage)
    }
}

private struct StorageUsage: Decodable {
    let status: String
    let disks: [StorageDisk]
    let error: String?

    var rootDisk: StorageDisk? {
        disks.first { $0.path == "/" } ?? disks.first
    }
}

private struct StorageDisk: Decodable, Identifiable {
    let path: String
    let mount: String
    let usedBytes: Int64
    let totalBytes: Int64
    let availableBytes: Int64
    let usedPercent: Double
    let used: String
    let total: String
    let available: String

    var id: String { "\(mount)-\(path)" }

    var progress: Double {
        min(max(usedPercent / 100, 0), 1)
    }

    var usedPercentDisplay: String {
        usedPercent.formatted(.number.precision(.fractionLength(0...1)))
    }
}

private struct NetworkUsageRow: Decodable, Identifiable {
    let date: String
    let rx: String
    let tx: String
    let total: String
    let avgRate: String
    let estimatedTotal: String?

    var id: String { date }
}

#Preview {
    NetworkUsageView()
}
