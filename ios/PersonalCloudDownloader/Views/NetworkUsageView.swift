import SwiftUI

struct NetworkUsageView: View {
    @Environment(\.scenePhase) private var scenePhase
    @State private var usage: NetworkUsageResponse?
    @State private var isLoading = false
    @State private var errorMessage: String?
    @State private var autoRefreshTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            Group {
                if isLoading && usage == nil {
                    ProgressView("Loading network usage...")
                } else if let usage {
                    usageContent(usage)
                } else {
                    unavailableView
                }
            }
            .navigationTitle("Network")
            .refreshable {
                await loadUsage()
            }
            .onAppear {
                startAutoRefresh()
            }
            .onDisappear {
                stopAutoRefresh()
            }
            .onChange(of: scenePhase) { phase in
                if phase == .active {
                    Task {
                        await loadUsage()
                    }
                }
            }
        }
    }

    private var unavailableView: some View {
        VStack(spacing: 12) {
            Image(systemName: "antenna.radiowaves.left.and.right.slash")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            Text("Network usage unavailable")
                .font(.headline)
            Text(errorMessage ?? "Pull to refresh or check the server connection.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private func usageContent(_ usage: NetworkUsageResponse) -> some View {
        if let raw = usage.raw, !raw.isEmpty {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header(usage)
                    storageCard(usage.storage)
                    Text(raw)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.green)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .background(.black, in: RoundedRectangle(cornerRadius: 8))
                }
                .padding()
            }
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    header(usage)
                    storageCard(usage.storage)

                    if let month = usage.month {
                        usageSection(title: "Current Month", row: month, showEstimate: true)
                    }

                    if let today = usage.today {
                        usageSection(title: "Today", row: today, showEstimate: false)
                    }

                    if !usage.daily.isEmpty {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("Daily Usage")
                                .font(.headline)
                            VStack(spacing: 0) {
                                ForEach(usage.daily) { row in
                                    dailyRow(row)
                                    if row.id != usage.daily.last?.id {
                                        Divider()
                                    }
                                }
                            }
                            .background(.background, in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
                .padding()
            }
        }
    }

    private func header(_ usage: NetworkUsageResponse) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Interface \(usage.interface)")
                .font(.headline)
            Text("Updated \(usage.updatedAtDisplay)")
                .font(.caption)
                .foregroundStyle(.secondary)
            if isLoading {
                Text("Refreshing...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func usageSection(title: String, row: NetworkUsageRow, showEstimate: Bool) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
            HStack(spacing: 10) {
                metric("RX", row.rx)
                metric("TX", row.tx)
                metric("Total", row.total)
            }
            metric("Avg Rate", row.avgRate)
            if showEstimate, let estimated = row.estimatedTotal {
                metric("Est. Monthly Total", estimated)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background, in: RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func storageCard(_ storage: StorageUsage?) -> some View {
        if let disk = storage?.rootDisk {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Storage")
                            .font(.headline)
                        Text("\(disk.mount) (\(disk.path))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Text("\(disk.usedPercentDisplay)%")
                        .font(.subheadline.monospacedDigit().weight(.semibold))
                }

                ProgressView(value: disk.progress)
                    .tint(.blue)

                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                    metric("Used", disk.used)
                    metric("Total", disk.total)
                    metric("Available", disk.available)
                    metric("Percentage", "\(disk.usedPercentDisplay)%")
                }

                if let error = storage?.error {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background, in: RoundedRectangle(cornerRadius: 8))
        } else if let error = storage?.error {
            Text(error)
                .font(.caption)
                .foregroundStyle(.orange)
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background, in: RoundedRectangle(cornerRadius: 8))
        }
    }

    private func metric(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func dailyRow(_ row: NetworkUsageRow) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(row.date)
                    .font(.subheadline.weight(.semibold))
                Spacer()
                Text(row.total)
                    .font(.subheadline.monospacedDigit())
            }
            HStack {
                Text("RX \(row.rx)")
                Spacer()
                Text("TX \(row.tx)")
                Spacer()
                Text(row.avgRate)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
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
        isLoading = true
        if usage == nil {
            errorMessage = nil
        }
        do {
            usage = try await NetworkUsageAPI.fetch()
            errorMessage = nil
        } catch {
            errorMessage = usage == nil ? "Could not load network usage." : "Could not refresh network usage."
        }
        isLoading = false
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
