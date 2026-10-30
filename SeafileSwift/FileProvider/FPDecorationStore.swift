import FileProvider
import Foundation

struct FPDecoration: Codable {
    var favoriteRank: UInt64?
    var tagData: Data?
    var lastUsedDate: Date?
}

final class FPDecorationStore {
    static let shared = FPDecorationStore()

    private let defaults = ShareSessionStore.defaults

    private func key(_ identifier: NSFileProviderItemIdentifier) -> String {
        "fp.decoration.\(identifier.rawValue)"
    }

    func decoration(for identifier: NSFileProviderItemIdentifier) -> FPDecoration? {
        guard let data = defaults?.data(forKey: key(identifier)) else { return nil }
        return try? JSONDecoder().decode(FPDecoration.self, from: data)
    }

    func save(_ decoration: FPDecoration, for identifier: NSFileProviderItemIdentifier) {
        guard let data = try? JSONEncoder().encode(decoration) else { return }
        defaults?.set(data, forKey: key(identifier))
    }

    @discardableResult
    func apply(to item: FPItem) -> FPItem {
        guard let decoration = decoration(for: item.itemIdentifier) else { return item }
        item.favoriteRank = decoration.favoriteRank.map { NSNumber(value: $0) }
        item.tagData = decoration.tagData
        item.lastUsedDate = decoration.lastUsedDate
        return item
    }

    func update(from template: NSFileProviderItem,
                fields: NSFileProviderItemFields,
                identifier: NSFileProviderItemIdentifier) {
        var decoration = decoration(for: identifier) ?? FPDecoration()
        if fields.contains(.favoriteRank) {
            let rank = template.favoriteRank ?? nil
            decoration.favoriteRank = rank?.uint64Value
        }
        if fields.contains(.tagData) {
            decoration.tagData = template.tagData ?? nil
        }
        if fields.contains(.lastUsedDate) {
            decoration.lastUsedDate = template.lastUsedDate ?? nil
        }
        save(decoration, for: identifier)
    }
}
