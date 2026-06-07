import Foundation
import SwiftUI
import UIKit

struct TrendsView: View {
    @StateObject private var viewModel = TrendsViewModel()

    private let background = Color(red: 0.015, green: 0.035, blue: 0.075)
    private let muted = Color(red: 0.62, green: 0.68, blue: 0.80)

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 26) {
                header

                if viewModel.isLoading && viewModel.trends == nil {
                    loadingState
                } else if let errorMessage = viewModel.errorMessage, viewModel.trends == nil {
                    errorState(errorMessage)
                } else if let trends = viewModel.trends {
                    content(for: trends)
                } else {
                    emptyState
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 18)
            .padding(.bottom, 34)
        }
        .background(trendsBackground)
        .navigationTitle("Trends")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarColorScheme(.dark, for: .navigationBar)
        .task {
            await viewModel.loadIfNeeded()
        }
        .refreshable {
            await viewModel.refresh()
        }
    }

    private var trendsBackground: some View {
        ZStack {
            background.ignoresSafeArea()
            LinearGradient(
                colors: [
                    Color(red: 0.025, green: 0.10, blue: 0.18),
                    background,
                    Color(red: 0.0, green: 0.01, blue: 0.025)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Fresh picks")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)

                Spacer(minLength: 12)

                Text("Trends")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.mint.opacity(0.90))
                    .textCase(.uppercase)
                    .tracking(0.8)
            }

            HStack(spacing: 8) {
                Label("Updated every 6 hours", systemImage: "clock")
                if let updatedAt = viewModel.trends?.updatedAt {
                    Text("•")
                        .foregroundStyle(muted.opacity(0.58))
                    Text("Last \(formattedUpdatedAt(updatedAt))")
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                }
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(muted.opacity(0.92))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(
            LinearGradient(
                colors: [
                    Color.mint.opacity(0.10),
                    Color(red: 0.035, green: 0.105, blue: 0.205).opacity(0.90)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 24, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.mint.opacity(0.34), lineWidth: 1.1)
        }
    }

    private func formattedUpdatedAt(_ value: String) -> String {
        let parser = ISO8601DateFormatter()
        parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        let date = parser.date(from: value) ?? ISO8601DateFormatter().date(from: value)
        guard let date else { return "recently" }

        return date.formatted(.dateTime.month(.abbreviated).day().hour().minute())
    }

    private func content(for trends: TrendsResponse) -> some View {
        VStack(alignment: .leading, spacing: 30) {
            trendSection("Global Movies", items: trends.globalMovies)
            trendSection("Global Series", items: trends.globalSeries)
            trendSection("India Movies", items: trends.indiaMovies)
            trendSection("India Series", items: trends.indiaSeries)

            if let errorMessage = viewModel.errorMessage {
                Text(errorMessage)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.orange.opacity(0.92))
                    .padding(.top, 2)
            }
        }
    }

    private func trendSection(_ title: String, items: [TrendItem]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)

                Spacer()

                Text("\(items.count)")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(muted)
            }

            if items.isEmpty {
                Text("No titles available.")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(muted)
                    .frame(maxWidth: .infinity, minHeight: 84, alignment: .center)
                    .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 14) {
                        ForEach(items) { item in
                            TrendCard(item: item)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private var loadingState: some View {
        VStack(spacing: 14) {
            ProgressView()
                .tint(.mint)
            Text("Loading trends...")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(muted)
        }
        .frame(maxWidth: .infinity, minHeight: 190)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func errorState(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.orange)

            Text("Trends unavailable")
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .foregroundStyle(.white)

            Text(message)
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(muted)
                .multilineTextAlignment(.center)

            Button {
                Task { await viewModel.refresh() }
            } label: {
                Text("Try Again")
                    .font(.system(size: 15, weight: .bold))
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .tint(.mint)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
        .padding(18)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private var emptyState: some View {
        Text("No trend data available.")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(muted)
            .frame(maxWidth: .infinity, minHeight: 160)
            .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

private struct TrendCard: View {
    let item: TrendItem

    private let cardWidth: CGFloat = 154
    private let posterHeight: CGFloat = 231
    private let muted = Color(red: 0.62, green: 0.68, blue: 0.80)

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            poster

            VStack(alignment: .leading, spacing: 7) {
                Text(item.title)
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .minimumScaleFactor(0.82)
                    .frame(minHeight: 38, alignment: .topLeading)

                HStack(spacing: 8) {
                    Text(item.ratingText)
                        .font(.system(size: 13, weight: .heavy))
                        .foregroundStyle(Color(red: 1.0, green: 0.84, blue: 0.36))

                    Spacer(minLength: 4)

                    Text(item.releaseYear ?? "N/A")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(muted)
                }

                if let trailerURL = item.trailerURL {
                    Button {
                        UIApplication.shared.open(trailerURL)
                    } label: {
                        Label("Trailer", systemImage: "play.fill")
                            .font(.system(size: 13, weight: .bold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.bordered)
                    .tint(.mint)
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 12)
        }
        .frame(width: cardWidth, alignment: .top)
        .background(Color(red: 0.055, green: 0.105, blue: 0.175), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.20), radius: 12, y: 8)
    }

    @ViewBuilder
    private var poster: some View {
        if let posterURL = item.posterURL {
            AsyncImage(url: posterURL) { phase in
                switch phase {
                case .empty:
                    posterPlaceholder(text: "Loading")
                        .overlay {
                            ProgressView()
                                .tint(.white)
                        }
                case .success(let image):
                    image
                        .resizable()
                        .scaledToFill()
                case .failure:
                    posterPlaceholder(text: "No poster")
                @unknown default:
                    posterPlaceholder(text: "No poster")
                }
            }
            .frame(width: cardWidth, height: posterHeight)
            .clipped()
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        } else {
            posterPlaceholder(text: "No poster")
                .frame(width: cardWidth, height: posterHeight)
        }
    }

    private func posterPlaceholder(text: String) -> some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color.white.opacity(0.08),
                    Color.mint.opacity(0.12),
                    Color.white.opacity(0.05)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            VStack(spacing: 8) {
                Image(systemName: "photo")
                    .font(.system(size: 28, weight: .semibold))
                Text(text)
                    .font(.system(size: 13, weight: .bold))
            }
            .foregroundStyle(Color.white.opacity(0.58))
        }
        .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

@MainActor
private final class TrendsViewModel: ObservableObject {
    @Published var trends: TrendsResponse?
    @Published var isLoading = false
    @Published var errorMessage: String?

    func loadIfNeeded() async {
        guard trends == nil else { return }
        await refresh()
    }

    func refresh() async {
        isLoading = true
        errorMessage = nil

        do {
            trends = try await TrendsAPI.fetchTrends()
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }
}

private enum TrendsAPI {
    static func fetchTrends() async throws -> TrendsResponse {
        guard let url = URL(string: "\(CompletedFilesAPI.baseURL)/api/trends") else {
            throw URLError(.badURL)
        }

        let (data, response) = try await URLSession.shared.data(from: url)

        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw URLError(.badServerResponse)
        }

        if let errorPayload = try? JSONDecoder().decode(TrendsErrorResponse.self, from: data) {
            throw TrendsAPIError.server(errorPayload.error)
        }

        return try JSONDecoder().decode(TrendsResponse.self, from: data)
    }
}

private struct TrendsErrorResponse: Decodable {
    let error: String
}

private enum TrendsAPIError: LocalizedError {
    case server(String)

    var errorDescription: String? {
        switch self {
        case .server(let message):
            return message
        }
    }
}

private struct TrendsResponse: Decodable {
    let updatedAt: String
    let globalMovies: [TrendItem]
    let globalSeries: [TrendItem]
    let indiaMovies: [TrendItem]
    let indiaSeries: [TrendItem]

    enum CodingKeys: String, CodingKey {
        case updatedAt = "updated_at"
        case globalMovies = "global_movies"
        case globalSeries = "global_series"
        case indiaMovies = "india_movies"
        case indiaSeries = "india_series"
    }
}

private struct TrendItem: Decodable, Identifiable, Hashable {
    let title: String
    let posterURL: URL?
    let rating: Double?
    let releaseYear: String?
    let trailerURL: URL?
    let mediaType: String?
    let language: String?

    var id: String {
        [
            title,
            releaseYear ?? "",
            mediaType ?? "",
            language ?? ""
        ].joined(separator: "|")
    }

    var ratingText: String {
        guard let rating else { return "N/A" }
        return String(format: "TMDB %.1f", rating)
    }

    enum CodingKeys: String, CodingKey {
        case title
        case posterURL = "poster_url"
        case rating
        case releaseYear = "release_year"
        case trailerURL = "trailer_url"
        case mediaType = "media_type"
        case language
    }
}

#Preview {
    NavigationStack {
        TrendsView()
    }
}
