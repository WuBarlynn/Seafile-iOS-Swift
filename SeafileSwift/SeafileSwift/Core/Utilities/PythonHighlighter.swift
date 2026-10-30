import Foundation
import SwiftUI
import UIKit

enum PythonHighlighter {
    private enum TokenKind {
        case comment
        case string
        case decorator
        case number
        case keyword
        case builtin
    }

    private struct Token {
        let range: NSRange
        let kind: TokenKind
    }

    private static let tokenRegex = try! NSRegularExpression(
        pattern: #"(#[^\n]*)|("""[\s\S]*?"""|'''[\s\S]*?'''|"(?:\\.|[^"\\\n])*"|'(?:\\.|[^'\\\n])*')|(@[A-Za-z_][A-Za-z0-9_.]*)|(\b\d+(?:\.\d+)?(?:[eE][+-]?\d+)?\b)|(\b(?:False|None|True|and|as|assert|async|await|break|class|continue|def|del|elif|else|except|finally|for|from|global|if|import|in|is|lambda|nonlocal|not|or|pass|raise|return|try|while|with|yield|match|case)\b)|(\b(?:print|len|range|str|int|float|list|dict|set|tuple|open|super|self|enumerate|zip|map|filter|sum|min|max|abs|any|all|isinstance|type|Exception|ValueError|TypeError|KeyError|IndexError)\b)"#
    )

    static func attributedString(_ code: String) -> AttributedString {
        var result = AttributedString(code)
        result.font = .system(size: 15, design: .monospaced)
        result.foregroundColor = .primary
        guard code.utf16.count <= 500_000 else { return result }
        for token in tokens(in: code) {
            guard let stringRange = Range(token.range, in: code),
                  let range = Range(stringRange, in: result) else { continue }
            result[range].foregroundColor = color(for: token.kind)
        }
        return result
    }

    static func nsAttributedString(_ code: String, font: UIFont) -> NSAttributedString {
        let result = NSMutableAttributedString(
            string: code,
            attributes: [
                .font: font,
                .foregroundColor: UIColor.label
            ]
        )
        for token in tokens(in: code) {
            result.addAttribute(.foregroundColor,
                                value: uiColor(for: token.kind),
                                range: token.range)
        }
        return result
    }

    static func apply(to textView: UITextView) {
        let font = textView.font ?? .monospacedSystemFont(ofSize: 15, weight: .regular)
        let typingAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.label
        ]
        if let text = textView.text, !text.isEmpty, text.utf16.count <= 200_000 {
            let selection = textView.selectedRange
            let offset = textView.contentOffset
            textView.attributedText = nsAttributedString(text, font: font)
            textView.selectedRange = selection
            textView.contentOffset = offset
        }
        textView.typingAttributes = typingAttributes
    }

    private static func tokens(in code: String) -> [Token] {
        let range = NSRange(location: 0, length: (code as NSString).length)
        return tokenRegex.matches(in: code, range: range).compactMap { match in
            let kind: TokenKind
            if match.range(at: 1).location != NSNotFound {
                kind = .comment
            } else if match.range(at: 2).location != NSNotFound {
                kind = .string
            } else if match.range(at: 3).location != NSNotFound {
                kind = .decorator
            } else if match.range(at: 4).location != NSNotFound {
                kind = .number
            } else if match.range(at: 5).location != NSNotFound {
                kind = .keyword
            } else if match.range(at: 6).location != NSNotFound {
                kind = .builtin
            } else {
                return nil
            }
            return Token(range: match.range, kind: kind)
        }
    }

    private static func color(for kind: TokenKind) -> Color {
        switch kind {
        case .comment: return .green
        case .string: return .red
        case .decorator: return .orange
        case .number: return .blue
        case .keyword: return .pink
        case .builtin: return .teal
        }
    }

    private static func uiColor(for kind: TokenKind) -> UIColor {
        switch kind {
        case .comment: return .systemGreen
        case .string: return .systemRed
        case .decorator: return .systemOrange
        case .number: return .systemBlue
        case .keyword: return .systemPink
        case .builtin: return .systemTeal
        }
    }
}
