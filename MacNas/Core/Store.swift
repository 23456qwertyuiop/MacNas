//
//  Store.swift
//  MacNas
//
//  存储引擎：
//  - 每个目录的 info/index.json 是记录的唯一真相来源（重启后可完整还原）
//  - 文件按内容寻址存放在 document/blobs/<哈希前两位>/<哈希>.<扩展名>
//  - 哈希全局唯一：任意目录已有相同哈希，就不再重复落盘，只新增一条记录
//  - 删除按引用计数处理：最后一条记录消失时才真正删除物理文件
//
//  所有对外方法都是线程安全（内部串行队列）且同步的，
//  哈希计算在上传流的接收过程中完成，不占用本队列。
//

import Foundation

final class Store: @unchecked Sendable {

    struct BlobLocation {
        var volumeId: String
        var relPath: String
        var size: Int64
    }

    private let queue = DispatchQueue(label: "cn.zenlc.macnas.store")

    private var volumes: [Volume] = []
    private var indexes: [String: VolumeIndex] = [:]
    private var dirSets: [String: Set<String>] = [:]
    private var blobs: [String: BlobLocation] = [:]
    private var missingHashes: Set<String> = []

    /// 从磁盘上保留下来、当前版本不认识的字段（写回时原样带上）
    private var preservedIndex: [String: PreservedIndexJSON] = [:]
    /// 由更新版本的 MacNas 写入 → 只读，绝不改写
    private var readOnlyVolumes: Set<String> = []
    /// 使用追加日志的卷（格式版本 >= 2）：日常改动只追加，不整份重写
    private var journaledVolumes: Set<String> = []
    /// 上次落盘时每条记录的指纹，用来算出「这次到底改了什么」
    private var persistedEntryPrints: [String: [String: Int]] = [:]
    private var persistedTrashPrints: [String: [String: Int]] = [:]
    private var persistedFolders: [String: [String]] = [:]
    private var journalBytes: [String: Int64] = [:]
    /// 索引是从 document/blobs 重建的
    private var rebuiltVolumes: Set<String> = []

    private let fm = FileManager.default

    // MARK: - 目录装载

    /// 装载 / 重载目录列表；返回经过修正（沿用磁盘身份）后的目录列表
    @discardableResult
    func setVolumes(_ newVolumes: [Volume]) -> [Volume] {
        queue.sync {
            volumes = []
            indexes = [:]
            dirSets = [:]
            blobs = [:]
            missingHashes = []
            preservedIndex = [:]
            readOnlyVolumes = []
            rebuiltVolumes = []
            journaledVolumes = []
            persistedEntryPrints = [:]
            persistedTrashPrints = [:]
            persistedFolders = [:]
            journalBytes = [:]

            var resolved: [Volume] = []
            var seen: Set<String> = []
            // 需要在装载完成后才能落盘的写入（此时 volumes 才可用）
            var pendingWrites: [(volumeId: String, forceBackup: Bool, reason: String)] = []

            for var volume in newVolumes {
                guard volume.isPrepared else {
                    LogCenter.shared.warn("目录不可用（缺少 document / info 子文件夹）：\(volume.path)")
                    resolved.append(volume)
                    continue
                }

                let marker = _readMarker(volume)
                let file = IndexFile.read(from: volume)
                if let marker { volume.id = marker.id }
                if let file, !file.index.volumeId.isEmpty { volume.id = file.index.volumeId }
                if volume.name.isEmpty {
                    volume.name = marker?.name ?? file?.index.volumeName ?? volume.rootURL.lastPathComponent
                }
                if seen.contains(volume.id) {
                    LogCenter.shared.warn("同一个目录被重复添加，已忽略：\(volume.path)")
                    continue
                }
                seen.insert(volume.id)

                // 磁盘格式版本：取标记与索引里声明的较大者
                let diskVersion = max(marker?.formatVersion ?? 1, file?.diskVersion ?? 1)
                if DiskSchema.needsNewerApp(diskVersion) {
                    readOnlyVolumes.insert(volume.id)
                    LogCenter.shared.error("「\(volume.name)」的格式版本为 v\(diskVersion)，高于当前软件支持的 v\(DiskSchema.maximumReadableVersion)，将以只读方式打开（不会改写目录内容）")
                }

                var index: VolumeIndex
                var needsRepairWrite = false
                if let file {
                    index = file.index
                    preservedIndex[volume.id] = file.preserved
                    // 从备份恢复后把正式索引写回去
                    needsRepairWrite = (file.source == .backup)
                } else if _hasAnyBlob(volume) {
                    // 索引文件丢失/损坏且没有备份，但 document/blobs 里还有内容 → 按哈希重建
                    index = _rebuildIndexFromBlobsLocked(volume)
                    rebuiltVolumes.insert(volume.id)
                    needsRepairWrite = true
                } else {
                    index = VolumeIndex(volumeId: volume.id, volumeName: volume.name)
                }

                // 老版本 → 新版本：只补默认值，不改结构
                let migrated = SchemaMigration.migrate(index: &index, from: diskVersion)

                // 格式 v2 起用追加日志：把日志回放到索引上
                if DiskSchema.usesJournal(diskVersion) && !readOnlyVolumes.contains(volume.id) {
                    let journal = IndexFile.readJournal(from: volume)
                    if !journal.records.isEmpty {
                        IndexFile.apply(journal.records, to: &index)
                    }
                    if journal.damaged > 0 {
                        LogCenter.shared.warn("「\(volume.name)」的追加日志里有 \(journal.damaged) 行损坏（已跳过），下次写入时会压缩成完整索引")
                        needsRepairWrite = true
                    }
                    journaledVolumes.insert(volume.id)
                    journalBytes[volume.id] = journal.bytes
                }

                index.volumeId = volume.id
                index.volumeName = volume.name
                if !readOnlyVolumes.contains(volume.id) { index.formatVersion = diskVersion }
                indexes[volume.id] = index
                dirSets[volume.id] = _computeDirs(index)
                persistedEntryPrints[volume.id] = _prints(of: index.entries)
                persistedTrashPrints[volume.id] = _prints(of: index.trashed)
                persistedFolders[volume.id] = index.folders.sorted()

                // 修复（从备份恢复 / 按哈希重建）与版本升级都必须落盘，否则每次启动都要重来；
                // 但要等 volumes 装载完成后再写，因此先记下来。
                if needsRepairWrite {
                    pendingWrites.append((volume.id, false, "修复"))
                }
                if migrated, file != nil {
                    pendingWrites.append((volume.id, true, "升级"))
                }
                resolved.append(volume)
            }

            volumes = resolved
            _rebuildBlobMap()

            for write in pendingWrites where !readOnlyVolumes.contains(write.volumeId) {
                do {
                    try _saveIndexLocked(volumeId: write.volumeId,
                                         forceBackup: write.forceBackup,
                                         forceSnapshot: true)   // 修复 / 重建 / 升级都要整份落盘
                    if write.reason == "升级" {
                        LogCenter.shared.info("目录索引已升级到格式 v\(DiskSchema.currentVersion)（目录结构未变）")
                    } else {
                        LogCenter.shared.info("索引\(write.reason)结果已写回磁盘")
                    }
                } catch {
                    LogCenter.shared.warn("索引\(write.reason)写回失败：\(error.localizedDescription)")
                }
            }

            if !missingHashes.isEmpty {
                LogCenter.shared.warn("有 \(missingHashes.count) 个文件的实际内容缺失，请在“目录详情”里查看")
            }
            LogCenter.shared.info("已装载 \(volumes.count) 个目录，共 \(indexes.values.reduce(0) { $0 + $1.entries.count }) 条文件记录")
            return resolved
        }
    }

    func reload() -> [Volume] {
        let current = queue.sync { volumes }
        var refreshed = current
        for i in refreshed.indices {
            if let file = IndexFile.read(from: refreshed[i]), !file.index.volumeId.isEmpty {
                refreshed[i].id = file.index.volumeId
            }
        }
        return setVolumes(refreshed)
    }

    func volumeList() -> [Volume] { queue.sync { volumes } }

    func volume(id: String) -> Volume? { queue.sync { _volume(id) } }

    func setVolumeName(volumeId: String, name: String) {
        queue.sync {
            guard let index = indexes[volumeId], let position = volumes.firstIndex(where: { $0.id == volumeId }) else { return }
            volumes[position].name = name
            var updated = index
            updated.volumeName = name
            indexes[volumeId] = updated
            // 只读卷（由更新版本写入）不改写磁盘上的任何文件
            guard !readOnlyVolumes.contains(volumeId) else { return }
            VolumeBootstrap.writeMarker(volumes[position])
            try? _saveIndexLocked(volumeId: volumeId)
        }
    }

    func isAvailable(volumeId: String) -> Bool {
        queue.sync { _volume(volumeId)?.isPrepared ?? false }
    }

    /// 该卷是否因格式版本更新而只读
    func isReadOnly(volumeId: String) -> Bool { queue.sync { readOnlyVolumes.contains(volumeId) } }

    /// 写操作前的显式校验（路由层在动手之前调用，保证“整个请求被拒绝”而不是逐条失败）
    func ensureWritable(volumeId: String) throws {
        try queue.sync { try _requireWritable(volumeId) }
    }

    /// 该卷的索引是否由 document/blobs 重建而来
    func isRebuilt(volumeId: String) -> Bool { queue.sync { rebuiltVolumes.contains(volumeId) } }

    /// 按内容哈希重建索引（info 丢失后的救援手段），返回恢复的记录数
    @discardableResult
    func rebuildIndexFromBlobs(volumeId: String) throws -> Int {
        try queue.sync {
            try _requireWritable(volumeId)
            guard let volume = _volume(volumeId) else { throw StoreError.volumeNotFound }
            var index = _rebuildIndexFromBlobsLocked(volume)
            index.volumeId = volume.id
            index.volumeName = volume.name
            indexes[volumeId] = index
            rebuiltVolumes.insert(volumeId)
            _rebuildDirs(volumeId)
            try _saveIndexLocked(volumeId: volumeId)
            return index.entries.count
        }
    }

    // MARK: - 列目录

    func list(volumeId: String, path: String) throws -> DirectoryListing {
        try queue.sync {
            let directory = LogicalPath.normalize(path)
            guard let index = indexes[volumeId], let volume = _volume(volumeId), volume.isPrepared else {
                throw StoreError.volumeUnavailable(_volume(volumeId)?.path ?? volumeId)
            }
            let dirs = dirSets[volumeId] ?? [LogicalPath.root]
            let explicit = Set(index.folders.map { LogicalPath.normalize($0) })

            var folders: [FolderItem] = []
            for dir in dirs where dir != LogicalPath.root && LogicalPath.parent(dir) == directory {
                let name = LogicalPath.lastSegment(dir)
                guard !name.isEmpty else { continue }
                folders.append(FolderItem(name: name,
                                          path: dir,
                                          fileCount: _countFiles(index: index, under: dir),
                                          explicit: explicit.contains(dir)))
            }
            folders.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

            var files = index.entries.filter { $0.directory == directory }
            files.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }

            return DirectoryListing(path: directory, folders: folders, files: files)
        }
    }

    /// 该逻辑路径是否是一个存在的文件夹（分享链接状态检查用）
    func folderExists(volumeId: String, path: String) -> Bool {
        queue.sync {
            guard let volume = _volume(volumeId), volume.isPrepared else { return false }
            return dirSets[volumeId]?.contains(LogicalPath.normalize(path)) ?? false
        }
    }

    func entries(volumeId: String) -> [FileEntry] {
        queue.sync { indexes[volumeId]?.entries ?? [] }
    }

    func recentEntries(volumeId: String, limit: Int = 200) -> [FileEntry] {
        queue.sync {
            let all = indexes[volumeId]?.entries ?? []
            return Array(all.sorted { $0.createdAt > $1.createdAt }.prefix(limit))
        }
    }

    // MARK: - 写操作

    func createFolder(volumeId: String, path: String, name: String) throws -> String {
        try queue.sync {
            try _requireWritable(volumeId)
            guard var index = indexes[volumeId] else { throw StoreError.volumeNotFound }
            let parent = LogicalPath.normalize(path)
            guard parent == LogicalPath.root || (dirSets[volumeId]?.contains(parent) ?? false) else {
                throw StoreError.invalidPath(parent)
            }
            guard let clean = LogicalPath.sanitizedSegment(name) else { throw StoreError.invalidName(name) }
            let target = LogicalPath.join(parent, clean)
            if dirSets[volumeId]?.contains(target) ?? false { throw StoreError.conflict("已存在同名文件夹：\(clean)") }
            if index.entries.contains(where: { $0.logicalPath == target }) { throw StoreError.conflict("已存在同名文件：\(clean)") }

            index.folders.append(target)
            indexes[volumeId] = index
            _insertDirChain(volumeId: volumeId, path: target)
            try _saveIndexLocked(volumeId: volumeId)
            return target
        }
    }

    func renameEntry(volumeId: String, entryId: String, newName: String) throws {
        try queue.sync {
            try _requireWritable(volumeId)
            guard var index = indexes[volumeId] else { throw StoreError.volumeNotFound }
            guard let position = index.entries.firstIndex(where: { $0.id == entryId }) else {
                throw StoreError.notFound("文件记录不存在")
            }
            guard let clean = LogicalPath.sanitizedSegment(newName) else { throw StoreError.invalidName(newName) }
            let entry = index.entries[position]
            let target = LogicalPath.join(entry.directory, clean)
            if target == entry.logicalPath { return }
            if index.entries.contains(where: { $0.logicalPath == target }) { throw StoreError.conflict("已存在同名文件：\(clean)") }
            if dirSets[volumeId]?.contains(target) ?? false { throw StoreError.conflict("已存在同名文件夹：\(clean)") }

            index.entries[position].name = clean
            index.entries[position].logicalPath = target
            indexes[volumeId] = index
            try _saveIndexLocked(volumeId: volumeId)
        }
    }

    func renameFolder(volumeId: String, path: String, newName: String) throws -> String {
        try queue.sync {
            try _requireWritable(volumeId)
            guard var index = indexes[volumeId] else { throw StoreError.volumeNotFound }
            let source = LogicalPath.normalize(path)
            guard source != LogicalPath.root else { throw StoreError.invalidPath("根目录不能重命名") }
            guard dirSets[volumeId]?.contains(source) ?? false else { throw StoreError.notFound("文件夹不存在") }
            guard let clean = LogicalPath.sanitizedSegment(newName) else { throw StoreError.invalidName(newName) }
            let target = LogicalPath.join(LogicalPath.parent(source), clean)
            if target == source { return source }
            if dirSets[volumeId]?.contains(target) ?? false { throw StoreError.conflict("已存在同名文件夹：\(clean)") }
            if index.entries.contains(where: { $0.logicalPath == target }) { throw StoreError.conflict("已存在同名文件：\(clean)") }

            index.folders = index.folders.map { folder in
                let normalized = LogicalPath.normalize(folder)
                guard normalized == source || LogicalPath.isDescendant(normalized, of: source) else { return folder }
                return _replacingPrefix(normalized, old: source, new: target)
            }
            for i in index.entries.indices {
                let logical = index.entries[i].logicalPath
                guard LogicalPath.isDescendant(logical, of: source) else { continue }
                index.entries[i].logicalPath = _replacingPrefix(logical, old: source, new: target)
            }
            indexes[volumeId] = index
            _rebuildDirs(volumeId)
            try _saveIndexLocked(volumeId: volumeId)
            return target
        }
    }

    /// 删除文件记录：默认只是移入回收站（内容引用计数不变），
    /// 传 permanently = true 才是真正删除记录并回收内容。
    func deleteEntry(volumeId: String, entryId: String, permanently: Bool = false) throws {
        try queue.sync {
            try _requireWritable(volumeId)
            guard var index = indexes[volumeId] else { throw StoreError.volumeNotFound }
            guard let position = index.entries.firstIndex(where: { $0.id == entryId }) else {
                throw StoreError.notFound("文件记录不存在")
            }
            let hash = index.entries[position].sha256
            let name = index.entries[position].name

            if permanently {
                index.entries.remove(at: position)
            } else {
                var entry = index.entries.remove(at: position)
                entry.trashedAt = Date()
                entry.originalPath = entry.logicalPath
                index.trashed.insert(entry, at: 0)
            }
            indexes[volumeId] = index
            _rebuildDirs(volumeId)
            try _saveIndexLocked(volumeId: volumeId)
            if permanently {
                _pruneBlobsIfUnreferenced(hashes: [hash])
                LogCenter.shared.info("彻底删除记录：\(name)")
            } else {
                LogCenter.shared.info("已移入回收站：\(name)")
            }
        }
    }

    // MARK: - 回收站

    /// 回收站列表（按进站时间倒序）
    func trash(volumeId: String) -> [FileEntry] {
        queue.sync {
            (indexes[volumeId]?.trashed ?? []).sorted {
                ($0.trashedAt ?? .distantPast) > ($1.trashedAt ?? .distantPast)
            }
        }
    }

    func trashCount() -> Int {
        queue.sync { indexes.values.reduce(0) { $0 + $1.trashed.count } }
    }

    /// 从回收站还原。原路径被占用时自动加序号，不会覆盖任何东西。
    @discardableResult
    func restoreEntry(volumeId: String, entryId: String) throws -> String {
        try queue.sync {
            try _requireWritable(volumeId)
            guard var index = indexes[volumeId] else { throw StoreError.volumeNotFound }
            guard let position = index.trashed.firstIndex(where: { $0.id == entryId }) else {
                throw StoreError.notFound("回收站里没有这个文件")
            }
            var entry = index.trashed.remove(at: position)
            let wanted = entry.originalPath ?? entry.logicalPath
            var directory = LogicalPath.parent(wanted)
            var name = LogicalPath.lastSegment(wanted)

            // 原来的目录可能也一起被删了/改名了：逐级补回来
            if !(dirSets[volumeId]?.contains(directory) ?? false), directory != LogicalPath.root {
                let segments = LogicalPath.segments(directory)
                var current = LogicalPath.root
                for segment in segments {
                    current = LogicalPath.join(current, segment)
                    if current == directory { break }
                }
                _insertDirChain(volumeId: volumeId, path: directory)
            }

            // 重名时按「名字 (2).扩展名」的规则让位，和复制/移动的命名保持一致
            let ext = (name as NSString).pathExtension
            let base = ext.isEmpty ? name : (name as NSString).deletingPathExtension
            var finalPath = LogicalPath.join(directory, name)
            var counter = 2
            while index.entries.contains(where: { $0.logicalPath == finalPath })
                    || (dirSets[volumeId]?.contains(finalPath) ?? false) {
                let candidate = ext.isEmpty ? "\(base) (\(counter))" : "\(base) (\(counter)).\(ext)"
                name = candidate
                finalPath = LogicalPath.join(directory, candidate)
                counter += 1
            }

            entry.name = name
            entry.logicalPath = finalPath
            entry.trashedAt = nil
            entry.originalPath = nil
            index.entries.append(entry)
            index.volumeName = _volume(volumeId)?.name ?? index.volumeName
            indexes[volumeId] = index
            _rebuildDirs(volumeId)
            try _saveIndexLocked(volumeId: volumeId)
            LogCenter.shared.info("从回收站还原：\(name) → \(finalPath)")
            return finalPath
        }
    }

    /// 彻底删除回收站里的一条记录（内容在没人引用时才会被回收）
    func purgeEntry(volumeId: String, entryId: String) throws {
        try queue.sync {
            try _requireWritable(volumeId)
            guard var index = indexes[volumeId] else { throw StoreError.volumeNotFound }
            guard let position = index.trashed.firstIndex(where: { $0.id == entryId }) else {
                throw StoreError.notFound("回收站里没有这个文件")
            }
            let entry = index.trashed.remove(at: position)
            indexes[volumeId] = index
            try _saveIndexLocked(volumeId: volumeId)
            var hashes = Set([entry.sha256])
            hashes.formUnion(entry.history.map { $0.sha256 })
            _pruneBlobsIfUnreferenced(hashes: hashes)
            LogCenter.shared.info("彻底删除：\(entry.name)")
        }
    }

    /// 清空回收站；olderThanDays > 0 时只清更早的（自动过期清理用）
    @discardableResult
    func emptyTrash(volumeId: String, olderThanDays: Int? = nil) throws -> Int {
        try queue.sync {
            try _requireWritable(volumeId)
            guard var index = indexes[volumeId] else { throw StoreError.volumeNotFound }
            let cutoff: Date? = olderThanDays.map { Date().addingTimeInterval(-Double($0) * 86400) }
            var removed: [FileEntry] = []
            if let cutoff {
                removed = index.trashed.filter { ($0.trashedAt ?? .distantPast) < cutoff }
                index.trashed.removeAll { ($0.trashedAt ?? .distantPast) < cutoff }
            } else {
                removed = index.trashed
                index.trashed.removeAll()
            }
            guard !removed.isEmpty else { return 0 }
            indexes[volumeId] = index
            try _saveIndexLocked(volumeId: volumeId)
            var hashes = Set(removed.map { $0.sha256 })
            for entry in removed { hashes.formUnion(entry.history.map { $0.sha256 }) }
            _pruneBlobsIfUnreferenced(hashes: hashes)
            LogCenter.shared.info("清空回收站：\(volumeId)，共 \(removed.count) 项")
            return removed.count
        }
    }

    /// 所有卷的回收站里超过保留期的项，统一清理（软件启动时调用一次）
    @discardableResult
    func pruneExpiredTrash(olderThanDays: Int) -> Int {
        guard olderThanDays > 0 else { return 0 }
        var total = 0
        let volumeIds = queue.sync { Array(indexes.keys) }
        for volumeId in volumeIds {
            total += (try? emptyTrash(volumeId: volumeId, olderThanDays: olderThanDays)) ?? 0
        }
        if total > 0 { LogCenter.shared.info("回收站自动清理：共 \(total) 项（保留 \(olderThanDays) 天）") }
        return total
    }

    // MARK: - 历史版本

    /// 某个文件的版本列表：当前版本在最前，其后是历史版本
    func versions(volumeId: String, entryId: String) -> [(version: FileVersion, isCurrent: Bool, name: String)] {
        queue.sync {
            guard let index = indexes[volumeId] else { return [] }
            let all = index.entries + index.trashed
            guard let entry = all.first(where: { $0.id == entryId }) else { return [] }
            var result: [(FileVersion, Bool, String)] = []
            result.append((FileVersion(sha256: entry.sha256,
                                       size: entry.size,
                                       createdAt: entry.createdAt,
                                       replacedAt: entry.createdAt,
                                       name: entry.name), true, entry.name))
            for version in entry.history {
                result.append((version, false, version.name ?? entry.name))
            }
            return result
        }
    }

    /// 恢复到某个历史版本：当前内容会变成一条新的历史版本，所以这一步可以再反悔
    func restoreVersion(volumeId: String, entryId: String, sha256: String) throws {
        try queue.sync {
            try _requireWritable(volumeId)
            guard var index = indexes[volumeId] else { throw StoreError.volumeNotFound }
            guard let position = index.entries.firstIndex(where: { $0.id == entryId }) else {
                throw StoreError.notFound("文件记录不存在")
            }
            let current = index.entries[position]
            guard current.sha256 != sha256 else { return }
            guard let location = blobs[sha256] else {
                throw StoreError.notFound("该版本的内容已经不在库里了")
            }
            guard let versionPosition = current.history.firstIndex(where: { $0.sha256 == sha256 }) else {
                throw StoreError.notFound("这个版本不在历史记录里")
            }
            let target = current.history[versionPosition]

            var history = current.history
            history.remove(at: versionPosition)
            history.insert(FileVersion(sha256: current.sha256,
                                       size: current.size,
                                       createdAt: current.createdAt,
                                       replacedAt: Date(),
                                       name: current.name), at: 0)
            if history.count > Self.maxVersionsPerFile {
                history = Array(history.prefix(Self.maxVersionsPerFile))
            }

            var restored = current
            restored.sha256 = target.sha256
            restored.size = target.size
            restored.storageVolumeId = location.volumeId
            restored.storageRelPath = location.relPath
            restored.history = history
            index.entries[position] = restored
            indexes[volumeId] = index
            try _saveIndexLocked(volumeId: volumeId)
            LogCenter.shared.info("已恢复到历史版本：\(restored.name) ← \(target.sha256.prefix(12))…")
        }
    }

    /// 某个目录下的全部记录（含子目录，不含回收站）—— 打包下载、镜像导出用
    func descendantEntries(volumeId: String, path: String) -> [FileEntry] {
        queue.sync {
            guard let index = indexes[volumeId] else { return [] }
            let root = LogicalPath.normalize(path)
            guard root != LogicalPath.root else { return index.entries }
            return index.entries.filter { LogicalPath.isDescendant($0.logicalPath, of: root) }
        }
    }

    /// 某个目录（含子目录）下的图片/视频记录，按时间倒序 —— 供「照片」时间线使用
    func mediaEntries(volumeId: String, path: String, kind: String) -> [FileEntry] {
        queue.sync {
            guard let index = indexes[volumeId] else { return [] }
            let root = LogicalPath.normalize(path)
            let imageExtensions: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "bmp", "tiff", "tif", "avif"]
            let videoExtensions: Set<String> = ["mp4", "m4v", "mov", "mkv", "webm", "avi", "3gp", "mpg", "mpeg"]
            return index.entries
                .filter { entry in
                    guard root == LogicalPath.root || LogicalPath.isDescendant(entry.logicalPath, of: root) else { return false }
                    let ext = (entry.name as NSString).pathExtension.lowercased()
                    switch kind {
                    case "image": return imageExtensions.contains(ext)
                    case "video": return videoExtensions.contains(ext)
                    default: return imageExtensions.contains(ext) || videoExtensions.contains(ext)
                    }
                }
                .sorted { $0.createdAt > $1.createdAt }
        }
    }

    /// 某个哈希对应的物理文件位置（下载历史版本时要按哈希取内容）
    func blobURL(sha256: String) -> URL? {
        queue.sync {
            guard let location = blobs[sha256] else { return nil }
            return _blobURL(volumeId: location.volumeId, relPath: location.relPath)
        }
    }

    /// 删除文件夹（含子文件夹与其中所有记录）
    @discardableResult
    func deleteFolder(volumeId: String, path: String, permanently: Bool = false) throws -> Int {
        try queue.sync {
            try _requireWritable(volumeId)
            guard var index = indexes[volumeId] else { throw StoreError.volumeNotFound }
            let target = LogicalPath.normalize(path)
            guard target != LogicalPath.root else { throw StoreError.invalidPath("根目录不能删除") }
            guard dirSets[volumeId]?.contains(target) ?? false else { throw StoreError.notFound("文件夹不存在") }

            let removed = index.entries.filter { LogicalPath.isDescendant($0.logicalPath, of: target) }
            let hashes = Set(removed.map { $0.sha256 })
            index.entries.removeAll { LogicalPath.isDescendant($0.logicalPath, of: target) }
            index.folders.removeAll { folder in
                let normalized = LogicalPath.normalize(folder)
                return normalized == target || LogicalPath.isDescendant(normalized, of: target)
            }
            if permanently {
                indexes[volumeId] = index
            } else {
                // 文件夹是「隐式」的（只由记录的路径推导），所以整棵子树进回收站 = 把这些记录标记一下
                let now = Date()
                let trashed = removed.map { entry -> FileEntry in
                    var copy = entry
                    copy.trashedAt = now
                    copy.originalPath = entry.logicalPath
                    return copy
                }
                index.trashed.insert(contentsOf: trashed, at: 0)
                indexes[volumeId] = index
            }
            _rebuildDirs(volumeId)
            try _saveIndexLocked(volumeId: volumeId)
            if permanently {
                _pruneBlobsIfUnreferenced(hashes: hashes)
                LogCenter.shared.info("彻底删除文件夹：\(target)（含 \(removed.count) 个文件）")
            } else {
                LogCenter.shared.info("文件夹已移入回收站：\(target)（含 \(removed.count) 个文件）")
            }
            return removed.count
        }
    }

    /// 提交一次上传：命中哈希则只记录，否则落盘后记录
    func commitUpload(volumeId: String,
                      directory: String,
                      fileName: String,
                      sha256: String,
                      size: Int64,
                      tempFileURL: URL,
                      overwrite: Bool) throws -> (entry: FileEntry, outcome: UploadOutcome) {
        try queue.sync {
            try _requireWritable(volumeId)
            guard let volume = _volume(volumeId) else { throw StoreError.volumeNotFound }
            guard var index = indexes[volumeId] else { throw StoreError.volumeNotFound }

            guard let clean = LogicalPath.sanitizedSegment(fileName) else {
                try? fm.removeItem(at: tempFileURL)
                throw StoreError.invalidName(fileName)
            }
            let dir = LogicalPath.normalize(directory)
            if dir != LogicalPath.root, !(dirSets[volumeId]?.contains(dir) ?? false) {
                try? fm.removeItem(at: tempFileURL)
                throw StoreError.invalidPath(dir)
            }

            let logical = LogicalPath.join(dir, clean)
            if dirSets[volumeId]?.contains(logical) ?? false {
                try? fm.removeItem(at: tempFileURL)
                throw StoreError.conflict("已存在同名文件夹：\(clean)")
            }

            var replacedHashes: Set<String> = []
            var reusedId: String?
            var carriedHistory: [FileVersion] = []
            var carriedCreatedAt: Date?
            if let position = index.entries.firstIndex(where: { $0.logicalPath == logical }) {
                if !overwrite {
                    try? fm.removeItem(at: tempFileURL)
                    throw StoreError.conflict("已存在同名文件：\(clean)")
                }
                // 覆盖时沿用原来的记录 id，保证网页端的引用始终有效
                let previous = index.entries[position]
                reusedId = previous.id
                carriedCreatedAt = previous.createdAt
                carriedHistory = previous.history
                replacedHashes.insert(previous.sha256)
                // 内容真的变了才记一版历史（同一份内容重复上传不算新版本）
                if previous.sha256 != sha256 {
                    carriedHistory.insert(FileVersion(sha256: previous.sha256,
                                                      size: previous.size,
                                                      createdAt: previous.createdAt,
                                                      replacedAt: Date(),
                                                      name: previous.name),
                                          at: 0)
                    if carriedHistory.count > Self.maxVersionsPerFile {
                        carriedHistory = Array(carriedHistory.prefix(Self.maxVersionsPerFile))
                    }
                }
                index.entries.remove(at: position)
            }

            let outcome: UploadOutcome
            let storageVolumeId: String
            let relPath: String
            var storedSize = size

            if let existing = blobs[sha256] {
                storageVolumeId = existing.volumeId
                relPath = existing.relPath
                storedSize = existing.size
                try? fm.removeItem(at: tempFileURL)
                outcome = .deduplicated
                LogCenter.shared.info("命中哈希，只写记录不占空间：\(clean) ← \(sha256.prefix(12))…")
            } else {
                let ext = LogicalPath.fileExtension(for: clean)
                relPath = _blobRelativePath(hash: sha256, ext: ext)
                storageVolumeId = volumeId
                let destination = volume.documentURL.appendingPathComponent(relPath)
                do {
                    try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if fm.fileExists(atPath: destination.path) {
                        try? fm.removeItem(at: tempFileURL)
                    } else {
                        try fm.moveItem(at: tempFileURL, to: destination)
                    }
                    let attributes = try? fm.attributesOfItem(atPath: destination.path)
                    storedSize = (attributes?[.size] as? NSNumber)?.int64Value ?? size
                } catch {
                    try? fm.removeItem(at: tempFileURL)
                    throw StoreError.io("写入文件失败：\(error.localizedDescription)")
                }
                blobs[sha256] = BlobLocation(volumeId: volumeId, relPath: relPath, size: storedSize)
                missingHashes.remove(sha256)
                outcome = .stored
                LogCenter.shared.info("新文件落盘：\(clean)（\(storedSize) 字节）")
            }

            let entry = FileEntry(id: reusedId ?? UUID().uuidString,
                                  name: clean,
                                  sha256: sha256,
                                  size: storedSize,
                                  logicalPath: logical,
                                  storageVolumeId: storageVolumeId,
                                  storageRelPath: relPath,
                                  createdAt: carriedCreatedAt ?? Date(),
                                  history: carriedHistory)
            index.entries.append(entry)
            index.volumeName = volume.name
            indexes[volumeId] = index
            _insertDirChain(volumeId: volumeId, path: dir)
            try _saveIndexLocked(volumeId: volumeId)

            replacedHashes.remove(sha256)
            _pruneBlobsIfUnreferenced(hashes: replacedHashes)
            return (entry, outcome)
        }
    }

    // MARK: - 跨目录移动 / 复制（网页端拖拽用）

    /// 每个文件最多保留多少个历史版本（再老的会被丢弃并回收内容）
    static let maxVersionsPerFile = 20

    struct TransferSummary {
        var moved: Int = 0
        var copied: Int = 0
        var renamed: Int = 0
        /// 新建记录（复制）或搬过来的记录（移动）的 id 与新路径，便于调用方继续处理
        var createdIds: [String] = []
        var createdPaths: [String] = []
    }

    /// 把一批记录（文件 + 文件夹）移动到 / 复制到目标目录。
    /// 因为内容是全局按哈希去重的，这里**只改记录不搬数据**：
    /// 跨卷“移动”也是瞬间完成，内容仍留在原来的 document/blobs 里。
    func transfer(fromVolumeId: String,
                  entryIds: [String],
                  folderPaths: [String],
                  toVolumeId: String,
                  toPath: String,
                  copy: Bool) throws -> TransferSummary {
        try queue.sync {
            guard let fromVolume = _volume(fromVolumeId) else { throw StoreError.volumeNotFound }
            guard let toVolume = _volume(toVolumeId) else { throw StoreError.volumeNotFound }
            guard fromVolume.isPrepared else { throw StoreError.volumeUnavailable(fromVolume.path) }
            try _requireWritable(toVolumeId)
            if !copy { try _requireWritable(fromVolumeId) }

            let sameVolume = fromVolumeId == toVolumeId
            guard var source = indexes[fromVolumeId] else { throw StoreError.volumeNotFound }
            var target = sameVolume ? source : (indexes[toVolumeId] ?? VolumeIndex(volumeId: toVolumeId, volumeName: toVolume.name))

            let destination = LogicalPath.normalize(toPath)
            if destination != LogicalPath.root, !(dirSets[toVolumeId]?.contains(destination) ?? false) {
                throw StoreError.invalidPath(destination)
            }

            var reservedEntries = Set(target.entries.map { $0.logicalPath })
            var reservedDirs = dirSets[toVolumeId] ?? [LogicalPath.root]

            /// 在目标目录里取一个不冲突的名字，冲突时自动加 (2)、(3)…
            func uniquePath(in directory: String, name: String) -> (path: String, renamed: Bool) {
                var candidate = LogicalPath.join(directory, name)
                if !reservedEntries.contains(candidate), !reservedDirs.contains(candidate) {
                    reservedEntries.insert(candidate)
                    return (candidate, false)
                }
                let ext = (name as NSString).pathExtension
                let base = ext.isEmpty ? name : (name as NSString).deletingPathExtension
                var counter = 2
                while true {
                    let next = ext.isEmpty ? "\(base) (\(counter))" : "\(base) (\(counter)).\(ext)"
                    candidate = LogicalPath.join(directory, next)
                    if !reservedEntries.contains(candidate), !reservedDirs.contains(candidate) {
                        reservedEntries.insert(candidate)
                        return (candidate, true)
                    }
                    counter += 1
                }
            }

            var newEntries: [FileEntry] = []
            var removedIds = Set<String>()
            var removedFolders = Set<String>()
            var newFolders: [String] = []
            var summary = TransferSummary()

            // 1) 直接拖的文件
            for id in entryIds {
                guard let entry = source.entries.first(where: { $0.id == id }) else { continue }
                let (newPath, renamed) = uniquePath(in: destination, name: entry.name)
                if !copy, sameVolume, newPath == entry.logicalPath { continue }
                let newId = copy ? UUID().uuidString : entry.id
                removedIds.insert(entry.id)
                summary.createdPaths.append(newPath)
                summary.createdIds.append(newId)
                newEntries.append(FileEntry(id: newId,
                                            name: LogicalPath.lastSegment(newPath),
                                            sha256: entry.sha256,
                                            size: entry.size,
                                            logicalPath: newPath,
                                            storageVolumeId: entry.storageVolumeId,
                                            storageRelPath: entry.storageRelPath,
                                            createdAt: entry.createdAt,
                                            source: copy ? "copy" : entry.source))
                if copy { summary.copied += 1 } else { summary.moved += 1 }
                if renamed { summary.renamed += 1 }
            }

            // 2) 拖的文件夹（连同子目录一起）
            for rawPath in folderPaths {
                let folder = LogicalPath.normalize(rawPath)
                guard folder != LogicalPath.root else { throw StoreError.invalidPath("根目录不能被拖动") }
                if destination == folder || LogicalPath.isDescendant(destination, of: folder) {
                    throw StoreError.conflict("不能把文件夹移动到它自己里面")
                }
                let folderName = LogicalPath.lastSegment(folder)
                let (newFolder, renamedFolder) = uniquePath(in: destination, name: folderName)
                reservedDirs.insert(newFolder)
                if renamedFolder { summary.renamed += 1 }

                // 文件夹自身（可能是个空文件夹）也要在目标里登记
                summary.createdPaths.append(newFolder)
                newFolders.append(newFolder)
                if !copy { removedFolders.insert(folder) }

                // 显式子文件夹跟着改名
                for explicit in source.folders {
                    let normalized = LogicalPath.normalize(explicit)
                    guard LogicalPath.isDescendant(normalized, of: folder) else { continue }
                    let suffix = String(normalized.dropFirst(folder.count))
                    let mapped = newFolder + suffix
                    newFolders.append(mapped)
                    reservedDirs.insert(mapped)
                    if !copy { removedFolders.insert(normalized) }
                }

                for entry in source.entries where LogicalPath.isDescendant(entry.logicalPath, of: folder) {
                    let suffix = String(entry.logicalPath.dropFirst(folder.count))
                    let newPath = newFolder + suffix
                    reservedEntries.insert(newPath)
                    let newId = copy ? UUID().uuidString : entry.id
                    removedIds.insert(entry.id)
                    summary.createdIds.append(newId)
                    newEntries.append(FileEntry(id: newId,
                                                name: entry.name,
                                                sha256: entry.sha256,
                                                size: entry.size,
                                                logicalPath: newPath,
                                                storageVolumeId: entry.storageVolumeId,
                                                storageRelPath: entry.storageRelPath,
                                                createdAt: entry.createdAt,
                                                source: copy ? "copy" : entry.source))
                    if copy { summary.copied += 1 } else { summary.moved += 1 }
                }
            }

            guard !newEntries.isEmpty || !newFolders.isEmpty else { return summary }

            if !copy {
                source.entries.removeAll { removedIds.contains($0.id) }
                source.folders.removeAll { removedFolders.contains(LogicalPath.normalize($0)) }
            }

            if sameVolume {
                var merged = source
                merged.entries.append(contentsOf: newEntries)
                merged.folders.append(contentsOf: newFolders)
                merged.volumeName = toVolume.name
                indexes[fromVolumeId] = merged
                _rebuildDirs(fromVolumeId)
                try _saveIndexLocked(volumeId: fromVolumeId)
            } else {
                target.entries.append(contentsOf: newEntries)
                target.folders.append(contentsOf: newFolders)
                target.volumeName = toVolume.name
                source.volumeName = fromVolume.name
                indexes[fromVolumeId] = source
                indexes[toVolumeId] = target
                _rebuildDirs(fromVolumeId)
                _rebuildDirs(toVolumeId)
                if !copy { try _saveIndexLocked(volumeId: fromVolumeId) }
                try _saveIndexLocked(volumeId: toVolumeId)
            }

            let action = copy ? "复制" : "移动"
            LogCenter.shared.info("\(action)：\(summary.moved + summary.copied) 条记录 → 「\(toVolume.name)」\(destination)")
            return summary
        }
    }

    // MARK: - 下载

    func entry(volumeId: String, entryId: String) -> FileEntry? {
        queue.sync { indexes[volumeId]?.entries.first(where: { $0.id == entryId }) }
    }

    /// 按逻辑路径取记录（WebDAV 需要）
    func entry(volumeId: String, logicalPath: String) -> FileEntry? {
        queue.sync {
            let target = LogicalPath.normalize(logicalPath)
            return indexes[volumeId]?.entries.first(where: { $0.logicalPath == target })
        }
    }

    func resolveEntry(volumeId: String, entryId: String) throws -> (entry: FileEntry, url: URL) {
        try queue.sync {
            guard let index = indexes[volumeId] else { throw StoreError.volumeNotFound }
            guard let entry = index.entries.first(where: { $0.id == entryId }) else {
                throw StoreError.notFound("文件记录不存在")
            }
            if let url = _blobURL(volumeId: entry.storageVolumeId, relPath: entry.storageRelPath),
               fm.fileExists(atPath: url.path) {
                return (entry, url)
            }
            if let found = _findBlobAnywhere(hash: entry.sha256),
               let url = _blobURL(volumeId: found.volumeId, relPath: found.relPath) {
                return (entry, url)
            }
            throw StoreError.notFound("该文件的实际内容缺失，请重新上传")
        }
    }

    // MARK: - 全局搜索

    struct SearchHit {
        var kind: String            // "file" | "folder"
        var volumeId: String
        var volumeName: String
        var name: String
        var logicalPath: String
        var size: Int64
        var fileCount: Int
        var entryId: String?
        var createdAt: Date?
        var score: Int
    }

    /// 在所有目录（或指定目录）里按名字/路径搜索。
    /// 多个关键词用空格分隔，必须全部命中；结果按相关度排序。
    func search(query: String, volumeId: String? = nil, limit: Int = 200) -> (hits: [SearchHit], total: Int) {
        queue.sync {
            let tokens = query
                .split(separator: " ", omittingEmptySubsequences: true)
                .map { Self.foldForSearch(String($0)) }
                .filter { !$0.isEmpty }
            guard !tokens.isEmpty else { return ([], 0) }

            var hits: [SearchHit] = []
            let scope = volumeId.map { [$0] } ?? volumes.map { $0.id }

            for id in scope {
                guard let volume = _volume(id), volume.isPrepared, let index = indexes[id] else { continue }

                // 每个文件夹下的文件数（含子目录），一次算好，避免逐条重复统计
                var subtreeCounts: [String: Int] = [:]
                for entry in index.entries {
                    var dir = entry.directory
                    while true {
                        subtreeCounts[dir, default: 0] += 1
                        if dir == LogicalPath.root { break }
                        dir = LogicalPath.parent(dir)
                    }
                }

                for entry in index.entries {
                    let name = Self.foldForSearch(entry.name)
                    let path = Self.foldForSearch(entry.logicalPath)
                    guard tokens.allSatisfy({ name.contains($0) || path.contains($0) }) else { continue }
                    hits.append(SearchHit(kind: "file",
                                          volumeId: id,
                                          volumeName: volume.name,
                                          name: entry.name,
                                          logicalPath: entry.logicalPath,
                                          size: entry.size,
                                          fileCount: 0,
                                          entryId: entry.id,
                                          createdAt: entry.createdAt,
                                          score: Self.searchScore(tokens: tokens, name: name, path: path)))
                }

                for dir in (dirSets[id] ?? []) where dir != LogicalPath.root {
                    let folderName = LogicalPath.lastSegment(dir)
                    let name = Self.foldForSearch(folderName)
                    let path = Self.foldForSearch(dir)
                    guard tokens.allSatisfy({ name.contains($0) || path.contains($0) }) else { continue }
                    hits.append(SearchHit(kind: "folder",
                                          volumeId: id,
                                          volumeName: volume.name,
                                          name: folderName,
                                          logicalPath: dir,
                                          size: 0,
                                          fileCount: subtreeCounts[dir] ?? 0,
                                          entryId: nil,
                                          createdAt: nil,
                                          score: Self.searchScore(tokens: tokens, name: name, path: path) - 8))
                }
            }

            hits.sort { lhs, rhs in
                if lhs.score != rhs.score { return lhs.score > rhs.score }
                if lhs.kind != rhs.kind { return lhs.kind == "folder" }
                return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
            }
            return (Array(hits.prefix(max(1, limit))), hits.count)
        }
    }

    private static func foldForSearch(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                     locale: Locale(identifier: "zh_Hans_CN")).lowercased()
    }

    private static func searchScore(tokens: [String], name: String, path: String) -> Int {
        var score = 0
        for token in tokens {
            if name == token { score += 120 }
            else if name.hasPrefix(token) { score += 80 }
            else if name.contains(token) { score += 50 }
            else if path.contains(token) { score += 20 }
        }
        // 名字越短越可能是用户想要的那一个
        score -= min(24, name.count / 3)
        return score
    }

    // MARK: - 统计与维护

    // MARK: - 启用追加日志（把老卷升级到格式 v2）

    /// 把一个已有目录升级到格式 v2（启用追加日志）。
    /// 目录结构完全不变，只是多一个 info/index.log；
    /// 代价是「旧版 MacNas」此后只能只读打开这个目录，所以要由用户明确选择。
    func enableJournal(volumeId: String) throws {
        try queue.sync {
            try _requireWritable(volumeId)
            guard let volume = _volume(volumeId), var index = indexes[volumeId] else {
                throw StoreError.volumeNotFound
            }
            index.formatVersion = DiskSchema.journaledVersion
            indexes[volumeId] = index
            try _writeSnapshotLocked(volumeId: volumeId, forceBackup: true)
            VolumeBootstrap.writeMarker(volume, formatVersion: DiskSchema.journaledVersion)
            journaledVolumes.insert(volumeId)
            journalBytes[volumeId] = 0
            LogCenter.shared.info("「\(volume.name)」已启用追加日志（格式 v\(DiskSchema.journaledVersion)），写入不再随文件数变慢")
        }
    }

    /// 这个卷是否在用追加日志
    func usesJournal(volumeId: String) -> Bool {
        queue.sync { journaledVolumes.contains(volumeId) }
    }

    /// 整理索引：把追加日志压缩回一份完整的 index.json 并清掉日志。
    /// 返回压缩后的记录数与文件大小。
    @discardableResult
    func compactIndex(volumeId: String) throws -> (entries: Int, bytes: Int64) {
        try queue.sync {
            try _requireWritable(volumeId)
            try _writeSnapshotLocked(volumeId: volumeId)
            let indexURL = _volume(volumeId)?.indexURL
            let attributes = indexURL.flatMap { try? fm.attributesOfItem(atPath: $0.path) }
            let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
            let count = indexes[volumeId]?.entries.count ?? 0
            LogCenter.shared.info("已整理索引：\(_volume(volumeId)?.name ?? volumeId)（\(count) 条记录，\(size / 1024) KB）")
            return (count, size)
        }
    }

    // MARK: - 镜像导出

    /// 把逻辑目录树导出成一个「真实文件系统」视图。
    ///
    /// 用途：macOS 自带的「文件共享」（SMB/AFP）与 Time Machine 都只认真实文件，
    /// 而 MacNas 的逻辑目录只存在于索引里。这里把目录树铺开成真实文件，
    /// 同一文件系统里默认用**硬链接**指向 blobs —— 所以导出几乎不占额外空间，也很快。
    ///
    /// 注意：镜像只是「给别的软件看的视图」，不是真相来源。改名/删除请在 MacNas 里做，
    /// 然后重新导出一遍（已是最新的文件会被跳过）。
    @discardableResult
    func mirror(volumeId: String,
                target: URL,
                preferHardlink: Bool = true,
                includeEmptyFolders: Bool = true) throws -> MirrorReport {
        let started = Date()
        var report = MirrorReport()
        report.target = target.path
        report.mode = preferHardlink ? "hardlink" : "copy"

        let fm = FileManager.default
        let maybeVolume = queue.sync { _volume(volumeId) }
        guard let volume = maybeVolume else { throw StoreError.volumeNotFound }

        // 安全检查：不能导出到卷内部，否则会把 document/info 也一起铺开成递归结构
        let targetPath = target.standardizedFileURL.path
        let volumePath = URL(fileURLWithPath: volume.path).standardizedFileURL.path
        guard targetPath != volumePath else {
            throw StoreError.invalidPath("不能导出到目录本身")
        }
        guard !targetPath.hasPrefix(volumePath + "/") else {
            throw StoreError.invalidPath("不能导出到一个 MacNas 目录里面")
        }
        do {
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
        } catch {
            throw StoreError.io("无法创建导出目录：\(error.localizedDescription)")
        }
        guard fm.isWritableFile(atPath: target.path) else {
            throw StoreError.io("导出目录不可写：\(target.path)")
        }

        // 取出快照，避免长时间持锁
        let snapshot = queue.sync { () -> (entries: [FileEntry], folders: [String], blobs: [String: URL]) in
            let index = indexes[volumeId]
            var blobURLs: [String: URL] = [:]
            for entry in index?.entries ?? [] {
                // 注意：这里已经在队列上，只能用队列内的私有访问，
                // 调用公共的 blobURL(sha256:) 会再次 queue.sync，造成同队列重入而崩溃
                guard blobURLs[entry.sha256] == nil,
                      let location = blobs[entry.sha256],
                      let url = _blobURL(volumeId: location.volumeId, relPath: location.relPath) else { continue }
                blobURLs[entry.sha256] = url
            }
            return (index?.entries ?? [], index?.folders ?? [], blobURLs)
        }

        var createdDirectories = Set<String>()

        func ensureDirectory(_ relative: String) {
            guard !relative.isEmpty, relative != LogicalPath.root else { return }
            let url = target.appendingPathComponent(relative)
            let key = url.path
            guard !createdDirectories.contains(key) else { return }
            if !fm.fileExists(atPath: key) {
                do {
                    try fm.createDirectory(at: url, withIntermediateDirectories: true)
                    report.directories += 1
                } catch {
                    report.failures.append("\(relative)：\(error.localizedDescription)")
                    return
                }
            }
            createdDirectories.insert(key)
        }

        for entry in snapshot.entries {
            let relative = entry.logicalPath.hasPrefix("/") ? String(entry.logicalPath.dropFirst()) : entry.logicalPath
            guard !relative.isEmpty else { continue }
            let directory = (relative as NSString).deletingLastPathComponent
            ensureDirectory(directory)

            guard let blobURL = snapshot.blobs[entry.sha256] else {
                report.failures.append("\(entry.logicalPath)：内容不在库里")
                continue
            }
            let destination = target.appendingPathComponent(relative)
            report.bytes += entry.size

            // 已经是指向同一份内容的硬链接 → 跳过（增量导出就是这样做到很快的）
            if let existing = Self.inode(of: destination), let source = Self.inode(of: blobURL), existing == source {
                report.skipped += 1
                continue
            }
            if fm.fileExists(atPath: destination.path) {
                try? fm.removeItem(at: destination)
            }
            do {
                if preferHardlink {
                    try fm.linkItem(at: blobURL, to: destination)
                    report.linked += 1
                } else {
                    try fm.copyItem(at: blobURL, to: destination)
                    report.copied += 1
                }
            } catch {
                // 跨文件系统时硬链接会失败，退回复制
                do {
                    try fm.copyItem(at: blobURL, to: destination)
                    report.copied += 1
                } catch {
                    report.failures.append("\(relative)：\(error.localizedDescription)")
                }
            }
        }

        if includeEmptyFolders {
            for folder in snapshot.folders {
                let relative = folder.hasPrefix("/") ? String(folder.dropFirst()) : folder
                ensureDirectory(relative)
            }
        }

        // 写一份清单，说明这是 MacNas 的镜像视图（方便自己判断新鲜度）
        let manifest: [String: Any] = [
            "app": "MacNas",
            "kind": "mirror",
            "volumeId": volumeId,
            "volumeName": volume.name,
            "generatedAt": Self.isoFormatter.string(from: Date()),
            "mode": report.mode,
            "fileCount": report.fileCount,
            "directories": report.directories,
            "bytes": report.bytes
        ]
        if let data = try? JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: target.appendingPathComponent(".macnas-mirror.json"))
        }

        report.duration = Date().timeIntervalSince(started)
        LogCenter.shared.info("镜像导出：\(volume.name) → \(target.path)（\(report.summary)）")
        return report
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    /// 取文件的 inode + 设备号，用来判断两个路径是不是同一份数据
    private static func inode(of url: URL) -> String? {
        var info = stat()
        guard stat(url.path, &info) == 0 else { return nil }
        return "\(info.st_dev):\(info.st_ino)"
    }

    /// 空间分析：去重收益、类型分布、重复内容、大文件、回收站占用
    func analytics(volumeId: String?) -> Analytics {
        queue.sync {
            var result = Analytics()
            var categoryByKey: [String: Int] = [:]          // key -> categories 下标
            var counts: [String: Int] = [:]
            var namesByHash: [String: [String]] = [:]
            var seenPhysical = Set<String>()
            var historyHashes = Set<String>()
            var liveHashes = Set<String>()
            var biggest: [AnalyticsBigFile] = []

            let volumeIds = volumeId.map { [$0] } ?? Array(indexes.keys)
            for id in volumeIds {
                guard let index = indexes[id] else { continue }
                for entry in index.entries {
                    let ext = (entry.name as NSString).pathExtension.lowercased()
                    let key = ext.isEmpty ? "" : ext
                    let position: Int
                    if let found = categoryByKey[key] {
                        position = found
                    } else {
                        categoryByKey[key] = result.categories.count
                        result.categories.append(AnalyticsCategory(key: key))
                        position = result.categories.count - 1
                    }
                    result.fileCount += 1
                    result.logicalBytes += entry.size
                    result.categories[position].fileCount += 1
                    result.categories[position].logicalBytes += entry.size
                    counts[entry.sha256, default: 0] += 1
                    liveHashes.insert(entry.sha256)
                    if namesByHash[entry.sha256, default: []].count < 6 {
                        namesByHash[entry.sha256, default: []].append(entry.logicalPath)
                    }
                    if blobs[entry.sha256] == nil { result.missingBlobs += 1 }
                    biggest.append(AnalyticsBigFile(name: entry.name, path: entry.logicalPath,
                                                    volumeId: id, size: entry.size, entryId: entry.id))

                    // 物理占用按「第一次遇到这个内容」的类型归类；同一内容只算一次
                    if seenPhysical.insert(entry.sha256).inserted {
                        result.uniqueBlobCount += 1
                        result.physicalBytes += entry.size
                        result.categories[position].physicalBytes += entry.size
                    }
                    // 历史版本引用的内容
                    for version in entry.history {
                        historyHashes.insert(version.sha256)
                        result.historyCount += 1
                        if seenPhysical.insert(version.sha256).inserted {
                            result.physicalBytes += version.size
                            result.historyBytes += version.size
                            result.uniqueBlobCount += 1
                        }
                    }
                }
                // 回收站：内容仍占空间，单独统计
                for entry in index.trashed {
                    result.trashItems.append(AnalyticsTrashItem(name: entry.name,
                                                                originalPath: entry.originalPath ?? entry.logicalPath,
                                                                size: entry.size, volumeId: id))
                    for version in entry.history {
                        historyHashes.insert(version.sha256)
                        if seenPhysical.insert(version.sha256).inserted {
                            result.historyCount += 1
                        }
                    }
                }
            }

            // 重复内容（同一哈希被多条记录引用）
            for (hash, count) in counts where count > 1 {
                guard let location = blobs[hash] else { continue }
                result.duplicates.append(AnalyticsDuplicate(sha256: hash,
                                                            size: location.size,
                                                            refCount: count,
                                                            names: namesByHash[hash] ?? []))
            }
            result.duplicates.sort { $0.wastedBytes > $1.wastedBytes }
            if result.duplicates.count > 50 { result.duplicates = Array(result.duplicates.prefix(50)) }

            // 大小分档
            let bounds: [(String, Int64)] = [
                ("<100KB", 100 * 1024),
                ("100KB–1MB", 1024 * 1024),
                ("1–10MB", 10 * 1024 * 1024),
                ("10–100MB", 100 * 1024 * 1024),
                ("100MB–1GB", 1024 * 1024 * 1024),
                (">1GB", Int64.max)
            ]
            var buckets = bounds.map { AnalyticsSizeBucket(label: $0.0, upperBound: $0.1) }
            for file in biggest {
                let position = bounds.firstIndex(where: { file.size <= $0.1 }) ?? (bounds.count - 1)
                buckets[position].fileCount += 1
                buckets[position].bytes += file.size
                if file.size > buckets[position].largestSize {
                    buckets[position].largestSize = file.size
                    buckets[position].largestName = file.name
                    buckets[position].largestId = file.entryId
                    buckets[position].largestVolumeId = file.volumeId
                }
            }
            result.sizeBuckets = buckets

            result.categories.sort { $0.logicalBytes > $1.logicalBytes }
            biggest.sort { $0.size > $1.size }
            result.largest = Array(biggest.prefix(20))
            return result
        }
    }

    func stats() -> StoreStats {
        queue.sync {
            var result = StoreStats()
            var countedHashes = Set<String>()
            var countedPhysical = Set<String>()
            var physicalByVolume: [String: Int64] = [:]
            var volumeFileCount: [String: Int] = [:]
            var volumeLogical: [String: Int64] = [:]
            var volumeMissing: [String: Int] = [:]

            for (volumeId, index) in indexes {
                volumeFileCount[volumeId] = index.entries.count
                for entry in index.entries {
                    result.fileCount += 1
                    result.logicalBytes += entry.size
                    volumeLogical[volumeId, default: 0] += entry.size

                    let isMissing = blobs[entry.sha256] == nil
                    if isMissing {
                        volumeMissing[volumeId, default: 0] += 1
                        continue
                    }
                    if countedHashes.insert(entry.sha256).inserted {
                        result.uniqueBlobCount += 1
                        result.physicalBytes += entry.size
                    }
                    let owner = blobs[entry.sha256]?.volumeId ?? entry.storageVolumeId
                    if countedPhysical.insert(owner + "|" + entry.sha256).inserted {
                        physicalByVolume[owner, default: 0] += entry.size
                    }
                }
            }

            result.volumeCount = volumes.count
            result.volumeStats = volumes.map { volume in
                VolumeStats(volumeId: volume.id,
                            name: volume.name,
                            path: volume.path,
                            fileCount: volumeFileCount[volume.id] ?? 0,
                            physicalBytes: physicalByVolume[volume.id] ?? 0,
                            logicalBytes: volumeLogical[volume.id] ?? 0,
                            available: volume.isPrepared,
                            missingBlobs: volumeMissing[volume.id] ?? 0,
                            readOnly: readOnlyVolumes.contains(volume.id),
                            rebuilt: rebuiltVolumes.contains(volume.id))
            }
            result.missingBlobs = missingHashes.count
            return result
        }
    }

    /// 清理 document/blobs 下没有被任何记录引用的文件
    func pruneOrphans(volumeId: String) throws -> (files: Int, bytes: Int64) {
        try queue.sync {
            try _requireWritable(volumeId)
            guard let volume = _volume(volumeId) else { throw StoreError.volumeNotFound }

            var referenced = Set<String>()
            for index in indexes.values {
                for entry in index.entries where entry.storageVolumeId == volumeId {
                    referenced.insert(entry.storageRelPath)
                }
            }

            let documentPrefix = volume.documentURL.path + "/"
            var orphanURLs: [URL] = []
            var bytes: Int64 = 0
            if let enumerator = fm.enumerator(at: volume.blobsURL,
                                              includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                                              options: [.skipsHiddenFiles]) {
                for case let fileURL as URL in enumerator {
                    guard fileURL.path.hasPrefix(documentPrefix) else { continue }
                    let relative = String(fileURL.path.dropFirst(documentPrefix.count))
                    guard relative.hasPrefix(StorageLayout.blobsFolderName + "/") else { continue }
                    if !referenced.contains(relative) {
                        let size = (try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                        bytes += Int64(size)
                        orphanURLs.append(fileURL)
                    }
                }
            }
            for url in orphanURLs { try? fm.removeItem(at: url) }
            _removeEmptyDirectories(at: volume.blobsURL)
            LogCenter.shared.info("清理孤立文件：\(volume.name)，共 \(orphanURLs.count) 个 / \(bytes) 字节")
            return (orphanURLs.count, bytes)
        }
    }

    // MARK: - 去重信息

    /// 一次性取出“每个哈希被引用几次”和“每个哈希的物理位置”，供列目录时标注去重情况
    func dedupFacts() -> (counts: [String: Int], owners: [String: BlobLocation]) {
        queue.sync {
            var counts: [String: Int] = [:]
            for index in indexes.values {
                for entry in index.entries {
                    counts[entry.sha256, default: 0] += 1
                    for version in entry.history where !version.sha256.isEmpty {
                        counts[version.sha256, default: 0] += 1
                    }
                }
                for entry in index.trashed {
                    counts[entry.sha256, default: 0] += 1
                    for version in entry.history where !version.sha256.isEmpty {
                        counts[version.sha256, default: 0] += 1
                    }
                }
            }
            return (counts, blobs)
        }
    }

    func volumeName(id: String) -> String {
        queue.sync { _volume(id)?.name ?? "" }
    }

    // MARK: - 内部（调用方必须已在 queue 上）

    private func _readMarker(_ volume: Volume) -> VolumeMarker? {
        guard let data = try? Data(contentsOf: volume.markerURL) else { return nil }
        return try? JSONDecoder.iso.decode(VolumeMarker.self, from: data)
    }

    /// 写操作前的统一闸门：卷必须存在、可用、且不是“更新版本写入的只读卷”
    private func _requireWritable(_ volumeId: String) throws {
        guard let volume = _volume(volumeId) else { throw StoreError.volumeNotFound }
        guard volume.isPrepared else { throw StoreError.volumeUnavailable(volume.path) }
        if readOnlyVolumes.contains(volumeId) { throw StoreError.readOnly(volume.name) }
    }

    /// - Parameter forceSnapshot: 强制整份写出（修复/重建/升级等结构性写入必须用它，
    ///   否则只追加日志，损坏的 index.json 就永远不会被修好）
    private func _saveIndexLocked(volumeId: String, forceBackup: Bool = false, forceSnapshot: Bool = false) throws {
        guard indexes[volumeId] != nil, let volume = _volume(volumeId) else { throw StoreError.volumeNotFound }
        try _requireWritable(volumeId)
        // 就地改这两个字段。不要写成 `var index = indexes[volumeId]` —— 那会复制
        // 整个 entries 数组（几万条时每次写入都要白白搬几百 KB 到几 MB 内存）
        indexes[volumeId]?.updatedAt = Date()
        indexes[volumeId]?.volumeId = volume.id

        // 格式 v2 的卷：日常改动只追加一条日志（常数级开销），
        // 日志攒到一定大小再压缩回一份完整索引。这是支撑几十万文件的关键。
        if journaledVolumes.contains(volumeId), !forceBackup, !forceSnapshot {
            if let record = _journalRecordLocked(volumeId: volumeId), !record.isEmpty {
                do {
                    try fm.createDirectory(at: volume.infoURL, withIntermediateDirectories: true)
                    let written = try IndexFile.append(record, to: volume)
                    journalBytes[volumeId, default: 0] += written
                    if journalBytes[volumeId, default: 0] > StorageLayout.journalCompactThreshold {
                        try _writeSnapshotLocked(volumeId: volumeId, forceBackup: true)
                    }
                    return
                } catch {
                    // 追加失败就退回整份写入，保证数据不丢
                    LogCenter.shared.warn("追加日志失败，改为整份写入：\(error.localizedDescription)")
                }
            } else {
                return   // 这次没有任何变化
            }
        }

        try _writeSnapshotLocked(volumeId: volumeId, forceBackup: forceBackup)
    }

    /// 整份写出索引（会顺带把日志清掉，等于一次压缩）
    private func _writeSnapshotLocked(volumeId: String, forceBackup: Bool = false) throws {
        guard let volume = _volume(volumeId) else { throw StoreError.volumeNotFound }
        try _requireWritable(volumeId)
        indexes[volumeId]?.updatedAt = Date()
        indexes[volumeId]?.volumeId = volume.id
        guard let index = indexes[volumeId] else { throw StoreError.volumeNotFound }
        do {
            try fm.createDirectory(at: volume.infoURL, withIntermediateDirectories: true)
            let data = try IndexFile.encode(index, preserved: preservedIndex[volumeId] ?? PreservedIndexJSON())
            // 如果这次压缩前日志里有内容，说明旧的 index.json 已经过期了。
            // 这种情况下要顺手把备份也刷新成本次快照，否则「index.json 损坏 → 回退到 .bak」
            // 会退回到一份更旧、甚至空的索引。
            let journalWasPending = (journalBytes[volumeId] ?? 0) > 0
            try IndexFile.write(data, to: volume, forceBackup: forceBackup || journalWasPending)
            if journalWasPending {
                try? data.write(to: volume.indexBackupURL, options: .atomic)
            }
            IndexFile.clearJournal(for: volume)
            journalBytes[volumeId] = 0
            persistedEntryPrints[volumeId] = _prints(of: index.entries)
            persistedTrashPrints[volumeId] = _prints(of: index.trashed)
            persistedFolders[volumeId] = index.folders.sorted()
        } catch let error as StoreError {
            throw error
        } catch {
            throw StoreError.io("写入 info/index.json 失败：\(error.localizedDescription)")
        }
    }

    /// 对比「上次落盘的指纹」，算出这一次到底改了什么
    private func _journalRecordLocked(volumeId: String) -> IndexJournalRecord? {
        guard let index = indexes[volumeId] else { return nil }
        var record = IndexJournalRecord()

        let currentEntryPrints = _prints(of: index.entries)
        let previousEntryPrints = persistedEntryPrints[volumeId] ?? [:]
        for entry in index.entries {
            let print = currentEntryPrints[entry.id]
            if previousEntryPrints[entry.id] != print { record.put.append(entry) }
        }
        for id in previousEntryPrints.keys where currentEntryPrints[id] == nil {
            record.remove.append(id)
        }

        let currentTrashPrints = _prints(of: index.trashed)
        let previousTrashPrints = persistedTrashPrints[volumeId] ?? [:]
        for entry in index.trashed {
            let print = currentTrashPrints[entry.id]
            if previousTrashPrints[entry.id] != print { record.putTrash.append(entry) }
        }
        for id in previousTrashPrints.keys where currentTrashPrints[id] == nil {
            record.removeTrash.append(id)
        }

        let folders = index.folders.sorted()
        if folders != (persistedFolders[volumeId] ?? []) { record.folders = folders }

        guard !record.isEmpty else { return nil }
        persistedEntryPrints[volumeId] = currentEntryPrints
        persistedTrashPrints[volumeId] = currentTrashPrints
        persistedFolders[volumeId] = folders
        return record
    }

    /// 用来判断一条记录有没有变化的指纹。
    /// 用 Hasher 算整数而不是拼字符串：几万条记录时这一步从「成千上万次字符串分配」
    /// 变成纯整数运算，是写入不随文件数变慢的关键之一。
    /// （Hasher 的种子每个进程不同，所以这只在内存里用，绝不落盘。）
    private func _prints(of entries: [FileEntry]) -> [String: Int] {
        var result: [String: Int] = [:]
        result.reserveCapacity(entries.count)
        for entry in entries {
            var hasher = Hasher()
            hasher.combine(entry.name)
            hasher.combine(entry.logicalPath)
            hasher.combine(entry.sha256)
            hasher.combine(entry.size)
            hasher.combine(entry.storageVolumeId)
            hasher.combine(entry.storageRelPath)
            hasher.combine(entry.history.count)
            if let head = entry.history.first {
                hasher.combine(head.sha256)
                hasher.combine(head.size)
            }
            hasher.combine(entry.trashedAt)
            hasher.combine(entry.originalPath)
            result[entry.id] = hasher.finalize()
        }
        return result
    }

    // MARK: - 内容重建（info 丢失时的救援）

    private func _hasAnyBlob(_ volume: Volume) -> Bool {
        guard let shards = try? fm.contentsOfDirectory(atPath: volume.blobsURL.path) else { return false }
        for shard in shards {
            let shardURL = volume.blobsURL.appendingPathComponent(shard, isDirectory: true)
            if let files = try? fm.contentsOfDirectory(atPath: shardURL.path), !files.isEmpty { return true }
        }
        return false
    }

    /// 依据 document/blobs 里“文件名即哈希”的约定重建索引。
    /// 逻辑名称已经无从得知，因此重建出来的记录以 recovered-<哈希前 8 位>.<扩展名> 命名放在根目录，
    /// 内容与哈希完全一致，可以直接下载。
    private func _rebuildIndexFromBlobsLocked(_ volume: Volume) -> VolumeIndex {
        var index = VolumeIndex(volumeId: volume.id, volumeName: volume.name)
        guard let shards = try? fm.contentsOfDirectory(atPath: volume.blobsURL.path) else {
            LogCenter.shared.warn("「\(volume.name)」索引缺失，且 document/blobs 为空，按空目录处理")
            return index
        }

        var usedNames = Set<String>()
        var recovered = 0
        for shard in shards.sorted() {
            let shardURL = volume.blobsURL.appendingPathComponent(shard, isDirectory: true)
            guard let files = try? fm.contentsOfDirectory(atPath: shardURL.path) else { continue }
            for file in files.sorted() {
                guard !file.hasPrefix(".") else { continue }
                let name = file as NSString
                let ext = name.pathExtension.lowercased()
                let hash = ext.isEmpty ? file : name.deletingPathExtension
                guard hash.count == 64, hash.allSatisfy({ $0.isHexDigit }) else { continue }

                let blobURL = shardURL.appendingPathComponent(file)
                let attributes = try? fm.attributesOfItem(atPath: blobURL.path)
                let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
                let createdAt = (attributes?[.modificationDate] as? Date) ?? Date()

                var displayName = ext.isEmpty ? "recovered-\(hash.prefix(8))" : "recovered-\(hash.prefix(8)).\(ext)"
                var suffix = 1
                while usedNames.contains(displayName) {
                    suffix += 1
                    displayName = ext.isEmpty ? "recovered-\(hash.prefix(8))-\(suffix)" : "recovered-\(hash.prefix(8))-\(suffix).\(ext)"
                }
                usedNames.insert(displayName)

                index.entries.append(FileEntry(name: displayName,
                                               sha256: hash,
                                               size: size,
                                               logicalPath: LogicalPath.join(LogicalPath.root, displayName),
                                               storageVolumeId: volume.id,
                                               storageRelPath: "\(StorageLayout.blobsFolderName)/\(shard)/\(file)",
                                               createdAt: createdAt,
                                               source: "recovery"))
                recovered += 1
            }
        }
        LogCenter.shared.warn("「\(volume.name)」的 info/index.json 不可用，已按哈希从 document/blobs 重建 \(recovered) 条记录（文件名无法还原，已用 recovered-<哈希前8位> 命名）")
        return index
    }

    private func _volume(_ id: String) -> Volume? { volumes.first(where: { $0.id == id }) }

    private func _blobRelativePath(hash: String, ext: String) -> String {
        let prefix = String(hash.prefix(2))
        let name = ext.isEmpty ? hash : "\(hash).\(ext)"
        return "\(StorageLayout.blobsFolderName)/\(prefix)/\(name)"
    }

    private func _blobURL(volumeId: String, relPath: String) -> URL? {
        guard let volume = _volume(volumeId) else { return nil }
        return volume.documentURL.appendingPathComponent(relPath)
    }

    private func _computeDirs(_ index: VolumeIndex) -> Set<String> {
        var dirs: Set<String> = [LogicalPath.root]
        for folder in index.folders { _insertChain(into: &dirs, path: LogicalPath.normalize(folder)) }
        for entry in index.entries { _insertChain(into: &dirs, path: entry.directory) }
        return dirs
    }

    private func _rebuildDirs(_ volumeId: String) {
        guard let index = indexes[volumeId] else { return }
        dirSets[volumeId] = _computeDirs(index)
    }

    private func _insertDirChain(volumeId: String, path: String) {
        var dirs = dirSets[volumeId] ?? [LogicalPath.root]
        _insertChain(into: &dirs, path: path)
        dirSets[volumeId] = dirs
    }

    private func _insertChain(into dirs: inout Set<String>, path: String) {
        var current = LogicalPath.normalize(path)
        dirs.insert(current)
        while current != LogicalPath.root {
            current = LogicalPath.parent(current)
            dirs.insert(current)
        }
    }

    private func _countFiles(index: VolumeIndex, under directory: String) -> Int {
        index.entries.reduce(into: 0) { partial, entry in
            if entry.directory == directory || LogicalPath.isDescendant(entry.logicalPath, of: directory) {
                partial += 1
            }
        }
    }

    private func _replacingPrefix(_ value: String, old: String, new: String) -> String {
        if value == old { return new }
        guard value.hasPrefix(old + "/") else { return value }
        return new + String(value.dropFirst(old.count))
    }

    private func _rebuildBlobMap() {
        blobs.removeAll()
        missingHashes.removeAll()

        for (_, index) in indexes {
            for entry in index.entries {
                if blobs[entry.sha256] != nil { continue }
                if let url = _blobURL(volumeId: entry.storageVolumeId, relPath: entry.storageRelPath),
                   fm.fileExists(atPath: url.path) {
                    blobs[entry.sha256] = BlobLocation(volumeId: entry.storageVolumeId,
                                                       relPath: entry.storageRelPath,
                                                       size: entry.size)
                } else {
                    missingHashes.insert(entry.sha256)
                }
            }
        }

        guard !missingHashes.isEmpty else { return }

        // 自愈：内容其实还在（换机器、手工挪动过），修正记录
        var healed = 0
        for (volumeId, var index) in indexes {
            var changed = false
            for i in index.entries.indices {
                let hash = index.entries[i].sha256
                guard missingHashes.contains(hash), blobs[hash] == nil else { continue }
                if let found = _findBlobAnywhere(hash: hash) {
                    index.entries[i].storageVolumeId = found.volumeId
                    index.entries[i].storageRelPath = found.relPath
                    blobs[hash] = found
                    missingHashes.remove(hash)
                    changed = true
                    healed += 1
                }
            }
            if changed {
                indexes[volumeId] = index
                try? _saveIndexLocked(volumeId: volumeId)
            }
        }
        if healed > 0 {
            LogCenter.shared.info("已自动修复 \(healed) 条记录的实际存放位置")
        }
    }

    private func _findBlobAnywhere(hash: String) -> BlobLocation? {
        let prefix = String(hash.prefix(2))
        for volume in volumes where volume.isPrepared {
            let shard = volume.blobsURL.appendingPathComponent(prefix, isDirectory: true)
            guard let names = try? fm.contentsOfDirectory(atPath: shard.path) else { continue }
            for name in names {
                let base = name.contains(".") ? String(name.prefix(while: { $0 != "." })) : name
                if base == hash {
                    let relPath = "\(StorageLayout.blobsFolderName)/\(prefix)/\(name)"
                    let blobURL = shard.appendingPathComponent(name)
                    let attributes = try? fm.attributesOfItem(atPath: blobURL.path)
                    let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
                    return BlobLocation(volumeId: volume.id, relPath: relPath, size: size)
                }
            }
        }
        return nil
    }

    private func _pruneBlobsIfUnreferenced(hashes: Set<String>) {
        guard !hashes.isEmpty else { return }
        // 引用来源有三处：正常记录、历史版本、回收站里的记录 —— 少算任何一处都会误删内容
        var counts: [String: Int] = [:]
        for index in indexes.values {
            for entry in index.entries {
                counts[entry.sha256, default: 0] += 1
                for version in entry.history where !version.sha256.isEmpty {
                    counts[version.sha256, default: 0] += 1
                }
            }
            for entry in index.trashed {
                counts[entry.sha256, default: 0] += 1
                for version in entry.history where !version.sha256.isEmpty {
                    counts[version.sha256, default: 0] += 1
                }
            }
        }
        for hash in hashes where (counts[hash] ?? 0) == 0 {
            guard let location = blobs[hash], let url = _blobURL(volumeId: location.volumeId, relPath: location.relPath) else {
                blobs[hash] = nil
                continue
            }
            try? fm.removeItem(at: url)
            blobs[hash] = nil
            missingHashes.remove(hash)
            _removeEmptyDirectories(at: url.deletingLastPathComponent())
        }
    }

    private func _removeEmptyDirectories(at root: URL) {
        guard let enumerator = fm.enumerator(at: root,
                                             includingPropertiesForKeys: [.isDirectoryKey],
                                             options: [.skipsHiddenFiles]) else { return }
        var directories: [URL] = []
        for case let url as URL in enumerator {
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                directories.append(url)
            }
        }
        for url in directories.sorted(by: { $0.path.count > $1.path.count }) {
            if let contents = try? fm.contentsOfDirectory(atPath: url.path), contents.isEmpty {
                try? fm.removeItem(at: url)
            }
        }
    }
}
