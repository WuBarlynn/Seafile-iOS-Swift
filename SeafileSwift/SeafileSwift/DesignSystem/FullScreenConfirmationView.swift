import SwiftUI

struct FullScreenConfirmationView: View {
    let icon: String
    let title: String
    let message: String
    let confirmTitle: String
    var isDestructive: Bool = true
    let onConfirm: () -> Void

    @Environment(\.dismiss) private var dismiss

    private var accent: Color {
        isDestructive ? .red : .seafileOrange
    }

    var body: some View {
        ZStack {
            SeafileBackground()
            VStack(spacing: 18) {
                Image(systemName: icon)
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(width: 68, height: 68)
                    .glassEffect(.regular.tint(accent.opacity(0.12)), in: .circle)

                Text(LocalizedStringKey(title))
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)

                Text(LocalizedStringKey(message))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                VStack(spacing: 12) {
                    Button {
                        onConfirm()
                        dismiss()
                    } label: {
                        Text(LocalizedStringKey(confirmTitle))
                    }
                    .buttonStyle(GlassProminentButtonStyle(tint: accent))

                    Button("Cancel") {
                        dismiss()
                    }
                    .buttonStyle(.plain)
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .glassEffect(.regular.interactive(), in: .capsule)
                }
                .padding(.top, 6)
            }
            .frame(maxWidth: 520)
            .glassCard(cornerRadius: 30, padding: 24)
            .padding(24)
        }
    }
}
