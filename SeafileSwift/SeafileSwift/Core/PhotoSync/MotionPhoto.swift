import Foundation

enum MotionPhoto {
    static let livePhotoUUID: [UInt8] = [
        0xBE, 0x7A, 0xCF, 0xCB, 0x97, 0xA9, 0x42, 0xE8,
        0x9C, 0x71, 0x99, 0x94, 0x91, 0xE3, 0xAF, 0xAC
    ]

    struct VideoLocation {
        let range: Range<Int>
        let fileExtension: String
    }

    private struct Box {
        let type: String
        let offset: Int
        let headerSize: Int
        let size: Int
    }

    static func isMotionPhoto(_ data: Data) -> Bool {
        videoLocation(in: data) != nil
    }

    static func videoLocation(in data: Data) -> VideoLocation? {
        if data.count > 2, data[data.startIndex] == 0xFF, data[data.startIndex + 1] == 0xD8 {
            return jpegVideoLocation(in: data)
        }
        if let box = mpvdBox(in: data) {
            let payload = (box.offset + box.headerSize)..<(box.offset + box.size)
            guard payload.lowerBound < payload.upperBound else { return nil }
            return VideoLocation(range: payload,
                                 fileExtension: videoExtension(for: data.subdata(in: payload)))
        }
        return nil
    }

    static func videoData(in data: Data) -> Data? {
        guard let location = videoLocation(in: data) else { return nil }
        return data.subdata(in: location.range)
    }

    static func videoFile(from data: Data, directory: URL = FileManager.default.temporaryDirectory) -> URL? {
        guard let location = videoLocation(in: data) else { return nil }
        let url = directory.appendingPathComponent("MotionPhoto-\(UUID().uuidString).\(location.fileExtension)")
        do {
            try data.subdata(in: location.range).write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }

    /// Image bytes without the appended XMP/video boxes. Returns nil when the
    /// file does not carry a motion-photo trailer.
    static func imageData(from data: Data) -> Data? {
        guard let boxes = topLevelBoxes(in: data),
              boxes.contains(where: { $0.type == "mpvd" }) else {
            return nil
        }
        var end = 0
        for box in boxes {
            if box.type == "uuid" || box.type == "mpvd" { break }
            end = box.offset + box.size
        }
        guard end > 0, end <= data.count else { return nil }
        return data.prefix(end)
    }

    static func compose(imageData: Data, videoData: Data) -> Data? {
        guard isHEIC(imageData), isVideo(videoData) else { return nil }
        let xmp = xmpData(videoLength: videoData.count)
        var result = Data(capacity: imageData.count + xmp.count + videoData.count + 40)
        result.append(imageData)
        result.append(uuidBox(xmp))
        result.append(mpvdBox(videoData))
        return result
    }

    static func isHEIC(_ data: Data) -> Bool {
        guard data.count >= 12, fourCC(data, at: 4) == "ftyp" else { return false }
        let boxSize = Int(beUInt32(data, at: 0))
        let brandEnd = min(boxSize > 0 ? boxSize : 32, data.count)
        var offset = 8
        while offset + 4 <= brandEnd {
            let brand = fourCC(data, at: offset)
            if ["heic", "heix", "hevc", "hevx", "heim", "heis", "hevm", "hevs", "mif1", "msf1"].contains(brand) {
                return true
            }
            offset += 4
        }
        return false
    }

    static func isVideo(_ data: Data) -> Bool {
        guard data.count >= 12 else { return false }
        let type = fourCC(data, at: 4)
        return type == "ftyp" || type == "moov" || type == "mdat" || type == "wide"
    }

    // MARK: - Trailer detection

    private static func mpvdBox(in data: Data) -> Box? {
        if let boxes = topLevelBoxes(in: data),
           let box = boxes.last(where: { $0.type == "mpvd" }) {
            return box
        }
        // mdat boxes with a zero size field swallow appended boxes, so fall
        // back to locating the mpvd trailer from the end of the file.
        let marker = Data("mpvd".utf8)
        var searchEnd = data.count
        while searchEnd > 12 {
            guard let range = data.range(of: marker,
                                         options: .backwards,
                                         in: 0..<searchEnd),
                  range.lowerBound >= 4 else {
                return nil
            }
            let start = range.lowerBound - 4
            let size = Int(beUInt32(data, at: start))
            if size >= 8, start + size == data.count {
                return Box(type: "mpvd", offset: start, headerSize: 8, size: size)
            }
            searchEnd = range.lowerBound
        }
        return nil
    }

    private static func jpegVideoLocation(in data: Data) -> VideoLocation? {
        guard data.count > 4 else { return nil }
        guard data.range(of: Data("MicroVideoOffset".utf8)) != nil else { return nil }
        guard let offset = intAttribute("MicroVideoOffset", in: data), offset > 0, offset < data.count else {
            return nil
        }
        let start = data.count - offset
        return VideoLocation(range: start..<data.count,
                             fileExtension: videoExtension(for: data.subdata(in: start..<data.count)))
    }

    private static func intAttribute(_ name: String, in data: Data) -> Int? {
        guard let nameRange = data.range(of: Data(name.utf8)) else { return nil }
        let tailEnd = min(data.count, nameRange.upperBound + 80)
        let tail = data[nameRange.upperBound..<tailEnd]
        guard let quoteIndex = tail.firstIndex(where: { $0 == 0x22 || $0 == 0x27 }) else { return nil }
        let quote = tail[quoteIndex]
        var digits = ""
        var index = tail.index(after: quoteIndex)
        while index < tail.endIndex {
            let byte = tail[index]
            if byte == quote { break }
            if byte >= 0x30, byte <= 0x39 {
                digits.append(Character(UnicodeScalar(byte)))
            }
            index = tail.index(after: index)
        }
        return Int(digits)
    }

    private static func videoExtension(for video: Data) -> String {
        guard video.count >= 12 else { return "mp4" }
        switch fourCC(video, at: 4) {
        case "ftyp":
            let brand = fourCC(video, at: 8)
            return brand == "qt  " || brand == "M4V " ? "mov" : "mp4"
        case "moov", "wide":
            return "mov"
        default:
            return "mp4"
        }
    }

    // MARK: - Composition

    private static func xmpData(videoLength: Int) -> Data {
        let timestamp = -1
        var xmp = ""
        xmp += "<x:xmpmeta xmlns:x=\"adobe:ns:meta/\" x:xmptk=\"XMP Core 6.0.0\">\n"
        xmp += "   <rdf:RDF xmlns:rdf=\"http://www.w3.org/1999/02/22-rdf-syntax-ns#\">\n"
        xmp += "      <rdf:Description rdf:about=\"\"\n"
        xmp += "            xmlns:GCamera=\"http://ns.google.com/photos/1.0/camera/\"\n"
        xmp += "            xmlns:Container=\"http://ns.google.com/photos/1.0/container/\"\n"
        xmp += "            xmlns:Item=\"http://ns.google.com/photos/1.0/container/item/\"\n"
        xmp += "            GCamera:MotionPhoto=\"1\"\n"
        xmp += "            GCamera:MotionPhotoVersion=\"1\"\n"
        xmp += "            GCamera:MotionPhotoPresentationTimestampUs=\"\(timestamp)\"\n"
        xmp += "            GCamera:MicroVideo=\"1\"\n"
        xmp += "            GCamera:MicroVideoVersion=\"1\"\n"
        xmp += "            GCamera:MicroVideoOffset=\"\(videoLength)\"\n"
        xmp += "            GCamera:MicroVideoPresentationTimestampUs=\"\(timestamp)\">\n"
        xmp += "         <Container:Directory>\n"
        xmp += "            <rdf:Seq>\n"
        xmp += "               <rdf:li rdf:parseType=\"Resource\">\n"
        xmp += "                  <Container:Item\n"
        xmp += "                     Item:Mime=\"image/heic\"\n"
        xmp += "                     Item:Semantic=\"Primary\"\n"
        xmp += "                     Item:Length=\"0\"\n"
        xmp += "                     Item:Padding=\"0\"/>\n"
        xmp += "               </rdf:li>\n"
        xmp += "               <rdf:li rdf:parseType=\"Resource\">\n"
        xmp += "                  <Container:Item\n"
        xmp += "                     Item:Mime=\"video/quicktime\"\n"
        xmp += "                     Item:Semantic=\"MotionPhoto\"\n"
        xmp += "                     Item:Length=\"\(videoLength)\"\n"
        xmp += "                     Item:Padding=\"8\"/>\n"
        xmp += "               </rdf:li>\n"
        xmp += "            </rdf:Seq>\n"
        xmp += "         </Container:Directory>\n"
        xmp += "      </rdf:Description>\n"
        xmp += "   </rdf:RDF>\n"
        xmp += "</x:xmpmeta>"
        return Data(xmp.utf8)
    }

    private static func uuidBox(_ xmp: Data) -> Data {
        var box = Data(capacity: 24 + xmp.count)
        box.append(contentsOf: beUInt32Bytes(UInt32(24 + xmp.count)))
        box.append(Data("uuid".utf8))
        box.append(contentsOf: livePhotoUUID)
        box.append(xmp)
        return box
    }

    private static func mpvdBox(_ video: Data) -> Data {
        var box = Data(capacity: 8 + video.count)
        box.append(contentsOf: beUInt32Bytes(UInt32(8 + video.count)))
        box.append(Data("mpvd".utf8))
        box.append(video)
        return box
    }

    // MARK: - ISO BMFF scanning

    private static func topLevelBoxes(in data: Data) -> [Box]? {
        guard data.count >= 8 else { return nil }
        var boxes: [Box] = []
        var offset = 0
        while offset + 8 <= data.count {
            let size32 = beUInt32(data, at: offset)
            let type = fourCC(data, at: offset + 4)
            var headerSize = 8
            var size = Int(size32)
            if size32 == 1 {
                guard offset + 16 <= data.count else { break }
                let size64 = beUInt64(data, at: offset + 8)
                guard size64 >= 16, size64 <= UInt64(Int.max) else { break }
                size = Int(size64)
                headerSize = 16
            } else if size32 == 0 {
                size = data.count - offset
            }
            guard size >= headerSize, offset + size <= data.count else { break }
            boxes.append(Box(type: type, offset: offset, headerSize: headerSize, size: size))
            offset += size
            if size32 == 0 { break }
        }
        return boxes.isEmpty ? nil : boxes
    }

    private static func fourCC(_ data: Data, at offset: Int) -> String {
        guard offset >= 0, offset + 4 <= data.count else { return "" }
        let bytes = [UInt8](data[offset..<(offset + 4)])
        return String(bytes: bytes, encoding: .isoLatin1) ?? ""
    }

    private static func beUInt32(_ data: Data, at offset: Int) -> UInt32 {
        var value: UInt32 = 0
        for index in 0..<4 {
            value = (value << 8) | UInt32(data[data.startIndex + offset + index])
        }
        return value
    }

    private static func beUInt64(_ data: Data, at offset: Int) -> UInt64 {
        var value: UInt64 = 0
        for index in 0..<8 {
            value = (value << 8) | UInt64(data[data.startIndex + offset + index])
        }
        return value
    }

    private static func beUInt32Bytes(_ value: UInt32) -> [UInt8] {
        [UInt8((value >> 24) & 0xFF),
         UInt8((value >> 16) & 0xFF),
         UInt8((value >> 8) & 0xFF),
         UInt8(value & 0xFF)]
    }
}
