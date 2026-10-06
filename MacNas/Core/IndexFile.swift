//
//  IndexFile.swift
//  MacNas
//
//  info/index.json 的读写：版本识别、备份回退、未知字段保留。
//  所有对索引文件的落盘都经过这里，保证“老版本不会抹掉新版本写入的内容”。
//

import Foundation

/// 从磁盘上读到的、当前软件不认识的字段（写回时原样带上）
struct PreservedIndexJSON {
    var topLevel: JSONObject = [:]
    var entries: [String: JSONObject] = [:]

    var isEmpty: Bool { topLevel.isEmpty && entries.isEmpty }
}

struct IndexFile {

    enum Source: String {
        case primary = "index.json"
        case backup = "index.json.bak"
        case missing = "none"
    }

    var index: VolumeIndex
    var preserved: PreservedIndexJSON
    var source: Source

    /// 磁盘上声明的格式版本（缺失时按 1 处理）
    var diskVersion: Int { index.formatVersion }

    // MARK: - 读取

    /// 依次尝试 index.json → index.json.bak；都不可用返回 nil（由调用方决定重建还是当作空卷）
    static func read(from volume: Volume) -> IndexFile? {
        if let file = decode(at: volume.indexURL, source: .primary) { return file }

        let primaryExists = FileManager.default.fileExists(atPath: volume.indexURL.path)
        if let file = decode(at: volume.indexBackupURL, source: .backup) {
            if primaryExists {
                LogCenter.shared.error("info/index.json 已损坏，已从备份 index.json.bak 恢复：\(volume.path)")
            } else {
                LogCenter.shared.warn("info/index.json 丢失，已从备份 index.json.bak 恢复：\(volume.path)")
            }
            return file
        }
        return nil
    }

    private static func decode(at url: URL, source: Source) -> IndexFile? {
        guard let data = try? Data(contentsOf: url),
              let object = JSONPreservation.object(from: data),
              let decoded = try? JSONDecoder.iso.decode(VolumeIndex.self, from: data) else { return nil }
        return IndexFile(index: decoded, preserved: preservation(from: object), source: source)
    }

    /// 挑出未知字段（顶层 + 每条记录），正常文件里为空
    private static func preservation(from object: JSONObject) -> PreservedIndexJSON {
        var preserved = PreservedIndexJSON()
        preserved.topLevel = JSONPreservation.unknownFields(in: object, known: SchemaFields.indexTopLevel)

        for key in ["entries", "trashed"] {
            guard let entries = object[key] as? [JSONObject] else { continue }
            for entry in entries {
                guard let id = entry["id"] as? String else { continue }
                let extra = JSONPreservation.unknownFields(in: entry, known: SchemaFields.indexEntry)
                if !extra.isEmpty { preserved.entries[id] = extra }
            }
        }
        return preserved
    }

    // MARK: - 写入

    static func encode(_ index: VolumeIndex, preserved: PreservedIndexJSON) throws -> Data {
        // 小索引保持缩进（方便人看/排查），大索引用紧凑写法（体积小、写得快）
        let encoder: JSONEncoder = index.entries.count > 2000 ? .iso : .pretty
        var object = JSONPreservation.object(from: try encoder.encode(index)) ?? [:]
        JSONPreservation.merge(preserved.topLevel, into: &object)
        JSONPreservation.mergeEntries(preserved.entries, into: &object)
        guard let data = JSONPreservation.data(from: object) else {
            throw StoreError.io("无法序列化 info/index.json")
        }
        return data
    }

    /// 原子写入；必要时先把“当前这份好文件”留一份备份。
    /// - Parameter forceBackup: 迁移等场景强制先备份
    ///
    /// 备份策略：常见的个人 NAS 索引都很小（远小于 4MB），因此每次都刷新备份，
    /// 保证 index.json.bak 永远是“上一次的完好内容”；只有索引很大时才退化为最多 5 分钟刷新一次，
    /// 避免每次上传都完整多写一遍大文件。
    @discardableResult
    static func write(_ data: Data, to volume: Volume, forceBackup: Bool = false) throws -> Bool {
        let fm = FileManager.default
        var wroteBackup = false

        let existing = try? Data(contentsOf: volume.indexURL)
        let backupAge: TimeInterval
        if let attributes = try? fm.attributesOfItem(atPath: volume.indexBackupURL.path),
           let modified = attributes[.modificationDate] as? Date {
            backupAge = Date().timeIntervalSince(modified)
        } else {
            backupAge = .greatestFiniteMagnitude
        }

        let alwaysRefreshBackup = (existing?.count ?? 0) < 4 * 1024 * 1024

        if let existing, !existing.isEmpty,
           forceBackup || alwaysRefreshBackup || backupAge > 300 {
            if (try? existing.write(to: volume.indexBackupURL, options: .atomic)) != nil {
                wroteBackup = true
            }
        }

        try data.write(to: volume.indexURL, options: .atomic)
        return wroteBackup
    }
}

// MARK: - 追加日志（格式版本 2）

/// 一条日志记录：只描述「这次改动」，而不是整份索引
struct IndexJournalRecord: Codable {
    /// 新增或修改的记录（整条写入，回放时按 id 覆盖）
    var put: [FileEntry] = []
    /// 删除的记录 id
    var remove: [String] = []
    /// 文件夹列表变化时写完整列表（文件夹本身很轻，直接快照最不容易出错）
    var folders: [String]?
    /// 回收站的新增/修改
    var putTrash: [FileEntry] = []
    /// 回收站里被移除的 id（还原或彻底删除）
    var removeTrash: [String] = []
    var at: Date = Date()

    var isEmpty: Bool { put.isEmpty && remove.isEmpty && putTrash.isEmpty && removeTrash.isEmpty && folders == nil }
}

extension IndexFile {

    /// 从磁盘读日志；损坏的行（例如断电导致的半行）会被跳过，不影响其它记录
    static func readJournal(from volume: Volume) -> (records: [IndexJournalRecord], bytes: Int64, damaged: Int) {
        guard let data = try? Data(contentsOf: volume.journalURL), !data.isEmpty else { return ([], 0, 0) }
        var records: [IndexJournalRecord] = []
        var damaged = 0
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard let record = try? JSONDecoder.iso.decode(IndexJournalRecord.self, from: Data(line)) else {
                damaged += 1
                continue
            }
            records.append(record)
        }
        return (records, Int64(data.count), damaged)
    }

    /// 把日志回放到索引上
    static func apply(_ records: [IndexJournalRecord], to index: inout VolumeIndex) {
        guard !records.isEmpty else { return }
        var entries = Dictionary(uniqueKeysWithValues: index.entries.map { ($0.id, $0) })
        var order = index.entries.map { $0.id }
        var trash = Dictionary(uniqueKeysWithValues: index.trashed.map { ($0.id, $0) })
        var trashOrder = index.trashed.map { $0.id }

        for record in records {
            for id in record.remove {
                entries[id] = nil
                order.removeAll { $0 == id }
            }
            for entry in record.put {
                if entries[entry.id] == nil { order.append(entry.id) }
                entries[entry.id] = entry
            }
            for id in record.removeTrash {
                trash[id] = nil
                trashOrder.removeAll { $0 == id }
            }
            for entry in record.putTrash {
                if trash[entry.id] == nil { trashOrder.append(entry.id) }
                trash[entry.id] = entry
            }
            if let folders = record.folders { index.folders = folders }
        }

        index.entries = order.compactMap { entries[$0] }
        index.trashed = trashOrder.compactMap { trash[$0] }
    }

    /// 追加一条记录（只写这一次改动的部分，所以是常数级开销）
    @discardableResult
    static func append(_ record: IndexJournalRecord, to volume: Volume) throws -> Int64 {
        guard !record.isEmpty else { return 0 }
        let encoder = JSONEncoder.iso
        guard var data = try? encoder.encode(record) else { return 0 }
        data.append(0x0A)
        let fm = FileManager.default
        if !fm.fileExists(atPath: volume.journalURL.path) {
            try? fm.createDirectory(at: volume.infoURL, withIntermediateDirectories: true)
            fm.createFile(atPath: volume.journalURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: volume.journalURL) else {
            throw StoreError.io("无法打开 info/index.log")
        }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        } catch {
            throw StoreError.io("写入 info/index.log 失败：\(error.localizedDescription)")
        }
        return Int64(data.count)
    }

    /// 删掉日志（压缩完成后调用）
    static func clearJournal(for volume: Volume) {
        try? FileManager.default.removeItem(at: volume.journalURL)
    }
}
