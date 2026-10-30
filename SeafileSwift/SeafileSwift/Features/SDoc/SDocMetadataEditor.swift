import SwiftUI

@MainActor
@Observable
final class SDocMetadataEditorModel {
    let repoID: String
    let api: APIClient
    let snapshot: SDocProfileSnapshot
    var values: [String: SDocMetadataValue]
    var isSaving = false

    private let initialValues: [String: SDocMetadataValue]

    init(repoID: String, api: APIClient, snapshot: SDocProfileSnapshot) {
        self.repoID = repoID
        self.api = api
        self.snapshot = snapshot
        let initial = Dictionary(uniqueKeysWithValues: snapshot.fields.map { ($0.key, $0.initialValue) })
        self.initialValues = initial
        self.values = initial
    }

    var hasChanges: Bool { values != initialValues }

    func save() async throws {
        var data: [String: Any] = [:]
        var tagIDs: [String]?

        for field in snapshot.fields {
            let newValue = values[field.key] ?? field.initialValue
            guard newValue != field.initialValue else { continue }
            switch newValue {
            case .text(let value):
                data[field.name] = value
            case .number(let value):
                let normalized = value.replacingOccurrences(of: ",", with: ".")
                data[field.name] = NSNumber(value: Double(normalized) ?? 0)
            case .date(let date):
                if let date, let format = field.dateFormat {
                    data[field.name] = dateString(date, format: format)
                } else {
                    data[field.name] = ""
                }
            case .single(let value):
                data[field.name] = value ?? ""
            case .multiple(let value):
                data[field.name] = value
            case .bool(let value):
                data[field.name] = value
            case .rate(let value):
                data[field.name] = NSNumber(value: value)
            case .collaborators(let value):
                data[field.name] = value
            case .tags(let value):
                tagIDs = value
            }
        }

        if !data.isEmpty {
            try await api.updateMetadataRecord(repoID: repoID,
                                               recordID: snapshot.recordID,
                                               data: data)
        }
        if let tagIDs {
            try await api.updateFileTags(repoID: repoID,
                                         recordID: snapshot.recordID,
                                         tagIDs: tagIDs)
        }
    }

    private func dateString(_ date: Date, format: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        let lower = format.lowercased()
        formatter.dateFormat = (lower.contains("h:mm") || lower.contains("hh:mm"))
            ? "yyyy-MM-dd HH:mm"
            : "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

struct SDocMetadataEditorView: View {
    let repoID: String
    let api: APIClient
    let onSaved: () async -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var model: SDocMetadataEditorModel
    @State private var toast: String?

    init(repoID: String,
         api: APIClient,
         snapshot: SDocProfileSnapshot,
         onSaved: @escaping () async -> Void) {
        self.repoID = repoID
        self.api = api
        self.onSaved = onSaved
        _model = State(initialValue: SDocMetadataEditorModel(repoID: repoID, api: api, snapshot: snapshot))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(model.snapshot.fields) { field in
                        fieldView(field)
                    }
                } header: {
                    Text("Properties")
                }
            }
            .navigationTitle("Edit Properties")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .disabled(model.isSaving)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if model.isSaving {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Button("Save") { save() }
                            .fontWeight(.semibold)
                            .disabled(!model.hasChanges)
                    }
                }
            }
            .interactiveDismissDisabled(model.isSaving)
            .seafileToast($toast)
        }
    }

    @ViewBuilder
    private func fieldView(_ field: SDocMetadataField) -> some View {
        switch field.type {
        case "text", "url", "email", "duration":
            LabeledContent {
                TextField("", text: textBinding(field))
                    .multilineTextAlignment(.trailing)
                    .autocorrectionDisabled(field.type == "email" || field.type == "url")
                    .textInputAutocapitalization(field.type == "email" || field.type == "url" ? .never : .sentences)
            } label: {
                Text(LocalizedStringKey(field.title))
            }

        case "long_text":
            VStack(alignment: .leading, spacing: 6) {
                Text(LocalizedStringKey(field.title))
                TextField("", text: textBinding(field), axis: .vertical)
                    .lineLimit(2...5)
            }
            .padding(.vertical, 2)

        case "number":
            LabeledContent {
                TextField("", text: numberBinding(field))
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
            } label: {
                Text(LocalizedStringKey(field.title))
            }

        case "date":
            dateRow(field)

        case "checkbox":
            Toggle(isOn: boolBinding(field)) {
                Text(LocalizedStringKey(field.title))
            }
            .tint(.seafileOrange)

        case "rate":
            rateRow(field)

        case "single_select":
            Picker(selection: singleBinding(field)) {
                Text("None").tag("")
                ForEach(field.options) { option in
                    Text(option.name).tag(option.name)
                }
            } label: {
                Text(LocalizedStringKey(field.title))
            }
            .pickerStyle(.menu)
            .tint(.seafileOrange)

        case "multiple_select":
            NavigationLink {
                SDocOptionSelectionView(title: field.title,
                                        options: field.options,
                                        selection: multipleBinding(field))
            } label: {
                LabeledContent {
                    Text(multipleSummary(field))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } label: {
                    Text(LocalizedStringKey(field.title))
                }
            }

        case "collaborator":
            NavigationLink {
                SDocCollaboratorSelectionView(title: field.title,
                                             users: model.snapshot.relatedUsers,
                                             selection: collaboratorBinding(field))
            } label: {
                LabeledContent {
                    Text(collaboratorSummary(field))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } label: {
                    Text(LocalizedStringKey(field.title))
                }
            }

        case "link":
            if field.key == "_tags" {
                NavigationLink {
                    SDocTagSelectionView(title: field.title,
                                         tags: model.snapshot.tags,
                                         selection: tagsBinding(field))
                } label: {
                    LabeledContent {
                        Text(tagSummary(field))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } label: {
                        Text(LocalizedStringKey(field.title))
                    }
                }
            }

        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private func dateRow(_ field: SDocMetadataField) -> some View {
        let components: DatePickerComponents = hasTime(field.dateFormat) ? [.date, .hourAndMinute] : [.date]
        if case .date(let date) = model.values[field.key] ?? field.initialValue {
            if let date {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(LocalizedStringKey(field.title))
                        Spacer()
                        Button("Clear") {
                            model.values[field.key] = .date(nil)
                        }
                        .font(.footnote)
                    }
                    DatePicker("", selection: dateBinding(field, fallback: date),
                               displayedComponents: components)
                        .labelsHidden()
                }
                .padding(.vertical, 2)
            } else {
                Button {
                    model.values[field.key] = .date(Date())
                } label: {
                    LabeledContent {
                        Text("Not set")
                            .foregroundStyle(.secondary)
                    } label: {
                        Text(LocalizedStringKey(field.title))
                    }
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func rateRow(_ field: SDocMetadataField) -> some View {
        HStack {
            Text(LocalizedStringKey(field.title))
            Spacer()
            let current: Int = {
                if case .rate(let value) = model.values[field.key] ?? field.initialValue { return value }
                return 0
            }()
            ForEach(1...max(1, field.rateMax), id: \.self) { index in
                Button {
                    model.values[field.key] = .rate(index == current ? 0 : index)
                } label: {
                    Image(systemName: index <= current ? "star.fill" : "star")
                        .foregroundStyle(Color.seafileOrange)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(index)")
            }
        }
    }

    private func hasTime(_ format: String?) -> Bool {
        guard let format = format?.lowercased() else { return false }
        return format.contains("h:mm") || format.contains("hh:mm")
    }

    private func save() {
        guard model.hasChanges, !model.isSaving else { return }
        model.isSaving = true
        Task {
            do {
                try await model.save()
                await onSaved()
                dismiss()
            } catch {
                toast = error.localizedDescription
                model.isSaving = false
            }
        }
    }

    private func textBinding(_ field: SDocMetadataField) -> Binding<String> {
        Binding(get: {
            if case .text(let value) = model.values[field.key] ?? field.initialValue { return value }
            return ""
        }, set: {
            model.values[field.key] = .text($0)
        })
    }

    private func numberBinding(_ field: SDocMetadataField) -> Binding<String> {
        Binding(get: {
            if case .number(let value) = model.values[field.key] ?? field.initialValue { return value }
            return ""
        }, set: {
            model.values[field.key] = .number($0)
        })
    }

    private func boolBinding(_ field: SDocMetadataField) -> Binding<Bool> {
        Binding(get: {
            if case .bool(let value) = model.values[field.key] ?? field.initialValue { return value }
            return false
        }, set: {
            model.values[field.key] = .bool($0)
        })
    }

    private func singleBinding(_ field: SDocMetadataField) -> Binding<String> {
        Binding(get: {
            if case .single(let value) = model.values[field.key] ?? field.initialValue { return value ?? "" }
            return ""
        }, set: {
            model.values[field.key] = .single($0.isEmpty ? nil : $0)
        })
    }

    private func multipleBinding(_ field: SDocMetadataField) -> Binding<Set<String>> {
        Binding(get: {
            if case .multiple(let value) = model.values[field.key] ?? field.initialValue { return Set(value) }
            return []
        }, set: {
            model.values[field.key] = .multiple(Array($0).sorted())
        })
    }

    private func collaboratorBinding(_ field: SDocMetadataField) -> Binding<Set<String>> {
        Binding(get: {
            if case .collaborators(let value) = model.values[field.key] ?? field.initialValue { return Set(value) }
            return []
        }, set: {
            model.values[field.key] = .collaborators(Array($0).sorted())
        })
    }

    private func tagsBinding(_ field: SDocMetadataField) -> Binding<Set<String>> {
        Binding(get: {
            if case .tags(let value) = model.values[field.key] ?? field.initialValue { return Set(value) }
            return []
        }, set: {
            model.values[field.key] = .tags(Array($0).sorted())
        })
    }

    private func dateBinding(_ field: SDocMetadataField, fallback: Date) -> Binding<Date> {
        Binding(get: {
            if case .date(let value) = model.values[field.key] ?? field.initialValue, let value { return value }
            return fallback
        }, set: {
            model.values[field.key] = .date($0)
        })
    }

    private func multipleSummary(_ field: SDocMetadataField) -> String {
        guard case .multiple(let value) = model.values[field.key] ?? field.initialValue, !value.isEmpty else {
            return String(localized: "None")
        }
        return value.joined(separator: ", ")
    }

    private func collaboratorSummary(_ field: SDocMetadataField) -> String {
        guard case .collaborators(let emails) = model.values[field.key] ?? field.initialValue,
              !emails.isEmpty else {
            return String(localized: "None")
        }
        let names = emails.compactMap { email in
            model.snapshot.relatedUsers.first { $0.email.caseInsensitiveCompare(email) == .orderedSame }?.displayName
        }
        return names.isEmpty ? emails.joined(separator: ", ") : names.joined(separator: ", ")
    }

    private func tagSummary(_ field: SDocMetadataField) -> String {
        guard case .tags(let ids) = model.values[field.key] ?? field.initialValue, !ids.isEmpty else {
            return String(localized: "None")
        }
        let names = model.snapshot.tags.filter { ids.contains($0.id) }.map(\.name)
        return names.isEmpty ? String(localized: "None") : names.joined(separator: ", ")
    }
}

private struct SDocOptionSelectionView: View {
    let title: String
    let options: [SDocFieldOption]
    @Binding var selection: Set<String>

    var body: some View {
        List {
            if options.isEmpty {
                Text("No options")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(options) { option in
                    chooseRow(id: option.name, name: option.name, color: option.color)
                }
            }
        }
        .navigationTitle(Text(LocalizedStringKey(title)))
        .navigationBarTitleDisplayMode(.inline)
    }

    private func chooseRow(id: String, name: String, color: String?) -> some View {
        Button {
            if selection.contains(id) { selection.remove(id) } else { selection.insert(id) }
        } label: {
            HStack(spacing: 10) {
                if let color, !color.isEmpty {
                    Circle().fill(Color(hex: color)).frame(width: 10, height: 10)
                }
                Text(name)
                    .foregroundStyle(.primary)
                Spacer()
                if selection.contains(id) {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.seafileOrange)
                        .fontWeight(.semibold)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct SDocCollaboratorSelectionView: View {
    let title: String
    let users: [SDocUser]
    @Binding var selection: Set<String>

    var body: some View {
        List {
            if users.isEmpty {
                Text("No collaborators")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(users.filter { !$0.email.isEmpty }, id: \.email) { user in
                    Button {
                        let email = user.email
                        if selection.contains(email) { selection.remove(email) } else { selection.insert(email) }
                    } label: {
                        HStack(spacing: 10) {
                            ZStack {
                                Circle().fill(Color(.tertiarySystemFill))
                                Text(String(user.displayName.prefix(1)).uppercased())
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            .frame(width: 28, height: 28)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(user.displayName)
                                    .foregroundStyle(.primary)
                                if !user.email.isEmpty {
                                    Text(user.email)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            if selection.contains(user.email) {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color.seafileOrange)
                                    .fontWeight(.semibold)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .navigationTitle(Text(LocalizedStringKey(title)))
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct SDocTagSelectionView: View {
    let title: String
    let tags: [SDocTagOption]
    @Binding var selection: Set<String>

    var body: some View {
        List {
            if tags.isEmpty {
                Text("No tags")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(tags) { tag in
                    Button {
                        if selection.contains(tag.id) { selection.remove(tag.id) } else { selection.insert(tag.id) }
                    } label: {
                        HStack(spacing: 10) {
                            Circle()
                                .fill(tag.color.flatMap { Color(hex: $0) } ?? Color.seafileOrange)
                                .frame(width: 10, height: 10)
                            Text(tag.name)
                                .foregroundStyle(.primary)
                            Spacer()
                            if selection.contains(tag.id) {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(Color.seafileOrange)
                                    .fontWeight(.semibold)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .navigationTitle(Text(LocalizedStringKey(title)))
        .navigationBarTitleDisplayMode(.inline)
    }
}
