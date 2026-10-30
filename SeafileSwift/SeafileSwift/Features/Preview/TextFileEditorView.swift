import SwiftUI
import UIKit

struct TextFileEditorView: View {
    private enum EditorMode: Hashable {
        case edit
        case preview
    }

    let title: String
    let initialText: String
    let onSave: (String) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text: String
    @State private var isSaving = false
    @State private var toast: String?
    @State private var mode: EditorMode = .edit
    @State private var markdownController = MarkdownEditorController()

    init(title: String, initialText: String, onSave: @escaping (String) async throws -> Void) {
        self.title = title
        self.initialText = initialText
        self.onSave = onSave
        _text = State(initialValue: initialText)
    }

    private var isMarkdown: Bool {
        let ext = (title as NSString).pathExtension.lowercased()
        return ["md", "markdown", "mdown", "mkd"].contains(ext)
    }

    private var isPython: Bool {
        ["py", "pyw", "pyi"].contains((title as NSString).pathExtension.lowercased())
    }

    var body: some View {
        NavigationStack {
            Group {
                if isMarkdown && mode == .preview {
                    markdownPreview
                } else if isMarkdown {
                    MarkdownTextView(text: $text, controller: markdownController)
                        .background(Color(.systemBackground))
                } else if isPython {
                    PythonCodeTextView(text: $text)
                        .background(Color(.systemBackground))
                } else {
                    TextEditor(text: $text)
                        .font(.system(.body, design: .monospaced))
                        .scrollContentBackground(.hidden)
                        .background(Color(.systemBackground))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Cancel") { dismiss() }
                        .disabled(isSaving)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    if isSaving {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Button("Save") { save() }
                            .fontWeight(.semibold)
                    }
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                if isMarkdown {
                    Picker("Mode", selection: $mode) {
                        Text("Edit").tag(EditorMode.edit)
                        Text("Preview").tag(EditorMode.preview)
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background(.bar)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if isMarkdown && mode == .edit {
                    markdownToolbar
                }
            }
            .onChange(of: mode) { _, newValue in
                if newValue == .preview {
                    markdownController.resign()
                }
            }
            .interactiveDismissDisabled(isSaving)
            .seafileToast($toast)
        }
    }

    private var markdownPreview: some View {
        ScrollView {
            Group {
                if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("Nothing to preview.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else if let attributed = try? AttributedString(markdown: text) {
                    Text(attributed)
                } else {
                    Text(text)
                        .font(.system(.body, design: .monospaced))
                }
            }
            .textSelection(.enabled)
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 20)
        }
        .background(Color(.systemBackground))
    }

    private var markdownToolbar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 3) {
                Menu {
                    Button("Normal text") { markdownController.removeHeadings() }
                    Button("Heading 1") { markdownController.toggleLinePrefix("# ") }
                    Button("Heading 2") { markdownController.toggleLinePrefix("## ") }
                    Button("Heading 3") { markdownController.toggleLinePrefix("### ") }
                } label: {
                    HStack(spacing: 1) {
                        Image(systemName: "textformat")
                            .font(.system(size: 17, weight: .medium))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 8, weight: .bold))
                    }
                    .foregroundStyle(.primary)
                    .frame(width: 44, height: 34)
                    .contentShape(Rectangle())
                }
                .accessibilityLabel("Heading")

                toolbarDivider

                markdownButton("bold", label: "Bold") {
                    markdownController.toggleWrap("**", "**")
                }
                markdownButton("italic", label: "Italic") {
                    markdownController.toggleWrap("*", "*")
                }
                markdownButton("strikethrough", label: "Strikethrough") {
                    markdownController.toggleWrap("~~", "~~")
                }

                toolbarDivider

                markdownButton("list.bullet", label: "Bulleted list") {
                    markdownController.toggleLinePrefix("- ")
                }
                markdownButton("list.number", label: "Numbered list") {
                    markdownController.toggleLinePrefix("1. ")
                }
                markdownButton("checklist", label: "Checklist") {
                    markdownController.toggleLinePrefix("- [ ] ")
                }
                markdownButton("text.quote", label: "Quote") {
                    markdownController.toggleLinePrefix("> ")
                }

                toolbarDivider

                markdownButton("chevron.left.forwardslash.chevron.right", label: "Code") {
                    markdownController.toggleWrap("`", "`")
                }
                markdownButton("link", label: "Link") {
                    markdownController.insertLink()
                }
            }
            .padding(.horizontal, 10)
        }
        .frame(height: 46)
        .background(.bar)
        .overlay(alignment: .top) {
            Divider()
        }
    }

    private var toolbarDivider: some View {
        Divider()
            .frame(height: 20)
            .padding(.horizontal, 1)
    }

    private func markdownButton(_ systemImage: String,
                                label: String,
                                action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.primary)
                .frame(width: 34, height: 34)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(LocalizedStringKey(label))
    }

    private func save() {
        guard !isSaving else { return }
        isSaving = true
        Task {
            do {
                try await onSave(text)
                dismiss()
            } catch {
                toast = error.localizedDescription
                isSaving = false
            }
        }
    }
}

final class MarkdownEditorController {
    weak var textView: UITextView?

    func focus() {
        textView?.becomeFirstResponder()
    }

    func resign() {
        textView?.resignFirstResponder()
    }

    func toggleWrap(_ prefix: String, _ suffix: String) {
        guard let textView else { return }
        let range = textView.selectedRange
        let ns = textView.text as NSString
        let selected = ns.substring(with: range)
        let prefixLength = (prefix as NSString).length
        let suffixLength = (suffix as NSString).length

        if !selected.isEmpty,
           selected.hasPrefix(prefix),
           selected.hasSuffix(suffix),
           selected.utf16.count >= prefixLength + suffixLength,
           !(prefix == "*" && selected.hasPrefix("**")) {
            let innerRange = NSRange(location: prefixLength,
                                     length: selected.utf16.count - prefixLength - suffixLength)
            let inner = (selected as NSString).substring(with: innerRange)
            replace(range,
                    with: inner,
                    select: NSRange(location: range.location, length: (inner as NSString).length))
        } else {
            let replacement = prefix + selected + suffix
            replace(range,
                    with: replacement,
                    select: NSRange(location: range.location + prefixLength,
                                    length: (selected as NSString).length))
        }
    }

    func toggleLinePrefix(_ prefix: String) {
        guard let textView else { return }
        let ns = textView.text as NSString
        let lineRange = ns.lineRange(for: textView.selectedRange)
        let block = ns.substring(with: lineRange)
        let nonEmpty = block.components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let allHave = !nonEmpty.isEmpty && nonEmpty.allSatisfy { lineHasPrefix($0, prefix: prefix) }

        transformLines(in: lineRange) { line in
            if line.trimmingCharacters(in: .whitespaces).isEmpty { return line }
            let stripped = Self.strippingKnownPrefix(line)
            return allHave ? stripped : prefix + stripped
        }
    }

    func removeHeadings() {
        guard let textView else { return }
        let ns = textView.text as NSString
        let lineRange = ns.lineRange(for: textView.selectedRange)
        let regex = try! NSRegularExpression(pattern: #"^\s*#{1,6}\s+"#)
        transformLines(in: lineRange) { line in
            let length = (line as NSString).length
            return regex.stringByReplacingMatches(in: line,
                                                  range: NSRange(location: 0, length: length),
                                                  withTemplate: "")
        }
    }

    func insertLink() {
        guard let textView else { return }
        let range = textView.selectedRange
        let ns = textView.text as NSString
        let selected = ns.substring(with: range)
        let replacement = selected.isEmpty ? "[text](url)" : "[\(selected)](url)"

        let selection: NSRange
        if selected.isEmpty {
            selection = NSRange(location: range.location + 1, length: 4)
        } else {
            selection = NSRange(location: range.location + 1 + selected.utf16.count + 2,
                                length: 3)
        }
        replace(range, with: replacement, select: selection)
    }

    private func lineHasPrefix(_ line: String, prefix: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if prefix.hasPrefix("#") {
            let level = prefix.filter { $0 == "#" }.count
            let hashes = trimmed.prefix { $0 == "#" }.count
            return hashes == level && trimmed.dropFirst(level).hasPrefix(" ")
        }
        if prefix == "- " {
            return trimmed.hasPrefix("- ") && !trimmed.hasPrefix("- [")
        }
        return trimmed.hasPrefix(prefix)
    }

    private func transformLines(in lineRange: NSRange, transform: (String) -> String) {
        guard let textView else { return }
        let ns = textView.text as NSString
        let block = ns.substring(with: lineRange)
        let endsWithNewline = block.hasSuffix("\n")
        var lines = block.components(separatedBy: "\n")
        if endsWithNewline, lines.last == "" {
            lines.removeLast()
        }
        lines = lines.map(transform)
        var replacement = lines.joined(separator: "\n")
        if endsWithNewline {
            replacement += "\n"
        }
        replace(lineRange,
                with: replacement,
                select: NSRange(location: lineRange.location, length: (replacement as NSString).length))
    }

    private func replace(_ range: NSRange, with text: String, select selection: NSRange? = nil) {
        guard let textView,
              let start = textView.position(from: textView.beginningOfDocument, offset: range.location),
              let end = textView.position(from: start, offset: range.length),
              let textRange = textView.textRange(from: start, to: end) else {
            return
        }
        textView.replace(textRange, withText: text)
        if let selection {
            let length = (textView.text as NSString).length
            let location = min(selection.location, length)
            let safeLength = min(selection.length, max(0, length - location))
            textView.selectedRange = NSRange(location: location, length: safeLength)
        }
        textView.scrollRangeToVisible(textView.selectedRange)
        textView.delegate?.textViewDidChange?(textView)
    }

    private static func strippingKnownPrefix(_ line: String) -> String {
        let regex = try! NSRegularExpression(
            pattern: #"^\s*(?:#{1,6}\s+|[-*+]\s+\[[ xX]\]\s+|[-*+]\s+|\d+\.\s+|>\s+)"#
        )
        let length = (line as NSString).length
        return regex.stringByReplacingMatches(in: line,
                                              range: NSRange(location: 0, length: length),
                                              withTemplate: "")
    }
}

private struct MarkdownTextView: UIViewRepresentable {
    @Binding var text: String
    let controller: MarkdownEditorController

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.font = .monospacedSystemFont(ofSize: 16, weight: .regular)
        textView.backgroundColor = .clear
        textView.textColor = .label
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        textView.alwaysBounceVertical = true
        textView.keyboardDismissMode = .interactive
        textView.autocorrectionType = .no
        textView.autocapitalizationType = .sentences
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.text = text
        controller.textView = textView
        return textView
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        context.coordinator.parent = self
        controller.textView = uiView
        if uiView.text != text {
            uiView.text = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: MarkdownTextView

        init(parent: MarkdownTextView) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
        }
    }
}

private struct PythonCodeTextView: UIViewRepresentable {
    @Binding var text: String

    func makeUIView(context: Context) -> UITextView {
        let textView = UITextView()
        textView.delegate = context.coordinator
        textView.font = .monospacedSystemFont(ofSize: 15, weight: .regular)
        textView.backgroundColor = .systemBackground
        textView.textColor = .label
        textView.textContainerInset = UIEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        textView.alwaysBounceVertical = true
        textView.keyboardDismissMode = .interactive
        textView.autocorrectionType = .no
        textView.autocapitalizationType = .none
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.smartInsertDeleteType = .no
        textView.text = text
        PythonHighlighter.apply(to: textView)
        return textView
    }

    func updateUIView(_ uiView: UITextView, context: Context) {
        context.coordinator.parent = self
        if uiView.text != text {
            uiView.text = text
            PythonHighlighter.apply(to: uiView)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: PythonCodeTextView

        init(parent: PythonCodeTextView) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            guard textView.markedTextRange == nil else { return }
            PythonHighlighter.apply(to: textView)
        }
    }
}
