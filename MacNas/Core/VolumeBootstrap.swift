//
//  VolumeBootstrap.swift
//  MacNas
//
//  目录（NAS 根）的创建 / 打开 / 校验。
//

import Foundation

enum VolumeBootstrap {
    struct Inspection {
        var root: URL
        var hasDocument: Bool
        var hasInfo: Bool
        var entryCount: Int = 0
        var markerName: String?
        var isMacNasVolume: Bool { hasDocument && hasInfo }
    }

    /// 只读探测：判断一个文件夹是不是 MacNas 目录
    static func inspect(_ root: URL) -> Inspection {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        let documentURL = root.appendingPathComponent(StorageLayout.documentFolderName, isDirectory: true)
        let infoURL = root.appendingPathComponent(StorageLayout.infoFolderName, isDirectory: true)
        let hasDocument = fm.fileExists(atPath: documentURL.path, isDirectory: &isDir) && isDir.boolValue
        let hasInfo = fm.fileExists(atPath: infoURL.path, isDirectory: &isDir) && isDir.boolValue

        var inspection = Inspection(root: root, hasDocument: hasDocument, hasInfo: hasInfo)

        let markerURL = infoURL.appendingPathComponent(StorageLayout.markerFileName)
        if let data = try? Data(contentsOf: markerURL),
           let marker = try? JSONDecoder.iso.decode(VolumeMarker.self, from: data) {
            inspection.markerName = marker.name
        }
        let indexURL = infoURL.appendingPathComponent(StorageLayout.indexFileName)
        if let data = try? Data(contentsOf: indexURL),
           let index = try? JSONDecoder.iso.decode(VolumeIndex.self, from: data) {
            inspection.entryCount = index.entries.count
        }
        return inspection
    }

    /// 初始化一个新目录：创建 document / info，写入身份标记与空索引
    static func prepare(_ root: URL, name: String) throws -> Volume {
        let fm = FileManager.default
        var volume = Volume(name: name, path: root.path)

        if let existing = readMarker(root: root) {
            volume.id = existing.id
            volume.createdAt = existing.createdAt
            if !existing.name.isEmpty { volume.name = existing.name }
        }

        let documentURL = root.appendingPathComponent(StorageLayout.documentFolderName, isDirectory: true)
        let blobsURL = documentURL.appendingPathComponent(StorageLayout.blobsFolderName, isDirectory: true)
        let infoURL = root.appendingPathComponent(StorageLayout.infoFolderName, isDirectory: true)

        do {
            try fm.createDirectory(at: blobsURL, withIntermediateDirectories: true)
            try fm.createDirectory(at: infoURL, withIntermediateDirectories: true)
        } catch {
            throw StoreError.io("无法创建 document / info 子文件夹：\(error.localizedDescription)")
        }

        writeMarker(volume)
        if !fm.fileExists(atPath: volume.indexURL.path) {
            // 新目录直接用最新格式（v2 = 带追加日志），写入性能不会随文件数线性变差
            var index = VolumeIndex(volumeId: volume.id, volumeName: volume.name)
            index.formatVersion = DiskSchema.newVolumeVersion
            let data = try JSONEncoder.pretty.encode(index)
            try data.write(to: volume.indexURL, options: .atomic)
        }
        return volume
    }

    /// 打开一个已存在的 MacNas 目录，沿用磁盘上的身份与名称
    static func open(_ root: URL, fallbackName: String) throws -> Volume {
        let inspection = inspect(root)
        guard inspection.isMacNasVolume else {
            throw StoreError.invalidPath("“\(root.lastPathComponent)”下没有同时存在 document 与 info 文件夹，不是 MacNas 目录")
        }
        var volume = Volume(name: fallbackName.isEmpty ? root.lastPathComponent : fallbackName, path: root.path)
        if let existing = readMarker(root: root) {
            volume.id = existing.id
            volume.createdAt = existing.createdAt
            if !existing.name.isEmpty { volume.name = existing.name }
        }
        if let name = inspection.markerName, !name.isEmpty { volume.name = name }
        writeMarker(volume)
        return volume
    }

    /// 读回卷身份：优先 volume.json，其次退回 index.json 里记录的 volumeId
    private static func readMarker(root: URL) -> VolumeMarker? {
        let infoURL = root.appendingPathComponent(StorageLayout.infoFolderName, isDirectory: true)
        let markerURL = infoURL.appendingPathComponent(StorageLayout.markerFileName)
        if let data = try? Data(contentsOf: markerURL),
           let marker = try? JSONDecoder.iso.decode(VolumeMarker.self, from: data), !marker.id.isEmpty {
            return marker
        }
        let indexURL = infoURL.appendingPathComponent(StorageLayout.indexFileName)
        if let data = try? Data(contentsOf: indexURL),
           let index = try? JSONDecoder.iso.decode(VolumeIndex.self, from: data), !index.volumeId.isEmpty {
            return VolumeMarker(id: index.volumeId, name: index.volumeName, createdAt: index.updatedAt)
        }
        return nil
    }

    /// 写入目录身份标记：更新已知字段，保留当前版本不认识的字段（降级运行也不会丢失信息）
    /// 注意：绝不会把 formatVersion 往低了写 —— 只读打开新版本目录时也不许“降级”声明。
    /// 写卷标记。默认不动已有卷声明的格式版本（老卷不会因为写一次标记就被升级），
    /// 只有显式传 formatVersion 时才改写（供「启用快速写入」用）。
    static func writeMarker(_ volume: Volume, formatVersion: Int? = nil) {
        let marker = VolumeMarker(id: volume.id, name: volume.name, createdAt: volume.createdAt)
        guard let encoded = try? JSONEncoder.pretty.encode(marker),
              var object = JSONPreservation.object(from: encoded) else { return }

        if let data = try? Data(contentsOf: volume.markerURL),
           let existing = JSONPreservation.object(from: data) {
            let unknown = JSONPreservation.unknownFields(in: existing, known: SchemaFields.marker)
            JSONPreservation.merge(unknown, into: &object)
            let declared = (existing["formatVersion"] as? Int) ?? 1
            object["formatVersion"] = formatVersion ?? declared
        } else {
            object["formatVersion"] = formatVersion ?? DiskSchema.newVolumeVersion
        }

        guard let data = JSONPreservation.data(from: object) else { return }

        // 磁盘上声明了比当前软件更新的版本 → 一个字节都不动
        if let existing = try? Data(contentsOf: volume.markerURL) {
            if let object = JSONPreservation.object(from: existing),
               let declared = object["formatVersion"] as? Int,
               DiskSchema.needsNewerApp(declared) {
                return
            }
            // 内容完全一致就不要写，避免无意义地修改修改时间
            if existing == data { return }
        }

        try? FileManager.default.createDirectory(at: volume.infoURL, withIntermediateDirectories: true)
        try? data.write(to: volume.markerURL, options: .atomic)
    }
}

extension JSONDecoder {
    static var iso: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

extension JSONEncoder {
    /// 紧凑 JSON（不缩进）：大索引用它可以明显减少体积与写入时间
    static var iso: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    static var pretty: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }
}
