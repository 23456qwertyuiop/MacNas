//
//  Schema.swift
//  MacNas
//
//  磁盘格式版本、迁移与兼容工具。
//
//  === 磁盘格式稳定性契约（后续任何版本都必须遵守） ===
//
//  1. 目录结构冻结：一个卷永远只有两个子文件夹 —— document/ 与 info/。
//     新功能只能往这两个文件夹里“新增文件或子文件夹”，不得改名、移动、删除已有文件夹。
//  2. 字段只增不改：index.json / volume.json 里已有字段的名称、含义、取值永不改变；
//     新增字段必须可以缺省（老版本读不到时用默认值），不允许把字段改成别的含义。
//  3. 未知字段原样保留：老版本软件读到新版本写入的未知字段时，会连同写回磁盘，绝不丢弃。
//     这样“降级运行”也不会破坏新版本写入的数据。
//  4. 新版本目录只读打开：如果磁盘上的 formatVersion 比当前软件能读的版本更新，
//     该卷以只读方式装载（可浏览、可下载），一切写操作被拒绝并提示升级，绝不改写。
//  5. 内容可重建：document/blobs 里的文件名就是内容哈希，
//     即使 info/ 全部丢失，也能按哈希重建索引并正常下载。
//
//  因此：升级软件不会改变系统结构，也不会让已有数据失效。
//

import Foundation

typealias JSONObject = [String: Any]

enum DiskSchema {
    /// 当前软件写出的格式版本。
    /// v2 相对 v1 只多了一样东西：info/index.log（追加日志）。
    /// 日常改动只往日志里追加，不再每次重写整份 index.json —— 这是支撑几十万文件的关键。
    static let currentVersion = 2
    /// 引入追加日志的版本（>= 这个版本的卷才会用日志）
    static let journaledVersion = 2
    /// 能读懂的最低 / 最高格式版本
    static let minimumReadableVersion = 1
    static let maximumReadableVersion = currentVersion

    /// 新目录默认写出的版本（老卷保持原版本，不自动升级）
    static let newVolumeVersion = journaledVersion

    static func usesJournal(_ version: Int) -> Bool { version >= journaledVersion }

    static func isReadable(_ version: Int) -> Bool {
        version >= minimumReadableVersion && version <= maximumReadableVersion
    }

    static func needsNewerApp(_ version: Int) -> Bool {
        version > maximumReadableVersion
    }
}

// MARK: - 迁移

/// 版本升级只允许“补默认值 / 加字段”，不允许删除或改变已有字段含义。
/// 目前只有版本 1，所以这里是空实现；将来新增版本时在这里追加一段即可。
enum SchemaMigration {

    /// 返回是否真的做了改动（用于决定是否立刻写回磁盘前先备份）
    @discardableResult
    static func migrate(index: inout VolumeIndex, from version: Int) -> Bool {
        var changed = false

        // 版本 < 2 时在这里补默认值，例如：
        // if version < 2 { index.someNewField = VolumeIndex.defaultNewField; changed = true }

        // 注意：**不**在这里把老卷升到新版本。
        // 升级格式版本会让「旧版 MacNas」只能只读打开这个目录，
        // 所以必须由用户明确选择（设置里的「启用快速写入」），不能顺手改了。
        return changed
    }

    /// 卷标记同样不自动升级版本（理由见上面的 migrate(index:)）
    @discardableResult
    static func migrate(marker: inout VolumeMarker, from version: Int) -> Bool {
        false
    }
}

// MARK: - 未知字段保留

enum JSONPreservation {

    static func object(from data: Data) -> JSONObject? {
        (try? JSONSerialization.jsonObject(with: data)) as? JSONObject
    }

    static func data(from object: JSONObject) -> Data? {
        try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys])
    }

    /// 取出我们不认识的字段（只保留这一小部分，正常文件几乎为空）
    static func unknownFields(in object: JSONObject, known: Set<String>) -> JSONObject {
        var result: JSONObject = [:]
        for (key, value) in object where !known.contains(key) {
            result[key] = value
        }
        return result
    }

    /// 把保留的未知字段合并回去（已存在的字段不会被覆盖）
    static func merge(_ preserved: JSONObject, into object: inout JSONObject) {
        for (key, value) in preserved where object[key] == nil {
            object[key] = value
        }
    }

    /// 合并到数组元素（按 id 匹配）—— entries 与 trashed 都要处理
    static func mergeEntries(_ preserved: [String: JSONObject], into object: inout JSONObject) {
        guard !preserved.isEmpty else { return }
        for key in ["entries", "trashed"] {
            guard var list = object[key] as? [JSONObject] else { continue }
            for index in list.indices {
                guard let id = list[index]["id"] as? String, let extra = preserved[id] else { continue }
                merge(extra, into: &list[index])
            }
            object[key] = list
        }
    }
}

// MARK: - 已知字段清单（用于判断“未知字段”）

enum SchemaFields {
    static let indexTopLevel: Set<String> = [
        "version", "formatVersion", "volumeId", "volumeName", "updatedAt", "folders", "entries", "trashed"
    ]

    static let indexEntry: Set<String> = [
        "id", "name", "sha256", "size", "logicalPath", "storageVolumeId", "storageRelPath",
        "createdAt", "source", "history", "trashedAt", "originalPath"
    ]

    static let marker: Set<String> = [
        "app", "version", "formatVersion", "id", "name", "createdAt"
    ]

    static let shareFile: Set<String> = ["formatVersion", "shares"]

    /// 历史版本记录里允许出现的字段
    static let version: Set<String> = ["sha256", "size", "createdAt", "replacedAt", "name"]

    static let shareRecord: Set<String> = [
        "token", "volumeId", "kind", "entryId", "logicalPath", "name", "createdAt",
        "expiresAt", "passwordSalt", "passwordHash", "enabled", "visits", "downloads", "formatVersion",
        "allowUpload", "maxFileBytes", "maxTotalBytes", "uploadedBytes", "uploadedCount", "imagesOnly"
    ]

    static let config: Set<String> = [
        "version", "formatVersion", "initialized", "username", "passwordSalt", "passwordHash",
        "port", "volumes", "autoStartServer", "webdavEnabled", "webdavReadOnly", "trashRetentionDays"
    ]
}
