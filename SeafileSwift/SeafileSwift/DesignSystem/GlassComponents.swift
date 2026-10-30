import SwiftUI
import UIKit

extension View {
    func glassCard(cornerRadius: CGFloat = 24, tint: Color? = nil, padding: CGFloat = 16) -> some View {
        self
            .padding(padding)
            .glassEffect(tint.map { Glass.regular.tint($0) } ?? .regular, in: .rect(cornerRadius: cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.18), lineWidth: 0.6)
                    .blendMode(.plusLighter)
            }
    }

    func glassPanel(cornerRadius: CGFloat = 28) -> some View {
        self
            .glassEffect(.regular, in: .rect(cornerRadius: cornerRadius))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.16), lineWidth: 0.6)
                    .blendMode(.plusLighter)
            }
    }
}

struct FileIconTile: View {
    let kind: FileKind
    var size: CGFloat = 44

    var body: some View {
        let colors = kind.tint.map { Color(hex: $0) }
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.28, style: .continuous)
                .fill(LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing))
            Image(systemName: kind.symbol)
                .font(.system(size: size * 0.4, weight: .semibold))
                .foregroundStyle(.white)
                .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
        }
        .frame(width: size, height: size)
    }
}

struct AccountAvatar: View {
    let initials: String
    var size: CGFloat = 46
    var account: Account?
    var token: String?
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                Circle()
                    .fill(LinearGradient(colors: [Color.seafileAmber, Color.seafileOrange],
                                         startPoint: .topLeading,
                                         endPoint: .bottomTrailing))
                Text(initials.isEmpty ? "S" : initials)
                    .font(.system(size: size * 0.36, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay {
            Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.6)
        }
        .task(id: account?.id) {
            image = nil
            guard let account, let token else { return }
            image = await AvatarStore.shared.image(for: account, token: token)
        }
    }
}

struct GlassCircleButton: View {
    let systemImage: String
    var label: String?
    var tint: Color?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .glassEffect((tint.map { Glass.regular.tint($0) } ?? .regular).interactive(), in: .circle)
        .accessibilityLabel(label ?? systemImage)
    }
}

struct GlassProminentButtonStyle: ButtonStyle {
    var tint: Color = .seafileOrange

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .foregroundStyle(.white)
            .background {
                Capsule(style: .continuous)
                    .fill(LinearGradient(colors: [Color.seafileAmber, tint],
                                         startPoint: .topLeading,
                                         endPoint: .bottomTrailing))
                    .opacity(configuration.isPressed ? 0.82 : 1)
            }
            .glassEffect(.regular.tint(tint.opacity(0.18)).interactive(), in: .capsule)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.smooth(duration: 0.18), value: configuration.isPressed)
    }
}

struct QuotaMeter: View {
    let used: Int64?
    let total: Int64?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Storage")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(DisplayFormat.quota(used: used, total: total))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let total, total > 0, let used {
                ProgressView(value: min(1, max(0, Double(used) / Double(total))))
                    .progressViewStyle(.linear)
                    .tint(.seafileOrange)
            } else {
                ProgressView()
                    .progressViewStyle(.linear)
                    .tint(.seafileOrange)
                    .opacity(0.4)
            }
        }
    }
}

struct EmptyStateCard: View {
    let icon: String
    let title: String
    let message: String
    var actionTitle: String?
    var action: (() -> Void)?

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 34, weight: .semibold))
                .foregroundStyle(Color.seafileOrange)
                .frame(width: 68, height: 68)
                .glassEffect(.regular.tint(Color.seafileOrange.opacity(0.12)), in: .circle)
            Text(LocalizedStringKey(title))
                .font(.headline)
            Text(LocalizedStringKey(message))
                .font(.subheadline)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            if let actionTitle, let action {
                Button(LocalizedStringKey(actionTitle), action: action)
                    .buttonStyle(GlassProminentButtonStyle())
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .glassCard(cornerRadius: 28, padding: 24)
    }
}

struct LoadingCard: View {
    var message: String = "Loading…"

    var body: some View {
        HStack(spacing: 12) {
            ProgressView()
            Text(LocalizedStringKey(message))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .glassCard(cornerRadius: 22, padding: 18)
    }
}

struct SectionHeader: View {
    let title: String
    var subtitle: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(LocalizedStringKey(title))
                .font(.footnote.weight(.semibold))
                .textCase(.uppercase)
                .foregroundStyle(.secondary)
                .tracking(0.8)
            Spacer()
            if let subtitle {
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 4)
    }
}

struct UploadProgressCard: View {
    let job: TransferCenter.UploadJob

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.up.circle.fill")
                .font(.title2)
                .foregroundStyle(Color.seafileOrange)
            VStack(alignment: .leading, spacing: 4) {
                Text(job.fileName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                ProgressView(value: job.progress.fraction)
                    .progressViewStyle(.linear)
                    .tint(.seafileOrange)
            }
            Text("\(Int(job.progress.fraction * 100))%")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .glassCard(cornerRadius: 20, padding: 14)
    }
}

struct SeafileToastModifier: ViewModifier {
    @Binding var message: String?

    func body(content: Content) -> some View {
        content.overlay(alignment: .bottom) {
            if let message {
                Text(message)
                    .font(.subheadline.weight(.medium))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 12)
                    .glassEffect(.regular.tint(Color.seafileOrange.opacity(0.16)), in: .capsule)
                    .padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .onAppear {
                        Task { @MainActor in
                            try? await Task.sleep(nanoseconds: 2_800_000_000)
                            withAnimation(.smooth) { self.message = nil }
                        }
                    }
            }
        }
        .animation(.smooth, value: message)
    }
}

extension View {
    func seafileToast(_ message: Binding<String?>) -> some View {
        modifier(SeafileToastModifier(message: message))
    }
}
