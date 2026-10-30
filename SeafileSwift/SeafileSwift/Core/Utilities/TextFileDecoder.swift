import Foundation

enum TextFileDecoder {
    static func decode(_ data: Data) -> String? {
        guard !data.isEmpty else { return "" }

        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            if let text = String(data: data, encoding: .utf16) {
                return text
            }
        }

        if let text = String(data: data, encoding: .utf8) {
            return text
        }

        var converted: NSString?
        var lossy = ObjCBool(false)
        let detected = NSString.stringEncoding(for: data,
                                               encodingOptions: nil,
                                               convertedString: &converted,
                                               usedLossyConversion: &lossy)
        if detected != 0, let converted {
            return converted as String
        }

        let fallbackEncodings: [String.Encoding] = [
            legacyEncoding(CFStringEncodings.GB_18030_2000),
            legacyEncoding(CFStringEncodings.big5),
            legacyEncoding(CFStringEncodings.shiftJIS),
            legacyEncoding(CFStringEncodings.EUC_KR),
            .windowsCP1252,
            .isoLatin1
        ]
        for encoding in fallbackEncodings {
            if let text = String(data: data, encoding: encoding) {
                return text
            }
        }
        return nil
    }

    static func read(url: URL, limit: Int) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.intValue,
              size <= limit,
              let data = try? Data(contentsOf: url) else { return nil }
        return decode(data)
    }

    private static func legacyEncoding(_ encoding: CFStringEncodings) -> String.Encoding {
        String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(encoding.rawValue)))
    }
}
