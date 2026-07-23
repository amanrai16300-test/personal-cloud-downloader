import SwiftUI

/// CloudBox Settings: the app's control hub, restyled to match the Home
/// dashboard and floating tab bar — flat raised navy panels, hairline strokes,
/// tinted icon chips, monospaced endpoint values. Same content and the same
/// single action (Open Tailscale) as the old Form; only the presentation
/// changed.
struct SettingsView: View {
    @Environment(\.openURL) private var openURL
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

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
                .font(.caption2.weight(.bold))
                .tracking(1.6)
                .foregroundStyle(premiumBlue)
                .padding(.horizontal, 2)
                .accessibilityAddTraits(.isHeader)

            content()
        }
    }

    // MARK: Identity panel

    private var identityPanel: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 10) {
                    identityIcon
                    identityText
                }
            } else {
                HStack(spacing: 13) {
                    identityIcon
                    identityText
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.top, 4)
        .padding(.horizontal, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Personal Cloud Downloader")
        .accessibilityValue("CloudBox, private by Tailscale")
    }

    private var identityIcon: some View {
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
    }

    private var identityText: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Personal Cloud Downloader")
                .font(.headline.weight(.bold))
                .fontDesign(.rounded)
                .foregroundStyle(Color.white)
                .lineLimit(3)

            Text("CloudBox · private by Tailscale")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(mutedText)
                .lineLimit(3)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Server endpoints — one panel, hairline-divided rows, mono values.

    private var endpointsPanel: some View {
        VStack(spacing: 0) {
            endpointRow(
                icon: "lock.shield.fill",
                label: "Oracle Tailscale IP",
                value: CloudBoxEndpoints.serverHost,
                tint: premiumBlue
            )
            rowDivider
            endpointRow(
                icon: "arrow.down.circle.fill",
                label: "Downloader",
                value: CloudBoxEndpoints.downloaderWebAppURL.absoluteString,
                tint: premiumBlue
            )
            rowDivider
            endpointRow(
                icon: "magnet",
                label: "qBittorrent",
                value: CloudBoxEndpoints.qBittorrentURL.absoluteString,
                tint: .orange
            )
            rowDivider
            endpointRow(
                icon: "externaldrive.fill",
                label: "Files",
                value: CloudBoxEndpoints.filesURL.absoluteString,
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
            .accessibilityHidden(true)
    }

    private func endpointRow(icon: String, label: String, value: String, tint: Color) -> some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 12) {
                        iconChip(icon, tint: tint)
                        endpointLabel(label)
                    }
                    endpointValue(value)
                }
            } else {
                HStack(spacing: 12) {
                    iconChip(icon, tint: tint)
                    VStack(alignment: .leading, spacing: 3) {
                        endpointLabel(label)
                        endpointValue(value)
                    }
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) service endpoint")
        .accessibilityValue(value)
    }

    private func endpointLabel(_ label: String) -> some View {
        Text(label)
            .font(.caption.weight(.semibold))
            .foregroundStyle(mutedText)
            .lineLimit(2)
    }

    private func endpointValue(_ value: String) -> some View {
        Text(value)
            .font(.subheadline.weight(.semibold))
            .fontDesign(.monospaced)
            .foregroundStyle(Color.white.opacity(0.94))
            .lineLimit(4)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    // MARK: Privacy panel

    private var privacyPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Group {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 8) {
                        iconChip("lock.shield", tint: premiumBlue)
                        privacyPrimaryText
                    }
                } else {
                    HStack(spacing: 12) {
                        iconChip("lock.shield", tint: premiumBlue)
                        privacyPrimaryText
                    }
                }
            }

            Text("Do not expose Oracle ports publicly.")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(mutedText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.leading, dynamicTypeSize.isAccessibilitySize ? 0 : 50)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(panelSurface)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Privacy")
        .accessibilityValue("This app works only through Tailscale or a private network. Do not expose Oracle ports publicly.")
    }

    private var privacyPrimaryText: some View {
        Text("This app works only through Tailscale / private network.")
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color.white.opacity(0.94))
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Tailscale panel — helper note + the action row.

    private var tailscalePanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Open Tailscale and confirm the VPN is connected before using the app.")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(mutedText)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 2)

            Button {
                if let url = URL(string: "tailscale://") {
                    openURL(url)
                }
            } label: {
                Group {
                    if dynamicTypeSize.isAccessibilitySize {
                        VStack(alignment: .leading, spacing: 12) {
                            HStack {
                                tailscaleIcon
                                Spacer(minLength: 8)
                                tailscaleArrow
                            }
                            tailscaleActionText
                        }
                    } else {
                        HStack(spacing: 13) {
                            tailscaleIcon
                            tailscaleActionText
                            Spacer(minLength: 8)
                            tailscaleArrow
                        }
                    }
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
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Open Tailscale")
            .accessibilityValue("Private connection and VPN route")
            .accessibilityHint("Opens the Tailscale app")
            .accessibilityAddTraits(.isButton)
        }
    }

    private var tailscaleIcon: some View {
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
    }

    private var tailscaleActionText: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Open Tailscale")
                .font(.headline.weight(.bold))
                .fontDesign(.rounded)
                .foregroundStyle(Color.white)
                .lineLimit(2)

            Text("Private connection / VPN route")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(mutedText)
                .lineLimit(3)
        }
        .fixedSize(horizontal: false, vertical: true)
        .layoutPriority(1)
    }

    private var tailscaleArrow: some View {
        Image(systemName: "arrow.up.right")
            .font(.system(size: 14, weight: .bold))
            .foregroundStyle(premiumBlue)
            .frame(width: 34, height: 34)
            .background(premiumBlue.opacity(0.12), in: Circle())
            .accessibilityHidden(true)
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
