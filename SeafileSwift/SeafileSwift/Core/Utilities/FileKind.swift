import Foundation
import UniformTypeIdentifiers

enum FileKind {
    case folder
    case image
    case video
    case audio
    case pdf
    case text
    case officeDocument
    case archive
    case other

    static func of(name: String, isDirectory: Bool = false) -> FileKind {
        if isDirectory { return .folder }
        let ext = (name as NSString).pathExtension.lowercased()
        switch ext {
        case "png", "jpg", "jpeg", "gif", "heic", "heif", "webp", "bmp", "tif", "tiff", "svg", "raw", "dng":
            return .image
        case "mp4", "mov", "m4v", "avi", "mkv", "webm", "3gp", "flv", "wmv":
            return .video
        case "mp3", "wav", "aac", "m4a", "flac", "ogg", "opus", "aiff":
            return .audio
        case "pdf":
            return .pdf
        case "txt", "md", "markdown", "log", "csv", "json", "xml", "html", "htm", "yaml", "yml",
             "swift", "m", "h", "c", "cpp", "js", "ts", "py", "pyw", "pyi", "rb", "go", "rs", "java", "kt",
             "css", "sh", "conf", "ini", "toml":
            return .text
        case "doc", "docx", "xls", "xlsx", "ppt", "pptx", "pages", "numbers", "key", "rtf", "sdoc":
            return .officeDocument
        case "zip", "rar", "7z", "tar", "gz", "bz2", "xz":
            return .archive
        default:
            return .other
        }
    }

    var symbol: String {
        switch self {
        case .folder: return "folder.fill"
        case .image: return "photo.fill"
        case .video: return "play.rectangle.fill"
        case .audio: return "waveform"
        case .pdf: return "doc.richtext.fill"
        case .text: return "doc.plaintext.fill"
        case .officeDocument: return "doc.text.fill"
        case .archive: return "archivebox.fill"
        case .other: return "doc.fill"
        }
    }

    var tint: [String] {
        switch self {
        case .folder: return ["#FFB74D", "#F57C00"]
        case .image: return ["#FF8A9B", "#E91E63"]
        case .video: return ["#B388FF", "#651FFF"]
        case .audio: return ["#80DEEA", "#00838F"]
        case .pdf: return ["#FF8A80", "#D32F2F"]
        case .text: return ["#90CAF9", "#1565C0"]
        case .officeDocument: return ["#A5D6A7", "#2E7D32"]
        case .archive: return ["#CFD8DC", "#546E7A"]
        case .other: return ["#B0BEC5", "#37474F"]
        }
    }

    var contentType: UTType? {
        switch self {
        case .folder: return nil
        case .image: return .image
        case .video: return .movie
        case .audio: return .audio
        case .pdf: return .pdf
        case .text: return .plainText
        case .officeDocument: return .content
        case .archive: return .archive
        case .other: return .data
        }
    }
}

extension String {
    var pathExtensionLowercased: String { (self as NSString).pathExtension.lowercased() }
}
