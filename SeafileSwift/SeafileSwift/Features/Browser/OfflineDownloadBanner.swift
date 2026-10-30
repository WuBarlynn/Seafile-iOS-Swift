import SwiftUI

struct OfflineDownloadBanner: View {
    @Environment(Session.self) private var session

    var body: some View {
        if session.offlineDownloads.isDownloading {
            HStack(spacing: 12) {
                ProgressView()
                    .controlSize(.small)
                    .tint(.seafileOrange)

                VStack(alignment: .leading, spacing: 2) {
                    Text(session.offlineDownloads.title)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Text(progressText)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                Button {
                    session.offlineDownloads.cancel()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 28, height: 28)
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Cancel offline download")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .glassEffect(.regular, in: .capsule)
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(Color.white.opacity(0.16), lineWidth: 0.6)
                    .blendMode(.plusLighter)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 8)
        }
    }

    private var progressText: String {
        let download = session.offlineDownloads
        guard download.totalFiles > 0 else {
            return String(localized: "Preparing…")
        }
        let base = String(format: String(localized: "%lld of %lld files"),
                          download.completedFiles,
                          download.totalFiles)
        guard let currentName = download.currentName, !currentName.isEmpty else {
            return base
        }
        return "\(base) · \(currentName)"
    }
}
