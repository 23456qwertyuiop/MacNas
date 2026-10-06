//
//  ZipWriter.swift
//  MacNas
//
//  极简 ZIP 打包器：不引入任何第三方库，用系统 Compression 框架做 deflate。
//
//  用途：多选文件/文件夹 → 打包下载。
//  写入到临时文件而不是内存，所以选几百个大文件也不会把内存吃满。
//
//  ZIP 结构：每个文件一条「本地头 + 数据」，最后写中央目录与结束记录。
//  压缩方法用 8（deflate）；内容已经是压缩格式（jpg/mp4/zip…）时直接存储（方法 0），
//  既省 CPU 又不会把文件撑大。
//

import Foundation
import Compression
final class ZipWriter {

    private let handle: FileHandle
    private let url: URL
    private var entries: [CentralEntry] = []
    private var offset: Int64 = 0
    private var finished = false

    private struct CentralEntry {
        var name: String
        var crc: UInt32
        var compressedSize: UInt32
        var uncompressedSize: UInt32
        var method: UInt16
        var localHeaderOffset: UInt32
    }

    /// 已经是压缩格式的扩展名：直接存储，不再压一次
    private static let storedExtensions: Set<String> = [
        "jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "avif", "mp4", "m4v", "mov",
        "mkv", "webm", "mp3", "m4a", "aac", "ogg", "opus", "flac", "zip", "gz", "bz2", "xz",
        "7z", "rar", "pdf", "docx", "xlsx", "pptx"
    ]

    init(destination: URL) throws {
        self.url = destination
        FileManager.default.createFile(atPath: destination.path, contents: nil)
        guard let handle = try? FileHandle(forWritingTo: destination) else {
            throw StoreError.io("无法创建打包临时文件")
        }
        self.handle = handle
    }

    var outputURL: URL { url }

    // MARK: - 写文件

    /// 把一个文件加进压缩包；archivePath 是包内的相对路径（用 / 分隔）
    func addFile(at fileURL: URL, archivePath: String) throws {
        let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        try addFile(data: data, archivePath: archivePath)
    }

    func addFile(data: Data, archivePath: String) throws {
        var name = archivePath
        if name.hasPrefix("/") { name = String(name.dropFirst()) }
        guard !name.isEmpty else { return }

        let ext = (name as NSString).pathExtension.lowercased()
        let shouldStore = Self.storedExtensions.contains(ext)
        let crc = CRC32.checksum(data)
        let payload: Data
        let method: UInt16
        if shouldStore || data.isEmpty {
            payload = data
            method = 0
        } else {
            let deflated = Self.deflate(data)
            // 压不小就直接存储
            if deflated.count < data.count {
                payload = deflated
                method = 8
            } else {
                payload = data
                method = 0
            }
        }

        let nameBytes = Array(name.utf8)
        guard nameBytes.count < 0xFFFF else { return }   // ZIP 传统格式的文件名上限
        let localOffset = UInt32(truncatingIfNeeded: offset)

        var header = Data()
        header.appendUInt32(0x04034b50)          // 本地文件头签名
        header.appendUInt16(20)                  // 需要的解压版本
        header.appendUInt16(0x0800)              // 通用标志：文件名是 UTF-8
        header.appendUInt16(method)
        header.appendUInt16(0)                   // 修改时间
        header.appendUInt16(0x21)                // 修改日期（固定值，保证打包结果可复现）
        header.appendUInt32(crc)
        header.appendUInt32(UInt32(truncatingIfNeeded: payload.count))
        header.appendUInt32(UInt32(truncatingIfNeeded: data.count))
        header.appendUInt16(UInt16(nameBytes.count))
        header.appendUInt16(0)                   // 扩展字段长度
        header.append(contentsOf: nameBytes)

        try write(header)
        try write(payload)

        entries.append(CentralEntry(name: name, crc: crc,
                                    compressedSize: UInt32(truncatingIfNeeded: payload.count),
                                    uncompressedSize: UInt32(truncatingIfNeeded: data.count),
                                    method: method, localHeaderOffset: localOffset))
    }

    /// 写一个空目录条目（这样解压出来空文件夹也在）
    func addDirectory(archivePath: String) throws {
        var name = archivePath
        if name.hasPrefix("/") { name = String(name.dropFirst()) }
        guard !name.isEmpty else { return }
        if !name.hasSuffix("/") { name += "/" }
        let nameBytes = Array(name.utf8)
        let localOffset = UInt32(truncatingIfNeeded: offset)

        var header = Data()
        header.appendUInt32(0x04034b50)
        header.appendUInt16(20)
        header.appendUInt16(0x0800)
        header.appendUInt16(0)
        header.appendUInt16(0)
        header.appendUInt16(0x21)
        header.appendUInt32(0)
        header.appendUInt32(0)
        header.appendUInt32(0)
        header.appendUInt16(UInt16(nameBytes.count))
        header.appendUInt16(0)
        header.append(contentsOf: nameBytes)
        try write(header)

        entries.append(CentralEntry(name: name, crc: 0, compressedSize: 0, uncompressedSize: 0,
                                    method: 0, localHeaderOffset: localOffset))
    }

    // MARK: - 收尾

    @discardableResult
    func finish() throws -> URL {
        guard !finished else { return url }
        finished = true

        let centralStart = UInt32(truncatingIfNeeded: offset)
        for entry in entries {
            let nameBytes = Array(entry.name.utf8)
            var record = Data()
            record.appendUInt32(0x02014b50)                 // 中央目录签名
            record.appendUInt16(20)                         // 创建版本
            record.appendUInt16(20)                         // 需要版本
            record.appendUInt16(0x0800)                     // UTF-8
            record.appendUInt16(entry.method)
            record.appendUInt16(0)
            record.appendUInt16(0x21)
            record.appendUInt32(entry.crc)
            record.appendUInt32(entry.compressedSize)
            record.appendUInt32(entry.uncompressedSize)
            record.appendUInt16(UInt16(nameBytes.count))
            record.appendUInt16(0)                          // 扩展字段
            record.appendUInt16(0)                          // 注释
            record.appendUInt16(0)                          // 磁盘号
            record.appendUInt16(0)                          // 内部属性
            record.appendUInt32(0)                          // 外部属性
            record.appendUInt32(entry.localHeaderOffset)
            record.append(contentsOf: nameBytes)
            try write(record)
        }
        let centralSize = UInt32(truncatingIfNeeded: offset) - centralStart

        var end = Data()
        end.appendUInt32(0x06054b50)                        // 结束记录签名
        end.appendUInt16(0)                                 // 本磁盘号
        end.appendUInt16(0)                                 // 中央目录起始磁盘
        end.appendUInt16(UInt16(min(entries.count, 0xFFFF)))
        end.appendUInt16(UInt16(min(entries.count, 0xFFFF)))
        end.appendUInt32(centralSize)
        end.appendUInt32(centralStart)
        end.appendUInt16(0)                                 // 注释长度
        try write(end)

        try? handle.close()
        return url
    }

    func discard() {
        try? handle.close()
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - 内部

    private func write(_ data: Data) throws {
        do {
            try handle.write(contentsOf: data)
            offset += Int64(data.count)
        } catch {
            throw StoreError.io("写入压缩包失败：\(error.localizedDescription)")
        }
    }

    /// 用系统 Compression 框架做 raw deflate（ZIP 的方法 8 就是 raw deflate）
    static func deflate(_ data: Data) -> Data {
        guard !data.isEmpty else { return Data() }
        let capacity = max(data.count + 64, 4096)
        var output = Data(count: capacity)
        let written = output.withUnsafeMutableBytes { destination -> Int in
            guard let destinationBase = destination.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return data.withUnsafeBytes { source -> Int in
                guard let sourceBase = source.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_encode_buffer(destinationBase, capacity,
                                                 sourceBase, data.count,
                                                 nil, COMPRESSION_ZLIB)
            }
        }
        guard written > 0 else { return Data() }
        return output.prefix(written)
    }
}

/// ZIP 需要的 CRC-32（IEEE 802.3）
enum CRC32 {
    private static let table: [UInt32] = {
        (0..<256).map { index -> UInt32 in
            var value = UInt32(index)
            for _ in 0..<8 {
                value = (value & 1) == 1 ? (0xEDB88320 ^ (value >> 1)) : (value >> 1)
            }
            return value
        }
    }()

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFFFFFF
        data.withUnsafeBytes { buffer in
            for byte in buffer.bindMemory(to: UInt8.self) {
                crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
            }
        }
        return crc ^ 0xFFFFFFFF
    }
}

private extension Data {
    mutating func appendUInt16(_ value: UInt16) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
    }

    mutating func appendUInt32(_ value: UInt32) {
        append(UInt8(value & 0xFF))
        append(UInt8((value >> 8) & 0xFF))
        append(UInt8((value >> 16) & 0xFF))
        append(UInt8((value >> 24) & 0xFF))
    }
}
