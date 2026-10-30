import SwiftUI

enum SDocMetadataValue: Equatable {
    case text(String)
    case number(String)
    case date(Date?)
    case single(String?)
    case multiple([String])
    case bool(Bool)
    case rate(Int)
    case collaborators([String])
    case tags([String])
}

struct SDocFieldOption: Identifiable {
    let id: String
    let name: String
    let color: String?
    let textColor: String?
}

struct SDocTagOption: Identifiable {
    let id: String
    let name: String
    let color: String?
}

struct SDocMetadataField: Identifiable {
    let id: String
    let key: String
    let name: String
    let title: String
    let type: String
    let options: [SDocFieldOption]
    let rateMax: Int
    let dateFormat: String?
    let initialValue: SDocMetadataValue
}

struct SDocProfileSnapshot {
    let recordID: String
    let fields: [SDocMetadataField]
    let tags: [SDocTagOption]
    let relatedUsers: [SDocUser]
}

struct SDocPropertyRow: Identifiable {
    let id: String
    let title: String
    let icon: String
    let values: [SDocPropertyValue]
}

enum SDocPropertyValue {
    case text(String)
    case chip(text: String, background: String?, foreground: String?)
    case collaborator(name: String, avatar: String?)
}

@MainActor
@Observable
final class SDocPropertiesModel {
    let repoID: String
    let path: String
    private let api: APIClient

    var rows: [SDocPropertyRow] = []
    var snapshot: SDocProfileSnapshot?
    var isLoading = true
    var error: String?

    init(repoID: String, path: String, api: APIClient) {
        self.repoID = repoID
        self.path = path
        self.api = api
    }

    func load() async {
        isLoading = true
        error = nil
        snapshot = nil
        defer { isLoading = false }

        do {
            let detail = try await api.fileDetail(repoID: repoID, path: path)
            var config: [String: Any] = [:]
            if let value = try? await api.metadataConfig(repoID: repoID) {
                config = value
            }
            let metadataEnabled = Self.bool(config["enabled"])
            let tagsEnabled = Self.bool(config["tags_enabled"])

            var record: [String: Any]?
            var users: [SDocUser] = []
            var tags: [String: Any]?
            if metadataEnabled || tagsEnabled {
                let parent = (path as NSString).deletingLastPathComponent
                let parentDir = parent.isEmpty ? "/" : parent
                let name = (path as NSString).lastPathComponent
                async let recordResult = try? api.metadataRecord(repoID: repoID, parentDir: parentDir, name: name)
                async let usersResult = try? api.relatedUsers(repoID: repoID)
                record = await recordResult
                users = await usersResult ?? []
                if tagsEnabled {
                    tags = try? await api.repoTags(repoID: repoID)
                }
            }

            let rows = SDocProfileAssembler.buildRows(fileDetail: detail,
                                                      metadataConfig: config,
                                                      record: record,
                                                      relatedUsers: users,
                                                      tags: tags)
            self.rows = rows
            self.snapshot = SDocProfileAssembler.buildSnapshot(metadataConfig: config,
                                                               record: record,
                                                               relatedUsers: users,
                                                               tags: tags)
            if rows.isEmpty {
                error = String(localized: "No file profile data")
            }
        } catch is CancellationError {
            return
        } catch {
            self.error = error.localizedDescription
        }
    }

    private static func bool(_ value: Any?) -> Bool {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        if let value = value as? String { return value == "true" || value == "1" }
        return false
    }
}

enum SDocProfileAssembler {
    private static let fixedKeys: Set<String> = [
        "_size", "_file_modifier", "_file_mtime", "_owner", "_description", "_collaborators",
        "_reviewer", "_status", "_rate", "_tags", "_location", "_expire_time"
    ]

    private static let titles: [String: String] = [
        "_description": "Description",
        "_file_modifier": "Last modifier",
        "_file_mtime": "Last modified",
        "_status": "Status",
        "_collaborators": "Collaborators",
        "_size": "Size",
        "_reviewer": "Reviewer",
        "_in_progress": "In progress",
        "_in_review": "In review",
        "_done": "Done",
        "_outdated": "Outdated",
        "_tags": "Tags",
        "_owner": "Owner",
        "_rate": "Rating",
        "_location": "Location",
        "_expire_time": "Expiration time"
    ]

    static func buildRows(fileDetail: [String: Any],
                          metadataConfig: [String: Any],
                          record: [String: Any]?,
                          relatedUsers: [SDocUser],
                          tags: [String: Any]?) -> [SDocPropertyRow] {
        let metadataEnabled = bool(metadataConfig["enabled"])
        let settings = detailsSettings(metadataConfig, metadataEnabled: metadataEnabled)

        var metadata = record?["metadata"] as? [[String: Any]]
        var result = (record?["results"] as? [[String: Any]])?.first
        var users = relatedUsers

        if !metadataEnabled || metadata == nil || metadata?.isEmpty == true || result == nil {
            let size = (fileDetail["size"] as? NSNumber)?.int64Value ?? 0
            let modifierEmail = fileDetail["last_modifier_email"] as? String
                ?? fileDetail["last_modifier_contact_email"] as? String
                ?? ""
            let modifierName = fileDetail["last_modifier_name"] as? String ?? ""
            let modifierAvatar = fileDetail["last_modifier_avatar"] as? String ?? ""
            let modified = fileDetail["last_modified"] as? String ?? ""
            metadata = [
                ["key": "_size", "name": "_size", "type": "number"],
                ["key": "_file_modifier", "name": "_file_modifier", "type": "text"],
                ["key": "_file_mtime", "name": "_file_mtime", "type": "date"]
            ]
            result = ["_size": size as Any,
                      "_file_modifier": modifierEmail,
                      "_file_mtime": modified]
            if users.isEmpty {
                users = [SDocUser(json: ["name": modifierName,
                                         "email": modifierEmail,
                                         "avatar_url": modifierAvatar])].compactMap { $0 }
            }
        }

        guard var fields = metadata, let values = result else { return [] }

        if let index = fields.firstIndex(where: { ($0["key"] as? String) == "_size" }), index != 0 {
            let size = fields.remove(at: index)
            fields.insert(size, at: 0)
        }

        var rows: [SDocPropertyRow] = []
        for field in fields {
            let key = field["key"] as? String ?? ""
            let name = field["name"] as? String ?? key
            let rawType = field["type"] as? String ?? "text"
            var type = normalizeType(rawType, key: key)

            if let shown = settings[key], !shown { continue }
            if settings[key] == nil { continue }
            if key.hasPrefix("_") && !fixedKeys.contains(key) { continue }

            var rawValue = values[name]
            if key == "_file_modifier" {
                type = "collaborator"
                if let text = rawValue as? String, !text.isEmpty {
                    rawValue = [text]
                } else if rawValue is [Any] {
                    // keep array
                } else if rawValue != nil && !(rawValue is NSNull) {
                    rawValue = []
                }
            }

            let rowTitle = titles[key] ?? name
            let icon = iconForType(type, key: key)

            let displayValues: [SDocPropertyValue]
            if rawValue == nil || rawValue is NSNull {
                displayValues = [.text(String(localized: "Empty"))]
            } else {
                displayValues = renderValues(type: type,
                                             key: key,
                                             value: rawValue!,
                                             field: field,
                                             tags: tags,
                                             users: users,
                                             metadataConfig: metadataConfig)
            }
            rows.append(SDocPropertyRow(id: key.isEmpty ? name : key,
                                        title: rowTitle,
                                        icon: icon,
                                        values: displayValues))
        }
        return rows
    }

    static func buildSnapshot(metadataConfig: [String: Any],
                              record: [String: Any]?,
                              relatedUsers: [SDocUser],
                              tags: [String: Any]?) -> SDocProfileSnapshot? {
        guard bool(metadataConfig["enabled"]),
              let record,
              let metadata = record["metadata"] as? [[String: Any]],
              let result = (record["results"] as? [[String: Any]])?.first else {
            return nil
        }

        let recordID: String
        if let value = result["_id"] as? String, !value.isEmpty {
            recordID = value
        } else if let value = result["_id"] as? NSNumber {
            recordID = value.stringValue
        } else {
            return nil
        }

        let settings = detailsSettings(metadataConfig, metadataEnabled: true)
        let editability: [String: Bool] = [
            "_size": false,
            "_file_modifier": false,
            "_file_mtime": false,
            "_owner": true,
            "_description": true,
            "_collaborators": true,
            "_reviewer": true,
            "_status": true,
            "_location": false,
            "_tags": true,
            "_rate": true,
            "_expire_time": true
        ]

        var fields: [SDocMetadataField] = []
        for field in metadata {
            let key = field["key"] as? String ?? ""
            guard !key.isEmpty, settings[key] == true else { continue }
            if key.hasPrefix("_") && !fixedKeys.contains(key) { continue }

            let name = field["name"] as? String ?? key
            let type = normalizeType(field["type"] as? String ?? "text", key: key)
            var editable = editability[key] ?? true
            let rawValue = result[name]
            let raw: Any? = rawValue is NSNull ? nil : rawValue

            var value: SDocMetadataValue?
            var dateFormat: String?
            switch type {
            case "text", "long_text", "duration", "email", "url":
                value = .text(raw as? String ?? (raw as? NSNumber)?.stringValue ?? "")
            case "number":
                value = .number(numberString(raw))
            case "date":
                if let format = fieldDateFormat(for: field) {
                    dateFormat = format
                    value = .date(raw.flatMap(parseDate))
                } else {
                    editable = false
                }
            case "single_select":
                value = .single(raw as? String)
            case "multiple_select":
                value = .multiple(raw as? [String] ?? [])
            case "checkbox":
                if let number = raw as? NSNumber {
                    value = .bool(number.boolValue)
                } else if let text = raw as? String {
                    value = .bool((text as NSString).boolValue)
                } else {
                    value = .bool(false)
                }
            case "rate":
                value = .rate((raw as? NSNumber)?.intValue ?? 0)
            case "collaborator":
                value = .collaborators(raw as? [String] ?? [])
            case "link":
                if key == "_tags", let links = raw as? [[String: Any]] {
                    let ids = links.compactMap { ($0["row_id"] as? String) ?? ($0["id"] as? String) }
                    value = .tags(Array(Set(ids)).sorted())
                } else {
                    editable = false
                }
            default:
                editable = false
            }

            guard editable, let value else { continue }

            let optionModels = (options(field: field, metadataConfig: metadataConfig) ?? []).compactMap { option -> SDocFieldOption? in
                let name = option["name"] as? String ?? ""
                guard !name.isEmpty else { return nil }
                return SDocFieldOption(id: name,
                                       name: name,
                                       color: (option["color"] as? String) ?? (option["bgColor"] as? String),
                                       textColor: (option["textColor"] as? String) ?? (option["text_color"] as? String))
            }

            fields.append(SDocMetadataField(id: key,
                                            key: key,
                                            name: name,
                                            title: titles[key] ?? name,
                                            type: type,
                                            options: optionModels,
                                            rateMax: rateMax(field) ?? 5,
                                            dateFormat: dateFormat,
                                            initialValue: value))
        }

        let tagResults = tags?["results"] as? [[String: Any]] ?? []
        let tagOptions = tagResults.compactMap { tag -> SDocTagOption? in
            let id = (tag["_id"] as? String) ?? (tag["id"] as? String) ?? ""
            let name = (tag["_tag_name"] as? String) ?? (tag["name"] as? String) ?? ""
            guard !id.isEmpty, !name.isEmpty else { return nil }
            return SDocTagOption(id: id, name: name,
                                 color: (tag["_tag_color"] as? String) ?? (tag["color"] as? String))
        }

        return SDocProfileSnapshot(recordID: recordID,
                                   fields: fields,
                                   tags: tagOptions,
                                   relatedUsers: relatedUsers)
    }

    private static func numberString(_ value: Any?) -> String {
        if let number = value as? NSNumber {
            let double = number.doubleValue
            if double.rounded() == double, abs(double) < Double(Int64.max) {
                return String(number.int64Value)
            }
            return String(double)
        }
        if let text = value as? String { return text }
        return ""
    }

    private static func fieldDateFormat(for field: [String: Any]) -> String? {
        if let data = field["data"] as? [String: Any],
           let format = data["format"] as? String, !format.isEmpty {
            return format
        }
        if let data = field["data"] as? [[String: Any]],
           let format = data.first?["format"] as? String, !format.isEmpty {
            return format
        }
        if let data = field["configData"] as? [String: Any],
           let format = data["format"] as? String, !format.isEmpty {
            return format
        }
        return nil
    }

    private static func detailsSettings(_ config: [String: Any], metadataEnabled: Bool) -> [String: Bool] {
        var map: [String: Bool] = ["_size": true, "_file_modifier": true, "_file_mtime": true]
        if metadataEnabled {
            map["_location"] = true
            map["_description"] = true
            map["_tags"] = true
        }

        var parsed: [String: Any]?
        if let dict = config["details_settings"] as? [String: Any] {
            parsed = dict
        } else if let text = config["details_settings"] as? String,
                  let data = text.data(using: .utf8),
                  let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            parsed = dict
        }
        if let columns = parsed?["columns"] as? [[String: Any]] {
            for column in columns {
                guard let key = column["key"] as? String, !key.isEmpty else { continue }
                map[key] = bool(column["shown"])
            }
        }
        return map
    }

    private static func renderValues(type: String,
                                     key: String,
                                     value: Any,
                                     field: [String: Any],
                                     tags: [String: Any]?,
                                     users: [SDocUser],
                                     metadataConfig: [String: Any]) -> [SDocPropertyValue] {
        switch type {
        case "text", "long_text", "duration", "email", "url":
            guard let text = value as? String, !text.isEmpty else { return [] }
            return [.text(text)]

        case "number":
            if key == "_size" {
                let size = (value as? NSNumber)?.int64Value ?? Int64(value as? String ?? "0") ?? 0
                return [.text(DisplayFormat.fileSize(size))]
            }
            if let number = value as? NSNumber {
                let formatter = NumberFormatter()
                formatter.numberStyle = .decimal
                formatter.minimumFractionDigits = 0
                formatter.maximumFractionDigits = 1
                return [.text(formatter.string(from: number) ?? number.stringValue)]
            }
            return []

        case "date":
            guard let text = dateString(value) else { return [] }
            return [.text(text)]

        case "collaborator":
            guard let emails = value as? [Any] else { return [] }
            var result: [SDocPropertyValue] = []
            for email in emails {
                guard let email = email as? String, !email.isEmpty else { continue }
                guard let user = users.first(where: { $0.email.caseInsensitiveCompare(email) == .orderedSame }) else {
                    continue
                }
                result.append(.collaborator(name: user.displayName, avatar: user.avatarURL))
            }
            return result

        case "single_select":
            guard let text = value as? String, !text.isEmpty else { return [] }
            return [chipValue(text: text, key: key, field: field, tags: tags, metadataConfig: metadataConfig)]

        case "multiple_select":
            guard let list = value as? [Any] else { return [] }
            return list.compactMap { item in
                guard let text = item as? String, !text.isEmpty else { return nil }
                return chipValue(text: text, key: key, field: field, tags: tags, metadataConfig: metadataConfig)
            }

        case "link":
            if key == "_tags", let links = value as? [[String: Any]] {
                return links.compactMap { link in
                    let rowID = (link["row_id"] as? String) ?? (link["id"] as? String) ?? ""
                    guard let tag = tagResult(rowID: rowID, tags: tags) else { return nil }
                    let name = (tag["_tag_name"] as? String) ?? (tag["name"] as? String) ?? ""
                    guard !name.isEmpty else { return nil }
                    let color = (tag["_tag_color"] as? String) ?? (tag["color"] as? String)
                    return .chip(text: name, background: color, foreground: nil)
                }
            }
            return []

        case "rate":
            guard let number = value as? NSNumber else { return [] }
            let maxValue = rateMax(field) ?? 5
            let selected = max(0, min(maxValue, number.intValue))
            let stars = String(repeating: "★", count: selected) + String(repeating: "☆", count: maxValue - selected)
            return [.text(stars)]

        case "checkbox":
            if let number = value as? NSNumber {
                return [.text(number.boolValue ? String(localized: "Yes") : String(localized: "No"))]
            }
            if let text = value as? String {
                let yes = (text as NSString).boolValue
                return [.text(yes ? String(localized: "Yes") : String(localized: "No"))]
            }
            return []

        case "geolocation":
            return geolocationValues(value)

        default:
            if let text = value as? String, !text.isEmpty { return [.text(text)] }
            if let number = value as? NSNumber { return [.text(number.stringValue)] }
            return []
        }
    }

    private static func chipValue(text: String,
                                  key: String,
                                  field: [String: Any],
                                  tags: [String: Any]?,
                                  metadataConfig: [String: Any]) -> SDocPropertyValue {
        if let option = optionValue(text, field: field, metadataConfig: metadataConfig) {
            let name = (option["name"] as? String) ?? text
            return .chip(text: name,
                         background: (option["color"] as? String) ?? (option["bgColor"] as? String),
                         foreground: (option["textColor"] as? String) ?? (option["text_color"] as? String))
        }
        if key == "_status" {
            let fallback = statusFallback(text)
            return .chip(text: fallback.name, background: fallback.color, foreground: fallback.textColor)
        }
        return .chip(text: text, background: nil, foreground: nil)
    }

    private static func optionValue(_ value: String, field: [String: Any], metadataConfig: [String: Any]) -> [String: Any]? {
        guard let options = options(field: field, metadataConfig: metadataConfig) else { return nil }
        return options.first { option in
            let name = (option["name"] as? String) ?? ""
            let key = (option["key"] as? String) ?? (option["id"] as? String) ?? ""
            return name == value || key == value
        }
    }

    private static func options(field: [String: Any], metadataConfig: [String: Any]) -> [[String: Any]]? {
        if let data = field["data"] as? [String: Any], let options = data["options"] as? [[String: Any]] {
            return options
        }
        if let data = field["data"] as? [[String: Any]], let options = data.first?["options"] as? [[String: Any]] {
            return options
        }
        if let data = field["configData"] as? [String: Any], let options = data["options"] as? [[String: Any]] {
            return options
        }
        if let data = field["configData"] as? [[String: Any]], let options = data.first?["options"] as? [[String: Any]] {
            return options
        }
        if let options = field["options"] as? [[String: Any]] {
            return options
        }
        return nil
    }

    private static func tagResult(rowID: String, tags: [String: Any]?) -> [String: Any]? {
        guard !rowID.isEmpty,
              let results = tags?["results"] as? [[String: Any]] else { return nil }
        return results.first {
            let id = ($0["_id"] as? String) ?? ($0["id"] as? String) ?? ""
            return id == rowID
        }
    }

    private static func rateMax(_ field: [String: Any]) -> Int? {
        if let data = field["data"] as? [String: Any] {
            if let value = data["max"] as? NSNumber { return value.intValue }
            if let value = data["rate_max_number"] as? NSNumber { return value.intValue }
        }
        if let data = field["data"] as? [[String: Any]],
           let value = data.first?["max"] as? NSNumber {
            return value.intValue
        }
        return nil
    }

    private static func statusFallback(_ code: String) -> (name: String, color: String, textColor: String) {
        switch code {
        case "_in_progress":
            return (String(localized: "In progress"), "#EED5FF", "#202428")
        case "_in_review":
            return (String(localized: "In review"), "#FFE8CC", "#202428")
        case "_done":
            return (String(localized: "Done"), "#59CB74", "#FFFFFF")
        case "_outdated":
            return (String(localized: "Outdated"), "#C2C2C2", "#FFFFFF")
        default:
            return (code, "#EED5FF", "#202428")
        }
    }

    private static func geolocationValues(_ value: Any) -> [SDocPropertyValue] {
        if let text = value as? String, !text.isEmpty {
            return [.text(text)]
        }
        if let dict = value as? [String: Any] {
            let lat = dict["lat"] ?? dict["latitude"]
            let lng = dict["lng"] ?? dict["longitude"]
            if let lat = lat as? NSNumber, let lng = lng as? NSNumber {
                return [.text("\(lat.doubleValue), \(lng.doubleValue)")]
            }
            if let name = dict["name"] as? String, !name.isEmpty {
                return [.text(name)]
            }
        }
        if let list = value as? [Any], !list.isEmpty {
            return list.compactMap { item in
                if let text = item as? String, !text.isEmpty { return .text(text) }
                return nil
            }
        }
        return []
    }

    private static func dateString(_ value: Any) -> String? {
        if let date = parseDate(value) {
            return date.formatted(date: .numeric, time: .shortened)
        }
        if let text = value as? String, !text.isEmpty {
            return text.replacingOccurrences(of: "T", with: " ")
        }
        return nil
    }

    private static func parseDate(_ value: Any) -> Date? {
        if let text = value as? String, !text.isEmpty {
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = iso.date(from: text) { return date }
            iso.formatOptions = [.withInternetDateTime]
            if let date = iso.date(from: text) { return date }

            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            for format in ["yyyy-MM-dd HH:mm:ss.SSSXXX", "yyyy-MM-dd HH:mm:ssXXX",
                           "yyyy-MM-dd HH:mm:ss.SSS", "yyyy-MM-dd HH:mm:ss",
                           "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
                formatter.dateFormat = format
                if let date = formatter.date(from: text) { return date }
            }
            return nil
        }
        if let number = value as? NSNumber {
            var timestamp = number.doubleValue
            if timestamp > 100_000_000_000 { timestamp /= 1000 }
            return Date(timeIntervalSince1970: timestamp)
        }
        return nil
    }

    private static func normalizeType(_ type: String, key: String) -> String {
        if key == "_size" { return "number" }
        if key == "_file_mtime" { return "date" }
        if key == "_file_modifier" { return "collaborator" }
        if key == "_tags" { return "link" }
        if key == "_status" { return "single_select" }
        return type
    }

    private static func iconForType(_ type: String, key: String) -> String {
        if key == "_tags" { return "tag" }
        switch type {
        case "collaborator": return "person.2"
        case "date": return "calendar"
        case "number": return "number"
        case "email": return "envelope"
        case "url", "link": return "link"
        case "single_select", "multiple_select", "checkbox": return "checkmark.square"
        case "rate": return "star"
        case "geolocation": return "location"
        case "image", "file": return "photo"
        case "duration": return "clock"
        case "long_text": return "text.alignleft"
        default: return "text.alignleft"
        }
    }

    private static func bool(_ value: Any?) -> Bool {
        if let value = value as? Bool { return value }
        if let value = value as? NSNumber { return value.boolValue }
        if let value = value as? String { return value == "true" || value == "1" }
        return false
    }
}

struct SDocPropertiesSheet: View {
    let api: APIClient
    let canEdit: Bool

    @Environment(\.dismiss) private var dismiss
    @State private var model: SDocPropertiesModel
    @State private var showEditor = false

    init(repoID: String, path: String, api: APIClient, canEdit: Bool = false) {
        self.api = api
        self.canEdit = canEdit
        _model = State(initialValue: SDocPropertiesModel(repoID: repoID, path: path, api: api))
    }

    var body: some View {
        NavigationStack {
            Group {
                if model.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = model.error, model.rows.isEmpty {
                    ContentUnavailableView {
                        Label("No file profile data", systemImage: "info.circle")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Try Again") {
                            Task { await model.load() }
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.seafileOrange)
                    }
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            ForEach(Array(model.rows.enumerated()), id: \.offset) { index, row in
                                SDocPropertyRowView(row: row, api: api)
                                if index < model.rows.count - 1 {
                                    Divider().padding(.leading, 44)
                                }
                            }
                        }
                        .padding(16)
                        .background(Color(.secondarySystemGroupedBackground),
                                    in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                        .padding(16)
                    }
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Properties")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Close") { dismiss() }
                }
                if canEdit, let snapshot = model.snapshot, !snapshot.fields.isEmpty {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Edit") { showEditor = true }
                            .fontWeight(.semibold)
                    }
                }
            }
            .task { await model.load() }
            .fullScreenCover(isPresented: $showEditor) {
                if let snapshot = model.snapshot {
                    SDocMetadataEditorView(repoID: model.repoID,
                                           api: api,
                                           snapshot: snapshot) {
                        await model.load()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

private struct SDocPropertyRowView: View {
    let row: SDocPropertyRow
    let api: APIClient

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: row.icon)
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 20, height: 22)
            Text(LocalizedStringKey(row.title))
                .font(.subheadline)
                .foregroundStyle(.primary)
            Spacer(minLength: 12)
            values
                .frame(maxWidth: 220, alignment: .trailing)
        }
        .padding(.vertical, 10)
    }

    @ViewBuilder
    private var values: some View {
        let chips = row.values.contains { if case .chip = $0 { return true }; if case .collaborator = $0 { return true }; return false }
        if chips {
            FlowLayout(spacing: 6) {
                ForEach(Array(row.values.enumerated()), id: \.offset) { _, value in
                    chipView(value)
                }
            }
        } else {
            VStack(alignment: .trailing, spacing: 4) {
                ForEach(Array(row.values.enumerated()), id: \.offset) { _, value in
                    if case .text(let text) = value {
                        Text(verbatim: text)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.trailing)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func chipView(_ value: SDocPropertyValue) -> some View {
        switch value {
        case .text(let text):
            Text(verbatim: text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        case .chip(let text, let background, let foreground):
            Text(text)
                .font(.footnote.weight(.medium))
                .foregroundStyle(foreground.flatMap { Color(hex: $0) } ?? .primary)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(chipBackground(background), in: Capsule())
        case .collaborator(let name, let avatar):
            HStack(spacing: 4) {
                if let raw = avatar, let url = resolveURL(raw) {
                    RemoteImage(url: url, token: api.token, allowUntrusted: api.allowUntrusted)
                        .frame(width: 16, height: 16)
                        .clipShape(Circle())
                }
                Text(name)
                    .font(.footnote.weight(.medium))
                    .lineLimit(1)
            }
            .padding(.leading, avatar == nil ? 8 : 3)
            .padding(.trailing, 8)
            .padding(.vertical, 3)
            .background(Color(.tertiarySystemFill), in: Capsule())
        }
    }

    private func chipBackground(_ hex: String?) -> Color {
        guard let hex, !hex.isEmpty else { return Color(.tertiarySystemFill) }
        return Color(hex: hex).opacity(0.85)
    }

    private func resolveURL(_ raw: String) -> URL? {
        if let url = URL(string: raw), url.scheme != nil { return url }
        return URL(string: raw, relativeTo: api.baseURL)?.absoluteURL
    }
}

private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var totalWidth: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
            totalWidth = max(totalWidth, x - spacing)
        }
        return CGSize(width: proposal.width ?? totalWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
