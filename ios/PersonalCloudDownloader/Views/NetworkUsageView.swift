import SwiftUI

struct NetworkUsageView: View {
    @State private var usage: NetworkUsageResponse?
    @State private var isLoading = false
    @State private var errorMessage: String?

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
            .task {
                if usage == nil {
                    await loadUsage()
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

    @MainActor
    private func loadUsage() async {
        isLoading = true
        errorMessage = nil
        do {
            usage = try await NetworkUsageAPI.fetch()
        } catch {
            errorMessage = "Could not load network usage."
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
