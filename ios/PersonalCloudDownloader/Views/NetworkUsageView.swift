import SwiftUI

struct NetworkUsageView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var usage: NetworkUsageResponse?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var autoRefreshTask: Task<Void, Never>?
    @State private var isVisible = false
    @State private var refreshGeneration = 0
    private let screenBackground = Color(red: 0.015, green: 0.035, blue: 0.075)
    private let panelBackground = Color(red: 0.025, green: 0.075, blue: 0.145)
    private let elevatedPanel = Color(red: 0.035, green: 0.105, blue: 0.205)
    private let cardStroke = Color(red: 0.18, green: 0.34, blue: 0.58)
    private let mutedText = Color(red: 0.62, green: 0.68, blue: 0.80)
    private let accentBlue = Color(red: 0.28, green: 0.58, blue: 1.0)
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
                if phase == .active && isVisible {
                    Task {
                        await loadUsage()
                    }
                }
            }
        }
    }

    private var networkBackground: some View {
        ZStack {
            screenBackground.ignoresSafeArea()
            LinearGradient(
                colors: [
                    Color(red: 0.025, green: 0.105, blue: 0.22),
                    screenBackground,
                    Color(red: 0.0, green: 0.012, blue: 0.03)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
            RadialGradient(
                colors: [accentBlue.opacity(0.16), .clear],
                center: .topLeading,
                startRadius: 16,
                endRadius: 300
            )
            .ignoresSafeArea()
        }
    }

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .tint(accentBlue)
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
                .font(.system(size: 38, weight: .semibold))
                .foregroundStyle(mutedText)
                .frame(width: 76, height: 76)
                .background(panelBackground.opacity(0.82), in: Circle())
                .overlay(Circle().stroke(cardStroke.opacity(0.42), lineWidth: 1))
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
                VStack(alignment: .leading, spacing: 18) {
                    header(usage)
                    storageCard(usage.storage)
                    rawOutputCard(raw)
                }
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 34)
            }
            .background(networkBackground)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header(usage)
                    storageCard(usage.storage)

                    if let month = usage.month {
                        usageSection(title: "Current Month", row: month, showEstimate: true)
                    }

                    if let today = usage.today {
                        usageSection(title: "Today", row: today, showEstimate: false)
                    }

                    let dailyRows = usage.latestDailyRows
                    if !dailyRows.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Text("Daily Usage")
                                .font(.system(size: 19, weight: .bold, design: .rounded))
                                .foregroundStyle(.white)
                            VStack(spacing: 0) {
                                ForEach(dailyRows) { row in
                                    dailyRow(row)
                                    if row.id != dailyRows.last?.id {
                                        Divider()
                                            .overlay(Color.white.opacity(0.10))
                                            .padding(.leading, 16)
                                    }
                                }
                            }
                            .background(panelBackground.opacity(0.74), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 18, style: .continuous)
                                    .stroke(cardStroke.opacity(0.34), lineWidth: 1)
                            }
                        }
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 18)
                .padding(.bottom, 34)
            }
            .background(networkBackground)
        }
    }

    private func header(_ usage: NetworkUsageResponse) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 14) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(accentBlue)
                    .frame(width: 58, height: 58)
                    .background(accentBlue.opacity(0.16), in: Circle())
                    .overlay(Circle().stroke(accentBlue.opacity(0.34), lineWidth: 1))

                VStack(alignment: .leading, spacing: 5) {
                    Text("Network")
                        .font(.system(size: 34, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text("Interface \(usage.interface)")
                        .font(.system(size: 16, weight: .medium))
                        .foregroundStyle(mutedText)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                }

                Spacer(minLength: 6)
            }

            HStack(spacing: 10) {
                statusChip(icon: isLoading ? "arrow.triangle.2.circlepath" : "clock", text: isLoading ? "Refreshing" : "Updated \(usage.updatedAtDisplay)")
            }

            if isLoading {
                Text("Refreshing latest counters")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(mutedText)
            }
            if let errorMessage {
                warningLine(errorMessage)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func statusChip(icon: String, text: String) -> some View {
        Label(text, systemImage: icon)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(mutedText)
            .lineLimit(1)
            .minimumScaleFactor(0.78)
            .padding(.horizontal, 11)
            .padding(.vertical, 8)
            .background(panelBackground.opacity(0.78), in: Capsule())
            .overlay(Capsule().stroke(cardStroke.opacity(0.30), lineWidth: 1))
    }

    private func usageSection(title: String, row: NetworkUsageRow, showEstimate: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.system(size: 19, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 108), spacing: 10)], spacing: 10) {
                metric("RX", row.rx)
                metric("TX", row.tx)
                metric("Total", row.total)
                metric("Avg Rate", row.avgRate)
                if showEstimate, let estimated = row.estimatedTotal {
                    metric("Est. Monthly Total", estimated)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(panelBackground.opacity(0.74), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(cardStroke.opacity(0.34), lineWidth: 1)
        }
    }

    @ViewBuilder
    private func storageCard(_ storage: StorageUsage?) -> some View {
        if let disk = storage?.rootDisk {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "internaldrive.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(accentBlue)
                        .frame(width: 44, height: 44)
                        .background(accentBlue.opacity(0.15), in: Circle())

                    VStack(alignment: .leading, spacing: 4) {
                        Text("Storage")
                            .font(.system(size: 19, weight: .bold, design: .rounded))
                            .foregroundStyle(.white)
                        Text("\(disk.mount) (\(disk.path))")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(mutedText)
                            .lineLimit(1)
                            .minimumScaleFactor(0.78)
                    }
                    Spacer()
                    Text("\(disk.usedPercentDisplay)%")
                        .font(.system(size: 17, weight: .bold, design: .rounded).monospacedDigit())
                        .foregroundStyle(.white)
                }

                storageProgress(disk.progress)

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    metric("Used", disk.used)
                    metric("Total", disk.total)
                    metric("Available", disk.available)
                    metric("Percentage", "\(disk.usedPercentDisplay)%")
                }

                if let error = storage?.error {
                    warningLine(error)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                LinearGradient(
                    colors: [elevatedPanel.opacity(0.90), panelBackground.opacity(0.78)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 22, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(cardStroke.opacity(0.42), lineWidth: 1)
            }
        } else if let error = storage?.error {
            warningCard(error)
        }
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(mutedText)
                .lineLimit(1)
            Text(value)
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(elevatedPanel.opacity(0.52), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(cardStroke.opacity(0.22), lineWidth: 1)
        }
    }

    private func dailyRow(_ row: NetworkUsageRow) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(row.date)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer()
                Text(row.total)
                    .font(.system(size: 15, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }
            HStack(spacing: 8) {
                dailyPill("RX \(row.rx)")
                dailyPill("TX \(row.tx)")
                dailyPill(row.avgRate)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 13)
    }

    private func dailyPill(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(mutedText)
            .lineLimit(1)
            .minimumScaleFactor(0.72)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .frame(maxWidth: .infinity)
            .background(elevatedPanel.opacity(0.45), in: Capsule())
    }

    private func storageProgress(_ value: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.12))
                Capsule()
                    .fill(
                        LinearGradient(
                            colors: [accentBlue, Color(red: 0.36, green: 0.80, blue: 1.0)],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(width: geo.size.width * CGFloat(min(max(value, 0), 1)))
            }
        }
        .frame(height: 7)
    }

    private func rawOutputCard(_ raw: String) -> some View {
        Text(raw)
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(Color(red: 0.47, green: 0.92, blue: 0.63))
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Color.black.opacity(0.58), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.white.opacity(0.10), lineWidth: 1)
            }
    }

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
            .background(panelBackground.opacity(0.72), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(warningOrange.opacity(0.34), lineWidth: 1)
            }
    }

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

private enum NetworkUsageAPI {
    static func fetch() async throws -> NetworkUsageResponse {
        guard let url = URL(string: "\(CompletedFilesAPI.baseURL)/api/network-usage") else {
            throw URLError(.badURL)
        }

        let (data, response) = try await URLSession.shared.data(from: url)
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
