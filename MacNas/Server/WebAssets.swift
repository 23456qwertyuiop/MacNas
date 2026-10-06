//
//  WebAssets.swift
//  MacNas
//
//  网页静态资源（随 App 打包）。设置 MACNAS_WEB_DIR 可在开发时直接读取源码目录。
//

import Foundation

final class WebAssets: @unchecked Sendable {

    struct Asset {
        var data: Data
        var contentType: String
        var etag: String
    }

    private let lock = NSLock()
    private var cache: [String: Asset] = [:]
    private let overrideDirectory: URL?

    /// 允许暴露的文件名白名单，防止路径穿越
    private static let allowedNames: Set<String> = [
        "index.html", "app.js", "styles.css", "logo.png",
        "manifest.webmanifest", "sw.js"
    ]

    init() {
        if let directory = ProcessInfo.processInfo.environment["MACNAS_WEB_DIR"], !directory.isEmpty {
            overrideDirectory = URL(fileURLWithPath: directory, isDirectory: true)
            LogCenter.shared.info("网页资源目录已被环境变量覆盖：\(directory)")
        } else {
            overrideDirectory = nil
        }
    }

    /// 把 index.html 里的 app.js / styles.css 换成「带内容指纹」的地址。
    ///
    /// 为什么必须这么做：手机把网页加到主屏后会装一个 Service Worker。
    /// 只要 sw.js 自己没变，浏览器就可能一直用缓存里的旧 /app.js，
    /// 服务端更新了、用户那边却还跑着几天前的前端（新功能点了没反应）。
    /// 带上内容指纹后 URL 变了，任何缓存都只能重新去取，这一类问题就不可能再发生。
    func fingerprintedIndex() -> Asset? {
        guard var index = asset(named: "index.html") else { return nil }
        guard let text = String(data: index.data, encoding: .utf8) else { return index }
        let version = (asset(named: "app.js")?.etag.prefix(10)).map(String.init) ?? "0"
        let styleVersion = (asset(named: "styles.css")?.etag.prefix(10)).map(String.init) ?? "0"
        var updated = text
            .replacingOccurrences(of: "app.js\"", with: "app.js?v=\(version)\"")
            .replacingOccurrences(of: "styles.css\"", with: "styles.css?v=\(styleVersion)\"")
            .replacingOccurrences(of: "app.js'", with: "app.js?v=\(version)'")
            .replacingOccurrences(of: "styles.css'", with: "styles.css?v=\(styleVersion)'")
        // 已经是带参数的地址就不要再加一次
        updated = updated.replacingOccurrences(of: "?v=\(version)?v=\(version)", with: "?v=\(version)")
        guard let data = updated.data(using: .utf8), data != index.data else { return index }
        index.data = data
        index.etag = FileHash.sha256(of: data)
        return index
    }

    func asset(named name: String) -> Asset? {
        let clean = name.hasPrefix("/") ? String(name.dropFirst()) : name
        guard Self.allowedNames.contains(clean) else { return nil }

        if let overrideDirectory {
            let url = overrideDirectory.appendingPathComponent(clean)
            guard let data = try? Data(contentsOf: url) else { return nil }
            return Asset(data: data, contentType: Self.contentType(for: clean), etag: FileHash.sha256(of: data))
        }

        lock.lock()
        if let cached = cache[clean] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        guard let data = loadFromBundle(clean) else { return nil }
        let asset = Asset(data: data, contentType: Self.contentType(for: clean), etag: FileHash.sha256(of: data))
        lock.lock()
        cache[clean] = asset
        lock.unlock()
        return asset
    }

    private func loadFromBundle(_ name: String) -> Data? {
        let pieces = name.split(separator: ".")
        let ext = pieces.count > 1 ? String(pieces.last!) : ""
        let base = pieces.dropLast().joined(separator: ".")
        if let url = Bundle.main.url(forResource: base, withExtension: ext),
           let data = try? Data(contentsOf: url) {
            return data
        }
        guard let resourceURL = Bundle.main.resourceURL else { return nil }
        let candidates = [
            resourceURL.appendingPathComponent("web/\(name)"),
            resourceURL.appendingPathComponent(name)
        ]
        for candidate in candidates {
            if let data = try? Data(contentsOf: candidate) { return data }
        }
        LogCenter.shared.error("网页资源缺失：\(name)")
        return nil
    }

    static func contentType(for name: String) -> String {
        if name.hasSuffix("manifest.webmanifest") { return "application/manifest+json; charset=utf-8" }
        if name.hasSuffix("sw.js") { return "application/javascript; charset=utf-8" }
        switch (name as NSString).pathExtension.lowercased() {
        case "html": return "text/html; charset=utf-8"
        case "css": return "text/css; charset=utf-8"
        case "js": return "application/javascript; charset=utf-8"
        case "svg": return "image/svg+xml"
        case "png": return "image/png"
        case "webmanifest": return "application/manifest+json"
        default: return "application/octet-stream"
        }
    }
}

enum MimeTypes {
    static func guess(forFileName name: String) -> String {
        switch (name as NSString).pathExtension.lowercased() {
        case "txt", "md", "log": return "text/plain; charset=utf-8"
        case "html", "htm": return "text/html; charset=utf-8"
        case "json": return "application/json; charset=utf-8"
        case "csv": return "text/csv; charset=utf-8"
        case "jpg", "jpeg": return "image/jpeg"
        case "png": return "image/png"
        case "gif": return "image/gif"
        case "webp": return "image/webp"
        case "heic": return "image/heic"
        case "svg": return "image/svg+xml"
        case "bmp": return "image/bmp"
        case "mp4", "m4v": return "video/mp4"
        case "mov": return "video/quicktime"
        case "mkv": return "video/x-matroska"
        case "webm": return "video/webm"
        case "mp3": return "audio/mpeg"
        case "m4a": return "audio/mp4"
        case "wav": return "audio/wav"
        case "flac": return "audio/flac"
        case "pdf": return "application/pdf"
        case "zip": return "application/zip"
        case "7z": return "application/x-7z-compressed"
        case "rar": return "application/vnd.rar"
        case "tar": return "application/x-tar"
        case "gz": return "application/gzip"
        case "doc": return "application/msword"
        case "docx": return "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
        case "xls": return "application/vnd.ms-excel"
        case "xlsx": return "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        case "ppt": return "application/vnd.ms-powerpoint"
        case "pptx": return "application/vnd.openxmlformats-officedocument.presentationml.presentation"
        default: return "application/octet-stream"
        }
    }

    static func isImage(_ name: String) -> Bool {
        guess(forFileName: name).hasPrefix("image/")
    }
}
