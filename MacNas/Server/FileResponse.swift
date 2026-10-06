//
//  FileResponse.swift
//  MacNas
//
//  下载响应的公共实现（普通下载与 WebDAV GET/HEAD 共用），支持 Range 断点续传。
//

import Foundation

enum FileResponse {

    static func make(_ request: HTTPRequest,
                     entry: FileEntry,
                     url: URL,
                     inline: Bool) -> HTTPResponse {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? entry.size

        var offset: Int64 = 0
        var length = size
        var status = 200
        var contentRange: String?

        if let rangeHeader = request.headers["range"], rangeHeader.hasPrefix("bytes=") {
            let spec = rangeHeader.dropFirst("bytes=".count)
            let pieces = spec.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
            if pieces.count == 2 {
                if let start = Int64(pieces[0]), start >= 0, start < max(size, 1) {
                    let end = Int64(pieces[1]).map { min($0, size - 1) } ?? (size - 1)
                    if end >= start {
                        offset = start
                        length = end - start + 1
                        status = 206
                        contentRange = "bytes \(start)-\(end)/\(size)"
                    }
                } else if pieces[0].isEmpty, let suffix = Int64(pieces[1]), suffix > 0 {
                    offset = max(0, size - suffix)
                    length = size - offset
                    status = 206
                    contentRange = "bytes \(offset)-\(size - 1)/\(size)"
                }
            }
        }

        var response = HTTPResponse(status: status, body: .file(url: url, offset: offset, length: length))
        response.headers["Content-Type"] = MimeTypes.guess(forFileName: entry.name)
        response.headers["Accept-Ranges"] = "bytes"
        response.headers["Content-Disposition"] = contentDisposition(name: entry.name, inline: inline)
        response.headers["ETag"] = "\"\(entry.sha256)\""
        if let contentRange { response.headers["Content-Range"] = contentRange }
        return response
    }

    static func contentDisposition(name: String, inline: Bool) -> String {
        let ascii = name.unicodeScalars.map { scalar -> Character in
            scalar.isASCII && scalar.value >= 32 && scalar.value < 127 && scalar != "\"" ? Character(scalar) : "_"
        }
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        let encoded = name.addingPercentEncoding(withAllowedCharacters: allowed) ?? name
        let kind = inline ? "inline" : "attachment"
        return "\(kind); filename=\"\(String(ascii))\"; filename*=UTF-8''\(encoded)"
    }
}
