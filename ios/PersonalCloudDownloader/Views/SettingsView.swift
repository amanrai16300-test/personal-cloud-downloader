import SwiftUI

/// CloudBox Settings: the app's control hub, restyled to match the Home
/// dashboard and floating tab bar — flat raised navy panels, hairline strokes,
/// tinted icon chips, monospaced endpoint values. Same content and the same
/// single action (Open Tailscale) as the old Form; only the presentation
/// changed.
struct SettingsView: View {
    @Environment(\.openURL) private var openURL

    private let tailscaleIP = "100.95.39.107"
    private let downloaderURL = "http://100.95.39.107:8090/app/"
    private let qbittorrentURL = "http://100.95.39.107:8080"
    private let filesURL = "http://100.95.39.107:8090/files/"

    // MARK: Palette — mirrored from the Home redesign tokens.
    private let screenBackground = Color(red: 0.008, green: 0.022, blue: 0.055)
    private let surface = Color(red: 0.035, green: 0.065, blue: 0.125)
    private let surfaceRaised = Color(red: 0.055, green: 0.095, blue: 0.175)
    private let hairline = Color.white.opacity(0.08)
    private let mutedText = Color(red: 0.56, green: 0.64, blue: 0.78)
    private let premiumBlue = Color(red: 0.30, green: 0.59, blue: 1.0)

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    identityPanel

                    section("Server Endpoints") {
                        endpointsPanel
                    }

                    section("Privacy") {
                        privacyPanel
                    }

                    section("Tailscale") {
                        tailscalePanel
                    }
                }
                .padding(.horizontal, 18)
                .padding(.top, 14)
                .padding(.bottom, 34)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(settingsBackground)
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarColorScheme(.dark, for: .navigationBar)
        }
    }

    // MARK: Background — same recipe as Home: deep navy, one accent bloom.

    private var settingsBackground: some View {
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

    // MARK: Section scaffold — tracked uppercase header + content.

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

    // MARK: Identity panel

    private var identityPanel: some View {
        HStack(spacing: 13) {
            ZStack {
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [premiumBlue, Color(red: 0.07, green: 0.22, blue: 0.55)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 46, height: 46)
                    .overlay {
                        RoundedRectangle(cornerRadius: 13, style: .continuous)
                            .stroke(Color.white.opacity(0.22), lineWidth: 1)
                    }

                Image(systemName: "cloud.fill")
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(Color.white)
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text("Personal Cloud Downloader")
                    .font(.system(size: 18, weight: .bold, design: .rounded))
                    .foregroundStyle(Color.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Text("CloudBox · private by Tailscale")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(mutedText)
            }

            Spacer(minLength: 0)
        }
        .padding(.top, 4)
        .padding(.horizontal, 2)
    }

    // MARK: Server endpoints — one panel, hairline-divided rows, mono values.

    private var endpointsPanel: some View {
        VStack(spacing: 0) {
            endpointRow(
                icon: "lock.shield.fill",
                label: "Oracle Tailscale IP",
                value: tailscaleIP,
                tint: premiumBlue
            )
            rowDivider
            endpointRow(
                icon: "arrow.down.circle.fill",
                label: "Downloader",
                value: downloaderURL,
                tint: premiumBlue
            )
            rowDivider
            endpointRow(
                icon: "magnet",
                label: "qBittorrent",
                value: qbittorrentURL,
                tint: .orange
            )
            rowDivider
            endpointRow(
                icon: "externaldrive.fill",
                label: "Files",
                value: filesURL,
                tint: Color(red: 0.28, green: 0.76, blue: 0.70)
            )
        }
        .background(panelSurface)
    }

    private var rowDivider: some View {
        Rectangle()
            .fill(hairline)
            .frame(height: 1)
            .padding(.leading, 64)
    }

    private func endpointRow(icon: String, label: String, value: String, tint: Color) -> some View {
        HStack(spacing: 12) {
            iconChip(icon, tint: tint)

            VStack(alignment: .leading, spacing: 3) {
                Text(label)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(mutedText)

                Text(value)
                    .font(.system(size: 13.5, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.white.opacity(0.94))
                    .lineLimit(1)
                    .minimumScaleFactor(0.62)
                    .textSelection(.enabled)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: Privacy panel

    private var privacyPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                iconChip("lock.shield", tint: premiumBlue)

                Text("This app works only through Tailscale / private network.")
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.94))
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Do not expose Oracle ports publicly.")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(mutedText)
                .padding(.leading, 50)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(panelSurface)
    }

    // MARK: Tailscale panel — helper note + the action row.

    private var tailscalePanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Open Tailscale and confirm the VPN is connected before using the app.")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(mutedText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 2)

            Button {
                if let url = URL(string: "tailscale://") {
                    openURL(url)
                }
            } label: {
                HStack(spacing: 13) {
                    ZStack(alignment: .bottomTrailing) {
                        Image(systemName: "globe")
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(Color(red: 0.62, green: 0.80, blue: 1.0))
                            .frame(width: 46, height: 46)
                            .background(premiumBlue.opacity(0.14), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 13, style: .continuous)
                                    .stroke(premiumBlue.opacity(0.32), lineWidth: 1)
                            }

                        Image(systemName: "lock.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(Color.white)
                            .frame(width: 18, height: 18)
                            .background(premiumBlue, in: Circle())
                            .offset(x: 5, y: 5)
                    }
                    .accessibilityHidden(true)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("Open Tailscale")
                            .font(.system(size: 16, weight: .bold, design: .rounded))
                            .foregroundStyle(Color.white)
                            .lineLimit(1)

                        Text("Private connection / VPN route")
                            .font(.system(size: 12.5, weight: .medium))
                            .foregroundStyle(mutedText)
                            .lineLimit(1)
                    }
                    .layoutPriority(1)

                    Spacer(minLength: 8)

                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(premiumBlue)
                        .frame(width: 34, height: 34)
                        .background(premiumBlue.opacity(0.12), in: Circle())
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 15)
                .padding(.vertical, 13)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(surfaceRaised, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(premiumBlue.opacity(0.30), lineWidth: 1)
                }
                .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
            }
            .buttonStyle(SettingsPressStyle())
        }
    }

    // MARK: Shared pieces

    /// Panel surface shared by the endpoint and privacy groups.
    private var panelSurface: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(surface)
            .overlay {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .stroke(hairline, lineWidth: 1)
            }
    }

    /// Tinted icon chip, same recipe as the Home metric cards.
    private func iconChip(_ systemName: String, tint: Color) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 16, weight: .bold))
            .foregroundStyle(tint)
            .frame(width: 38, height: 38)
            .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(tint.opacity(0.30), lineWidth: 1)
            }
            .accessibilityHidden(true)
    }
}

/// Press feedback consistent with the Home action row and tab bar.
private struct SettingsPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .opacity(configuration.isPressed ? 0.92 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

#Preview {
    SettingsView()
}
