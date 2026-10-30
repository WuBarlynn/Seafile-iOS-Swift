import ImageIO
import SwiftUI

struct FileInfoSheet: View {
    private struct ExifRow: Identifiable {
        let id = UUID()
        let title: String
        let value: String
    }

    let target: PreviewTarget

    @Environment(Session.self) private var session
    @Environment(\.dismiss) private var dismiss

    @State private var exifRows: [ExifRow] = []
    @State private var isLoadingExif = false

    private var kind: FileKind { FileKind.of(name: target.name) }

    private var isAvailableOffline: Bool {
        session.offlineFiles.existingURL(repoID: target.repo.id,
                                         path: target.path,
                                         name: target.name,
                                         version: target.version) != nil
    }

    var body: some View {
        NavigationStack {
            ZStack {
                SeafileBackground()
                ScrollView {
                    VStack(spacing: 16) {
                        header
                        details
                        if isLoadingExif {
                            ProgressView()
                                .controlSize(.small)
                                .tint(.seafileOrange)
                                .padding(.vertical, 12)
                        } else if !exifRows.isEmpty {
                            exifDetails
                        }
                    }
                    .padding(16)
                }
            }
            .navigationTitle("File Info")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .task {
            await loadExifIfNeeded()
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            FileIconTile(kind: kind, size: 64)
            Text(target.name)
                .font(.headline)
                .multilineTextAlignment(.center)
                .lineLimit(2)
            Text(kindTitle)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .glassCard(cornerRadius: 24, padding: 20)
    }

    private var details: some View {
        VStack(spacing: 0) {
            infoRow("Library", target.repo.name)
            divider
            infoRow("Path", target.path)
            divider
            infoRow("Size", target.size > 0 ? DisplayFormat.fileSize(target.size) : String(localized: "Unknown"))
            divider
            infoRow("Modified", target.modified.map { DisplayFormat.date($0) } ?? String(localized: "Unknown"))
            divider
            infoRow("Version", target.version.isEmpty ? String(localized: "Unknown") : target.version)
            divider
            infoRow("Offline", isAvailableOffline
                    ? String(localized: "Available offline")
                    : String(localized: "Not downloaded for offline use"))
            if target.repo.encrypted {
                divider
                infoRow("Encryption", String(localized: "Encrypted library"))
            }
        }
        .glassCard(cornerRadius: 24, padding: 0)
    }

    private var exifDetails: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "EXIF")
            VStack(spacing: 0) {
                ForEach(Array(exifRows.enumerated()), id: \.element.id) { index, row in
                    infoRow(row.title, row.value)
                    if index < exifRows.count - 1 {
                        divider
                    }
                }
            }
            .glassCard(cornerRadius: 24, padding: 0)
        }
    }

    private func loadExifIfNeeded() async {
        guard kind == .image, exifRows.isEmpty else { return }
        isLoadingExif = true
        defer { isLoadingExif = false }
        guard let url = try? await session.transfers.download(repoID: target.repo.id,
                                                              path: target.path,
                                                              name: target.name,
                                                              version: target.version) else {
            return
        }
        exifRows = Self.readExif(url)
    }

    private static func readExif(_ url: URL) -> [ExifRow] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else {
            return []
        }

        var rows: [ExifRow] = []
        func add(_ title: String, _ value: String?) {
            guard let value, !value.isEmpty else { return }
            rows.append(ExifRow(title: title, value: value))
        }

        let tiff = properties[kCGImagePropertyTIFFDictionary as String] as? [String: Any]
        let exif = properties[kCGImagePropertyExifDictionary as String] as? [String: Any]

        if let width = properties[kCGImagePropertyPixelWidth as String] as? NSNumber,
           let height = properties[kCGImagePropertyPixelHeight as String] as? NSNumber {
            add(String(localized: "Dimensions"), "\(width.intValue) × \(height.intValue)")
        }

        let make = tiff?[kCGImagePropertyTIFFMake as String] as? String
        let model = tiff?[kCGImagePropertyTIFFModel as String] as? String
        let camera = [make, model].compactMap { $0 }.joined(separator: " ")
        add(String(localized: "Camera"), camera)

        add(String(localized: "Lens"), exif?[kCGImagePropertyExifLensModel as String] as? String)
        add(String(localized: "Taken"), exif?[kCGImagePropertyExifDateTimeOriginal as String] as? String)

        if let iso = (exif?[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber])?.first {
            add("ISO", "\(iso.intValue)")
        }
        if let aperture = exif?[kCGImagePropertyExifFNumber as String] as? NSNumber {
            add(String(localized: "Aperture"), String(format: "ƒ/%.1f", aperture.doubleValue))
        }
        if let exposure = exif?[kCGImagePropertyExifExposureTime as String] as? NSNumber {
            let seconds = exposure.doubleValue
            if seconds > 0, seconds < 1 {
                add(String(localized: "Shutter"), "1/\(Int(round(1 / seconds))) s")
            } else if seconds > 0 {
                add(String(localized: "Shutter"), String(format: "%.1f s", seconds))
            }
        }
        if let focal = exif?[kCGImagePropertyExifFocalLength as String] as? NSNumber {
            add(String(localized: "Focal Length"), String(format: "%.0f mm", focal.doubleValue))
        }
        return rows
    }

    private var divider: some View {
        Divider().padding(.leading, 14).opacity(0.5)
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(LocalizedStringKey(title))
                .foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .multilineTextAlignment(.trailing)
                .lineLimit(3)
                .textSelection(.enabled)
        }
        .font(.subheadline)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private var kindTitle: String {
        switch kind {
        case .folder: return String(localized: "Folder")
        case .image: return String(localized: "Image")
        case .video: return String(localized: "Video")
        case .audio: return String(localized: "Audio")
        case .pdf: return String(localized: "PDF document")
        case .text: return String(localized: "Text file")
        case .officeDocument: return String(localized: "Office document")
        case .archive: return String(localized: "Archive")
        case .other: return String(localized: "File")
        }
    }
}
