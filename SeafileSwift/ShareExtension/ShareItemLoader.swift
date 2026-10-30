import Foundation
import UniformTypeIdentifiers

struct SharedItem: Identifiable, Sendable {
    let id = UUID()
    let url: URL
    let name: String
    let size: Int64
}

final class ShareItemLoader {
    private let directory: URL
    private var usedNames: Set<String> = []

    private init(directory: URL) {
        self.directory = directory
    }

    static func load(from context: NSExtensionContext?) async -> [SharedItem] {
        let providers = (context?.inputItems as? [NSExtensionItem] ?? [])
            .flatMap { $0.attachments ?? [] }
        guard !providers.isEmpty else { return [] }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SeafileShare-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let loader = ShareItemLoader(directory: directory)

        var items: [SharedItem] = []
        for (index, provider) in providers.enumerated() {
            if let item = await loader.load(provider, index: index) {
                items.append(item)
            }
        }
        return items
    }

    private func load(_ provider: NSItemProvider, index: Int) async -> SharedItem? {
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
           let url = await loadFileURL(provider) {
            return copy(url: url, suggestedName: provider.suggestedName, fallbackBase: "File-\(index)")
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier),
           let copied = await loadFileRepresentation(provider,
                                                     type: .image,
                                                     fallbackBase: "Photo-\(index)") {
            return copied
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier),
           let copied = await loadFileRepresentation(provider,
                                                     type: .movie,
                                                     fallbackBase: "Video-\(index)") {
            return copied
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.data.identifier),
           let copied = await loadFileRepresentation(provider,
                                                     type: .data,
                                                     fallbackBase: "File-\(index)") {
            return copied
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
           let text = await loadText(provider) {
            return writeText(text, index: index)
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
           let url = await loadURL(provider) {
            return writeText(url.absoluteString, index: index)
        }

        return nil
    }

    // MARK: - Loading

    private func loadFileURL(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                if let url = item as? URL {
                    continuation.resume(returning: url)
                } else if let url = item as? NSURL {
                    continuation.resume(returning: url as URL)
                } else if let data = item as? Data {
                    continuation.resume(returning: URL(dataRepresentation: data, relativeTo: nil))
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private func loadFileRepresentation(_ provider: NSItemProvider,
                                        type: UTType,
                                        fallbackBase: String) async -> SharedItem? {
        await withCheckedContinuation { continuation in
            provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { [weak self] url, _ in
                guard let self, let url else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: self.copy(url: url,
                                                        suggestedName: provider.suggestedName,
                                                        fallbackBase: fallbackBase))
            }
        }
    }

    private func loadText(_ provider: NSItemProvider) async -> String? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, _ in
                if let text = item as? String {
                    continuation.resume(returning: text)
                } else if let data = item as? Data {
                    continuation.resume(returning: String(data: data, encoding: .utf8))
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    private func loadURL(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, _ in
                if let url = item as? URL {
                    continuation.resume(returning: url)
                } else if let url = item as? NSURL {
                    continuation.resume(returning: url as URL)
                } else if let data = item as? Data {
                    continuation.resume(returning: URL(dataRepresentation: data, relativeTo: nil))
                } else {
                    continuation.resume(returning: nil)
                }
            }
        }
    }

    // MARK: - Copying

    private func copy(url: URL, suggestedName: String?, fallbackBase: String) -> SharedItem? {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return nil
        }

        let original = suggestedName?.isEmpty == false ? suggestedName! : url.lastPathComponent
        let name = uniqueName(Self.sanitize(original.isEmpty ? fallbackBase : original),
                              fallbackExtension: url.pathExtension)
        let destination = directory.appendingPathComponent(name)
        do {
            try FileManager.default.copyItem(at: url, to: destination)
        } catch {
            return nil
        }
        return item(at: destination, name: name)
    }

    private func writeText(_ text: String, index: Int) -> SharedItem? {
        let firstLine = text.split(separator: "\n").first.map(String.init) ?? ""
        var base = Self.sanitize(String(firstLine.prefix(40)))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if base.isEmpty { base = "Shared-\(index)" }
        let name = uniqueName("\(base).txt", fallbackExtension: "txt")
        let destination = directory.appendingPathComponent(name)
        do {
            try Data(text.utf8).write(to: destination, options: .atomic)
        } catch {
            return nil
        }
        return item(at: destination, name: name)
    }

    private func item(at url: URL, name: String) -> SharedItem {
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        return SharedItem(url: url, name: name, size: size)
    }

    private func uniqueName(_ name: String, fallbackExtension: String) -> String {
        var base = (name as NSString).deletingPathExtension
        var ext = (name as NSString).pathExtension
        if ext.isEmpty { ext = fallbackExtension }
        if base.isEmpty { base = "Shared" }

        var candidate = ext.isEmpty ? base : "\(base).\(ext)"
        var index = 2
        while usedNames.contains(candidate.lowercased()) {
            candidate = ext.isEmpty ? "\(base)-\(index)" : "\(base)-\(index).\(ext)"
            index += 1
        }
        usedNames.insert(candidate.lowercased())
        return candidate
    }

    private static func sanitize(_ value: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let trimmed = value
            .components(separatedBy: invalid)
            .joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Shared" : trimmed
    }
}
