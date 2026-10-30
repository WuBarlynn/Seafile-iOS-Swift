import SwiftUI
import UIKit

struct DirentRow: View {
    let dirent: Dirent
    let repo: Repository
    @Environment(Session.self) private var session
    @State private var thumbnail: UIImage?

    private var kind: FileKind { FileKind.of(name: dirent.name, isDirectory: dirent.isDirectory) }

    var body: some View {
        HStack(spacing: 12) {
            thumbnailView
            VStack(alignment: .leading, spacing: 3) {
                Text(dirent.name)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                HStack(spacing: 5) {
                    if dirent.isDirectory {
                        Text("Folder")
                    } else {
                        Text(DisplayFormat.fileSize(dirent.size))
                        if dirent.modified != nil {
                            Text("·")
                            Text(DisplayFormat.relative(dirent.modified))
                        }
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 4)
            if dirent.isDirectory {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .task(id: dirent.path) {
            await loadThumbnail()
        }
    }

    @ViewBuilder
    private var thumbnailView: some View {
        if let thumbnail, !dirent.isDirectory {
            Image(uiImage: thumbnail)
                .resizable()
                .scaledToFill()
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        } else {
            FileIconTile(kind: kind, size: 44)
        }
    }

    private func loadThumbnail() async {
        guard !repo.encrypted,
              !dirent.isDirectory,
              kind == .image,
              dirent.thumbnailPath?.isEmpty == false else { return }
        thumbnail = await session.thumbnails.image(repoID: repo.id, path: dirent.path)
    }
}

struct DirentGridCell: View {
    let dirent: Dirent
    let repo: Repository
    @Environment(Session.self) private var session
    @State private var thumbnail: UIImage?

    private var kind: FileKind { FileKind.of(name: dirent.name, isDirectory: dirent.isDirectory) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Color.primary.opacity(0.05))
                if let thumbnail, !dirent.isDirectory {
                    Image(uiImage: thumbnail)
                        .resizable()
                        .scaledToFill()
                } else {
                    FileIconTile(kind: kind, size: 54)
                }
            }
            .frame(height: 104)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))

            Text(dirent.name)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(dirent.isDirectory ? "Folder" : DisplayFormat.fileSize(dirent.size))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(10)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
        .contentShape(Rectangle())
        .task(id: dirent.path) {
            await loadThumbnail()
        }
    }

    private func loadThumbnail() async {
        guard !repo.encrypted,
              !dirent.isDirectory,
              kind == .image,
              dirent.thumbnailPath?.isEmpty == false else { return }
        thumbnail = await session.thumbnails.image(repoID: repo.id, path: dirent.path)
    }
}
