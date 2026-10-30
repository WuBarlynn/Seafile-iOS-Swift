import SwiftUI

struct TransferCenterView: View {
    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss

    private var transfers: TransferCenter {
        session.transfers
    }

    var body: some View {
        NavigationStack {
            ZStack {
                SeafileBackground()
                ScrollView {
                    LazyVStack(spacing: 16) {
                        if transfers.activeTransfers.isEmpty && transfers.completedTransfers.isEmpty {
                            EmptyStateCard(icon: "arrow.up.arrow.down",
                                           title: "No transfers",
                                           message: "Uploads and downloads will appear here.")
                                .padding(.top, 20)
                        } else {
                            if !transfers.activeTransfers.isEmpty {
                                section(title: "Active",
                                        subtitle: "\(transfers.activeTransfers.count)",
                                        records: transfers.activeTransfers)
                            }
                            if !transfers.completedTransfers.isEmpty {
                                section(title: "Recent",
                                        subtitle: "\(transfers.completedTransfers.count)",
                                        records: transfers.completedTransfers)
                            }
                        }
                    }
                    .padding(16)
                }
            }
            .navigationTitle("Transfers")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button {
                            transfers.cancelAllActiveTransfers()
                        } label: {
                            Label("Cancel All", systemImage: "xmark.circle")
                        }
                        .disabled(transfers.activeTransfers.isEmpty)

                        Button(role: .destructive) {
                            transfers.clearCompletedTransfers()
                        } label: {
                            Label("Clear History", systemImage: "trash")
                        }
                        .disabled(transfers.completedTransfers.isEmpty)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
    }

    private func section(title: String,
                         subtitle: String,
                         records: [TransferCenter.TransferRecord]) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: title, subtitle: subtitle)
            VStack(spacing: 10) {
                ForEach(records) { record in
                    TransferRecordCard(record: record) {
                        transfers.cancelTransfer(id: record.id)
                    }
                }
            }
        }
    }
}

private struct TransferRecordCard: View {
    let record: TransferCenter.TransferRecord
    let onCancel: () -> Void

    @Environment(Session.self) private var session

    private var icon: String {
        record.kind == .upload ? "arrow.up.circle.fill" : "arrow.down.circle.fill"
    }

    private var repoName: String {
        session.repoName(for: record.repoID) ?? record.repoID
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(record.isActive ? Color.seafileOrange : statusColor)

                VStack(alignment: .leading, spacing: 3) {
                    Text(record.name)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text("\(repoName) · \(record.path)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                if record.isActive {
                    Button {
                        onCancel()
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 11, weight: .bold))
                            .frame(width: 26, height: 26)
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .glassEffect(.regular.interactive(), in: .circle)
                    .accessibilityLabel("Cancel")
                } else {
                    Image(systemName: statusIcon)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(statusColor)
                }
            }

            if record.isActive {
                ProgressView(value: max(0, min(1, record.progress.fraction)))
                    .tint(.seafileOrange)
                HStack {
                    Text(progressText)
                    Spacer()
                    Text(statusText)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            } else {
                HStack {
                    Text(progressText)
                    Spacer()
                    Text(statusText)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .glassCard(cornerRadius: 20, padding: 14)
    }

    private var progressText: String {
        if record.progress.totalBytes > 0 {
            return "\(DisplayFormat.fileSize(record.progress.completedBytes)) / \(DisplayFormat.fileSize(record.progress.totalBytes))"
        }
        if record.progress.completedBytes > 0 {
            return DisplayFormat.fileSize(record.progress.completedBytes)
        }
        return record.kind == .upload
            ? String(localized: "Upload")
            : String(localized: "Download")
    }

    private var statusText: String {
        if record.isCancelled { return String(localized: "Cancelled") }
        switch record.progress.state {
        case .queued:
            return String(localized: "Queued")
        case .running:
            return "\(Int(record.progress.fraction * 100))%"
        case .finished:
            return String(localized: "Completed")
        case .failed(let message):
            return message
        }
    }

    private var statusIcon: String {
        if record.isCancelled { return "xmark.circle.fill" }
        switch record.progress.state {
        case .finished: return "checkmark.circle.fill"
        case .failed: return "exclamationmark.circle.fill"
        default: return "clock"
        }
    }

    private var statusColor: Color {
        if record.isCancelled { return .secondary }
        switch record.progress.state {
        case .finished: return .green
        case .failed: return .red
        default: return .secondary
        }
    }
}
