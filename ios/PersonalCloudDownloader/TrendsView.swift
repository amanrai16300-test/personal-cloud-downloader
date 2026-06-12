import Foundation
import SafariServices
import SwiftUI
import UIKit

struct TrendsView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var viewModel = TrendsViewModel()
    @State private var isVisible = false

    // Palette mirrored from the Home redesign tokens.
    private let background = Color(red: 0.008, green: 0.022, blue: 0.055)
    private let surface = Color(red: 0.035, green: 0.065, blue: 0.125)
    private let hairline = Color.white.opacity(0.08)
    private let muted = Color(red: 0.56, green: 0.64, blue: 0.78)
    private let premiumBlue = Color(red: 0.30, green: 0.59, blue: 1.0)

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
        .onAppear {
            isVisible = true
        }
        .onDisappear {
            isVisible = false
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active && isVisible {
                Task {
                    try? await Task.sleep(nanoseconds: 750_000_000)
                    guard !Task.isCancelled else { return }
                    await viewModel.refresh()
                }
            }
        }
    }

    private var trendsBackground: some View {
        ZStack {
            background.ignoresSafeArea()
            RadialGradient(
                colors: [premiumBlue.opacity(0.12), .clear],
                center: .init(x: 0.9, y: -0.05),
                startRadius: 10,
                endRadius: 380
            )
            .ignoresSafeArea()
        }
    }

    /// Discovery panel header: tracked tag, title, and a 6-hour cadence footer
    /// with the monospaced last-update time — the same panel anatomy as the
    /// Home server panel and Network monitor.
    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                Text("DISCOVERY RADAR")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(1.6)
                    .foregroundStyle(premiumBlue)

                Spacer(minLength: 8)

                Text("TMDB")
                    .font(.system(size: 11, weight: .bold))
                    .tracking(1.0)
                    .foregroundStyle(muted.opacity(0.85))
            }
            .padding(.bottom, 12)

            Text("Fresh picks")
                .font(.system(size: 24, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.78)
                .padding(.bottom, 12)

            Rectangle()
                .fill(hairline)
                .frame(height: 1)
                .padding(.bottom, 10)

            HStack(spacing: 6) {
                Image(systemName: "clock")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(muted)
                    .accessibilityHidden(true)

                Text("Updated every 6 hours")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(muted)

                if let updatedAt = viewModel.trends?.updatedAt {
                    Spacer(minLength: 8)

                    Text(formattedUpdatedAt(updatedAt))
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(Color.white.opacity(0.92))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            ZStack {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .fill(surface)

                RadialGradient(
                    colors: [premiumBlue.opacity(0.14), .clear],
                    center: .topTrailing,
                    startRadius: 4,
                    endRadius: 220
                )
                .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [premiumBlue.opacity(0.40), hairline],
                        startPoint: .topTrailing,
                        endPoint: .bottomLeading
                    ),
                    lineWidth: 1
                )
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
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                Text(title.uppercased())
                    .font(.system(size: 11, weight: .bold))
                    .tracking(1.6)
                    .foregroundStyle(premiumBlue)

                Spacer()

                Text("\(items.count)")
                    .font(.system(size: 11.5, weight: .bold, design: .monospaced))
                    .foregroundStyle(muted)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(surface, in: Capsule())
                    .overlay(Capsule().stroke(hairline, lineWidth: 1))
            }
            .padding(.horizontal, 2)

            if items.isEmpty {
                Text("No titles available.")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(muted)
                    .frame(maxWidth: .infinity, minHeight: 84, alignment: .center)
                    .background(surface, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .stroke(hairline, lineWidth: 1)
                    }
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
                .tint(premiumBlue)
            Text("Loading trends...")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(muted)
        }
        .frame(maxWidth: .infinity, minHeight: 190)
        .background(surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(hairline, lineWidth: 1)
        }
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
            .tint(premiumBlue)
        }
        .frame(maxWidth: .infinity, minHeight: 220)
        .padding(18)
        .background(surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(hairline, lineWidth: 1)
        }
    }

    private var emptyState: some View {
        Text("No trend data available.")
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(muted)
            .frame(maxWidth: .infinity, minHeight: 160)
            .background(surface, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 20, style: .continuous)
                    .stroke(hairline, lineWidth: 1)
            }
    }
}

private struct TrendCard: View {
    let item: TrendItem

    @State private var trailerSheet: TrailerSheet?

    private let cardWidth: CGFloat = 154
    private let posterHeight: CGFloat = 231
    private let contentHeight: CGFloat = 142
    private let muted = Color(red: 0.56, green: 0.64, blue: 0.78)
    private let premiumBlue = Color(red: 0.30, green: 0.59, blue: 1.0)
    private let ratingGold = Color(red: 1.0, green: 0.84, blue: 0.36)

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
                        .font(.system(size: 12.5, weight: .heavy))
                        .monospacedDigit()
                        .foregroundStyle(ratingGold)

                    Spacer(minLength: 4)

                    Text(item.releaseYear ?? "N/A")
                        .font(.system(size: 12.5, weight: .bold, design: .monospaced))
                        .foregroundStyle(muted)
                }

                if let trailerURL = item.trailerURL {
                    Button {
                        trailerSheet = TrailerSheet(url: trailerURL)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 11, weight: .heavy))
                            Text("Trailer")
                                .lineLimit(1)
                                .minimumScaleFactor(0.86)
                        }
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(premiumBlue)
                            .frame(maxWidth: .infinity)
                            .frame(height: 34)
                            .background(premiumBlue.opacity(0.13), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 10, style: .continuous)
                                    .stroke(premiumBlue.opacity(0.32), lineWidth: 1)
                            }
                            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    .buttonStyle(TrendPressStyle())
                }
            }
            .padding(.horizontal, 10)
            .padding(.bottom, 14)
            .frame(height: contentHeight, alignment: .top)
        }
        .frame(width: cardWidth, alignment: .top)
        .background(Color(red: 0.055, green: 0.105, blue: 0.175), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.white.opacity(0.10), lineWidth: 1)
        }
        .shadow(color: Color.black.opacity(0.20), radius: 12, y: 8)
        .sheet(item: $trailerSheet) { sheet in
            SafariView(url: sheet.url)
                .ignoresSafeArea()
        }
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
                    premiumBlue.opacity(0.12),
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

/// Press feedback for the trailer action, consistent with the press styles
/// used across the redesigned CloudBox screens.
private struct TrendPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.88 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

private struct TrailerSheet: Identifiable {
    let id = UUID()
    let url: URL
}

private struct SafariView: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let controller = SFSafariViewController(url: url)
        controller.preferredBarTintColor = UIColor(red: 0.008, green: 0.022, blue: 0.055, alpha: 1.0)
        controller.preferredControlTintColor = UIColor(red: 0.30, green: 0.59, blue: 1.0, alpha: 1.0)
        return controller
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
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
