//
//  BodySink.swift
//  MacNas
//
//  请求体接收器：小请求写内存，上传大文件直接边收边写盘边算哈希。
//

import Foundation

protocol BodySink: AnyObject {
    func consume(_ data: Data) throws
    func finish() throws -> RequestBody
    func abort()
}

final class MemoryBodySink: BodySink {
    private let limit: Int
    private var buffer = Data()

    init(limit: Int = 4 * 1024 * 1024) {
        self.limit = limit
    }

    func consume(_ data: Data) throws {
        if buffer.count + data.count > limit {
            throw HTTPError(status: 413, message: "请求体过大")
        }
        buffer.append(data)
    }

    func finish() throws -> RequestBody { .data(buffer) }

    func abort() { buffer.removeAll() }
}

/// 上传专用：边收边写临时文件，同时增量计算 SHA-256
final class UploadBodySink: BodySink {
    let tempURL: URL
    private let handle: FileHandle
    private let hasher = StreamingHasher()
    private var finished = false

    init(tempURL: URL) throws {
        self.tempURL = tempURL
        let fm = FileManager.default
        try fm.createDirectory(at: tempURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        fm.createFile(atPath: tempURL.path, contents: nil)
        self.handle = try FileHandle(forWritingTo: tempURL)
    }

    func consume(_ data: Data) throws {
        do {
            try handle.write(contentsOf: data)
        } catch {
            throw HTTPError(status: 500, message: "写入临时文件失败：\(error.localizedDescription)")
        }
        hasher.update(data)
    }

    func finish() throws -> RequestBody {
        if !finished {
            try? handle.close()
            finished = true
        }
        return .file(tempURL, sha256: hasher.finalize(), byteCount: hasher.byteCount)
    }

    func abort() {
        if !finished {
            try? handle.close()
            finished = true
        }
        try? FileManager.default.removeItem(at: tempURL)
    }
}
