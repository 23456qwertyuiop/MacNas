//
//  Preview.swift
//  MacNas
//
//  文件预览服务。
//
//  设计原则：不引入任何第三方依赖，只用 macOS 自带的两个工具：
//    · textutil —— 把 Word / RTF / ODT 这类“文字处理文档”转成 HTML（段落、表格都能保留）
//    · qlmanage —— 用系统的 QuickLook 给表格、幻灯片、图片等生成首页缩略图
//  图片 / 视频 / 音频 / PDF 则直接走原文件（浏览器原生就能渲染，且支持 Range 拖动）。
//
//  转换结果按内容哈希缓存，第二次打开同一个文件是瞬时的。
//

import Foundation

// MARK: - 类型判断

enum PreviewKind: String {
    case image          // 图片：直接给原文件
    case video          // 视频：给原文件，支持 Range
    case audio          // 音频
    case pdf            // PDF：交给浏览器原生查看器
    case text           // 纯文本 / 代码 / CSV / JSON：服务器读出来当文本用
    case document       // Word/RTF/ODT：textutil 转 HTML
    case render         // 表格/幻灯片/其它：QuickLook 首页缩略图
    case none           // 无法预览，只能下载
}

struct PreviewMeta {
    var kind: PreviewKind
    var mime: String
    var previewable: Bool
    var note: String?

    var dictionary: [String: Any] {
        var result: [String: Any] = [
            "kind": kind.rawValue,
            "mime": mime,
            "previewable": previewable
        ]
        if let note { result["note"] = note }
        return result
    }
}

enum PreviewRegistry {

    private static let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "bmp", "tiff", "tif", "svg", "avif", "ico"]
    private static let videoExtensions: Set<String> = ["mp4", "m4v", "mov", "mkv", "webm", "avi", "flv", "wmv", "mpg", "mpeg", "3gp"]
    private static let audioExtensions: Set<String> = ["mp3", "m4a", "wav", "flac", "aac", "ogg", "oga", "opus", "aiff", "aif", "wma"]
    private static let textExtensions: Set<String> = [
        "txt", "md", "markdown", "log", "csv", "tsv", "json", "xml", "yml", "yaml", "toml", "ini", "conf", "cfg",
        "html", "htm", "css", "js", "mjs", "ts", "tsx", "jsx", "py", "rb", "go", "rs", "java", "kt", "c", "h", "cpp", "hpp",
        "swift", "sh", "bash", "zsh", "sql", "plist", "srt", "vtt", "tex", "diff", "patch", "properties", "env"
    ]
    private static let documentExtensions: Set<String> = ["doc", "docx", "rtf", "rtfd", "odt", "wordml", "webarchive", "word"]
    private static let renderExtensions: Set<String> = [
        "xls", "xlsx", "xlsm", "numbers", "csv.xls", "ods",
        "ppt", "pptx", "pps", "ppsx", "key", "odp",
        "pages", "epub", "dwg", "sketch", "stl", "obj", "psd", "ai", "eps"
    ]

    static func extensionOf(_ fileName: String) -> String {
        (fileName as NSString).pathExtension.lowercased()
    }

    static func meta(forFileName name: String) -> PreviewMeta {
        let ext = extensionOf(name)
        let mime = MimeTypes.guess(forFileName: name)

        if imageExtensions.contains(ext) {
            return PreviewMeta(kind: .image, mime: mime, previewable: true, note: nil)
        }
        if videoExtensions.contains(ext) {
            return PreviewMeta(kind: .video, mime: mime, previewable: true, note: nil)
        }
        if audioExtensions.contains(ext) {
            return PreviewMeta(kind: .audio, mime: mime, previewable: true, note: nil)
        }
        if ext == "pdf" {
            return PreviewMeta(kind: .pdf, mime: "application/pdf", previewable: true, note: nil)
        }
        if textExtensions.contains(ext) {
            return PreviewMeta(kind: .text, mime: "text/plain; charset=utf-8", previewable: true, note: nil)
        }
        if documentExtensions.contains(ext) {
            return PreviewMeta(kind: .document, mime: "text/html; charset=utf-8", previewable: true,
                               note: "已转换成网页预览，排版可能与原文件略有差异")
        }
        if renderExtensions.contains(ext) {
            return PreviewMeta(kind: .render, mime: "image/png", previewable: true,
                               note: "显示的是第一页的渲染图，完整内容请下载后用对应软件打开")
        }
        // 其它类型交给 QuickLook 试试；预览不出来就只给下载
        return PreviewMeta(kind: .render, mime: "image/png", previewable: true, note: "由系统 QuickLook 生成")
    }
}

// MARK: - 转换服务

enum PreviewError: Error, LocalizedError {
    case failed(String)
    case timeout

    var errorDescription: String? {
        switch self {
        case .failed(let message): return message
        case .timeout: return "转换超时"
        }
    }
}

final class PreviewService: @unchecked Sendable {

    static let shared = PreviewService()

    /// 同时最多跑几个转换进程：太多会把机器拖住，太少会让「照片墙」这种
    /// 一次要几十张缩略图的场景排队排到天荒地老。4 个是实测比较平衡的值。
    private let conversionSlots = DispatchSemaphore(value: 4)
    /// 等槽位的最长时间：超时宁可让浏览器拿到一个「忙」的错误稍后重试，
    /// 也不要把请求线程一直挂在这里（否则会越堆越多）
    private let slotTimeout: TimeInterval = 20

    private func acquireSlot() throws {
        if conversionSlots.wait(timeout: .now() + slotTimeout) == .timedOut {
            throw PreviewError.failed("服务器正忙，请稍后再试")
        }
    }
    private let cacheQueue = DispatchQueue(label: "cn.zenlc.macnas.preview.cache")
    private let textLimit = 512 * 1024          // 文本预览最多读 512KB
    private let cacheLimitBytes: Int64 = 256 * 1024 * 1024

    private lazy var cacheDirectory: URL = {
        let base = AppPaths.supportDirectory.appendingPathComponent("preview-cache", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    // MARK: 文本

    /// 读出文本文件内容（按 UTF-8 → GB18030 → Latin-1 依次尝试，照顾中文老文件）
    func plainText(fileURL: URL) throws -> Data {
        guard let handle = try? FileHandle(forReadingFrom: fileURL) else {
            throw PreviewError.failed("无法读取文件")
        }
        defer { try? handle.close() }
        let data = (try? handle.read(upToCount: textLimit)) ?? Data()
        let truncated = data.count >= textLimit

        var text = decodeText(data)
        if truncated { text += "\n\n⋯⋯（文件较大，预览只显示前 512KB，完整内容请下载）" }
        return Data(text.utf8)
    }

    private func decodeText(_ data: Data) -> String {
        if let text = String(data: data, encoding: .utf8) { return text }
        // GB18030（很多中文老文件是它）
        let gbEncoding = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
        if let text = String(data: data, encoding: String.Encoding(rawValue: gbEncoding)) { return text }
        if let text = String(data: data, encoding: .isoLatin1) { return text }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: Word / RTF / ODT → HTML

    func documentHTML(fileURL: URL, cacheKey: String) throws -> Data {
        if let cached = readCache(key: cacheKey, ext: "html") { return cached }

        let output = try runProcess("/usr/bin/textutil",
                                    ["-convert", "html", "-stdout", fileURL.path],
                                    timeout: 25)
        guard !output.isEmpty, hasVisibleText(output) else {
            throw PreviewError.failed("这个文档转换后没有内容")
        }
        writeCache(key: cacheKey, ext: "html", data: output)
        return output
    }

    /// textutil 有时会输出一个空壳 HTML，这里检查正文里到底有没有可见文字
    private func hasVisibleText(_ html: Data) -> Bool {
        guard let text = String(data: html, encoding: .utf8) else { return false }
        var stripped = text
        stripped = stripped.replacingOccurrences(of: "<[^>]*>", with: " ", options: .regularExpression)
        stripped = stripped.replacingOccurrences(of: "&nbsp;", with: " ")
        let meaningful = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        return meaningful.count > 8
    }

    // MARK: 其它格式 → QuickLook 缩略图

    func renderedImage(fileURL: URL, cacheKey: String) throws -> Data {
        if let cached = readCache(key: cacheKey, ext: "png") { return cached }

        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("macnas-preview-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }

        _ = try? runProcess("/usr/bin/qlmanage",
                            ["-t", "-s", "1400", "-o", temporary.path, fileURL.path],
                            timeout: 20)

        let produced = (try? FileManager.default.contentsOfDirectory(at: temporary, includingPropertiesForKeys: nil)) ?? []
        guard let image = produced.first(where: { $0.pathExtension.lowercased() == "png" }),
              let data = try? Data(contentsOf: image), !data.isEmpty else {
            throw PreviewError.failed("系统没能为这个文件生成预览图")
        }
        writeCache(key: cacheKey, ext: "png", data: data)
        return data
    }

    // MARK: 图片缩略图（sips 缩放，比 QuickLook 快得多）

    /// 缩略图结果（数据 + 真实 MIME 类型）
    struct Thumbnail {
        var data: Data
        var mime: String
    }

    /// 给图片生成小尺寸缩略图；不是图片就退回 QuickLook 渲染图
    func thumbnail(fileURL: URL, cacheKey: String, maxPixel: Int) throws -> Thumbnail {
        let key = "\(cacheKey)-thumb\(maxPixel)"
        if let cached = readCache(key: key, ext: "jpg") {
            return Thumbnail(data: cached, mime: "image/jpeg")
        }

        try acquireSlot()
        defer { conversionSlots.signal() }

        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("macnas-thumb-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: output) }

        _ = try? runProcessLocked("/usr/bin/sips",
                                  ["-Z", String(maxPixel), "-s", "format", "jpeg",
                                   "-s", "formatOptions", "72", fileURL.path, "--out", output.path],
                                  timeout: 20)
        if let data = try? Data(contentsOf: output), !data.isEmpty, data.starts(with: [0xFF, 0xD8]) {
            writeCache(key: key, ext: "jpg", data: data)
            return Thumbnail(data: data, mime: "image/jpeg")
        }
        // 不是图片（或 sips 处理不了）→ 用系统的 QuickLook 渲染（拿到的是 PNG）
        let png = try renderedImage(fileURL: fileURL, cacheKey: cacheKey)
        return Thumbnail(data: png, mime: "image/png")
    }

    // MARK: 进程

    @discardableResult
    private func runProcess(_ path: String, _ arguments: [String], timeout: TimeInterval) throws -> Data {
        try acquireSlot()
        defer { conversionSlots.signal() }
        return try runProcessLocked(path, arguments, timeout: timeout)
    }

    /// 调用方已经占住并发槽位时用这个
    @discardableResult
    private func runProcessLocked(_ path: String, _ arguments: [String], timeout: TimeInterval) throws -> Data {
        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw PreviewError.failed("系统缺少 \(path)")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            throw PreviewError.failed("无法启动转换进程：\(error.localizedDescription)")
        }

        let semaphore = DispatchSemaphore(value: 0)
        var collected = Data()
        DispatchQueue.global(qos: .userInitiated).async {
            collected = output.fileHandleForReading.readDataToEndOfFile()
            semaphore.signal()
        }

        if semaphore.wait(timeout: .now() + timeout) == .timedOut {
            process.terminate()
            if semaphore.wait(timeout: .now() + 2) == .timedOut {
                kill(process.processIdentifier, SIGKILL)
                _ = semaphore.wait(timeout: .now() + 1)
            }
            throw PreviewError.timeout
        }
        process.waitUntilExit()
        return collected
    }

    // MARK: 缓存

    private func cacheURL(key: String, ext: String) -> URL {
        cacheDirectory.appendingPathComponent("\(key).\(ext)")
    }

    private func readCache(key: String, ext: String) -> Data? {
        cacheQueue.sync {
            guard let data = try? Data(contentsOf: cacheURL(key: key, ext: ext)), !data.isEmpty else { return nil }
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: cacheURL(key: key, ext: ext).path)
            return data
        }
    }

    private func writeCache(key: String, ext: String, data: Data) {
        cacheQueue.sync {
            try? data.write(to: cacheURL(key: key, ext: ext))
            trimCacheIfNeeded()
        }
    }

    /// 缓存超过 256MB 就按最后使用时间清掉旧的一半
    private func trimCacheIfNeeded() {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: cacheDirectory,
                                                                     includingPropertiesForKeys: keys) else { return }
        var entries: [(url: URL, size: Int64, date: Date)] = []
        var total: Int64 = 0
        for file in files {
            let values = try? file.resourceValues(forKeys: Set(keys))
            let size = Int64(values?.fileSize ?? 0)
            total += size
            entries.append((file, size, values?.contentModificationDate ?? .distantPast))
        }
        guard total > cacheLimitBytes else { return }
        entries.sort { $0.date < $1.date }
        var removed: Int64 = 0
        for entry in entries {
            guard removed < total / 2 else { break }
            try? FileManager.default.removeItem(at: entry.url)
            removed += entry.size
        }
        LogCenter.shared.debug("预览缓存已清理 \(removed / 1024 / 1024)MB")
    }
}
