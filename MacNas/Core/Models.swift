//
//  Models.swift
//  MacNas
//
//  基础数据模型：目录(Volume)、文件记录(FileEntry)、索引(VolumeIndex)。
//
//  磁盘布局（每个“目录”根下）：
//  <root>/document/blobs/<哈希前2位>/<哈希>.<ext>   真正存放的文件（按内容寻址，全局唯一）
//  <root>/info/index.json                          该目录下所有逻辑文件的记录
//  <root>/info/volume.json                         该目录的身份标记（id / 名称）
//

import Foundation

// MARK: - 目录布局

enum StorageLayout {
    static let documentFolderName = "document"
    static let infoFolderName = "info"
    static let blobsFolderName = "blobs"
    static let indexFileName = "index.json"
    static let indexBackupFileName = "index.json.bak"
    static let markerFileName = "volume.json"
    /// 追加日志（格式版本 2 起使用）：日常改动只往这里追加，不再整份重写 index.json
    static let journalFileName = "index.log"
    /// 日志超过这个大小就压缩回一份新的 index.json
    static let journalCompactThreshold: Int64 = 4 * 1024 * 1024

    /// 这些名字一旦发布就不能再改（见 Schema.swift 的稳定性契约）
    static let frozenNames = [
        documentFolderName, infoFolderName, blobsFolderName,
        indexFileName, indexBackupFileName, markerFileName, journalFileName
    ]
}

// MARK: - 一个“目录”（NAS 根）

struct Volume: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var path: String
    var createdAt: Date

    init(id: String = UUID().uuidString, name: String, path: String, createdAt: Date = Date()) {
        self.id = id
        self.name = name
        self.path = path
        self.createdAt = createdAt
    }

    var rootURL: URL { URL(fileURLWithPath: path, isDirectory: true) }
    var documentURL: URL { rootURL.appendingPathComponent(StorageLayout.documentFolderName, isDirectory: true) }
    var infoURL: URL { rootURL.appendingPathComponent(StorageLayout.infoFolderName, isDirectory: true) }
    var blobsURL: URL { documentURL.appendingPathComponent(StorageLayout.blobsFolderName, isDirectory: true) }
    var indexURL: URL { infoURL.appendingPathComponent(StorageLayout.indexFileName) }
    var indexBackupURL: URL { infoURL.appendingPathComponent(StorageLayout.indexBackupFileName) }
    var journalURL: URL { infoURL.appendingPathComponent(StorageLayout.journalFileName) }
    var markerURL: URL { infoURL.appendingPathComponent(StorageLayout.markerFileName) }

    /// document 与 info 是否都存在
    var isPrepared: Bool {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        let hasDocument = fm.fileExists(atPath: documentURL.path, isDirectory: &isDir) && isDir.boolValue
        let hasInfo = fm.fileExists(atPath: infoURL.path, isDirectory: &isDir) && isDir.boolValue
        return hasDocument && hasInfo
    }
}

/// 卷本身也做宽容解码：老配置文件里没有的字段用默认值补上
extension Volume {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decode(String.self, forKey: .id)) ?? UUID().uuidString
        name = (try? container.decode(String.self, forKey: .name)) ?? ""
        path = (try? container.decode(String.self, forKey: .path)) ?? ""
        createdAt = (try? container.decode(Date.self, forKey: .createdAt)) ?? Date()
    }
}

// MARK: - 一条逻辑文件记录

/// `logicalPath` 是用户在网页里看到的“存放目录”，
/// `storageVolumeId` + `storageRelPath` 是文件真正躺在哪儿（“存储目录”）。
/// 当多个逻辑文件哈希相同时，物理文件只存一份，其余记录指向同一份。
/// 一个历史版本：只记录内容哈希与时间，内容本身早就按哈希存在库里了，
/// 所以“保留历史”几乎不占额外空间（这也正是内容寻址存储的红利）。
struct FileVersion: Codable, Hashable {
    var sha256: String
    var size: Int64
    /// 这份内容当初被上传的时间
    var createdAt: Date
    /// 被新内容替换掉的时间
    var replacedAt: Date
    /// 替换前的名字（改名后覆盖的情况）
    var name: String?

    init(sha256: String, size: Int64, createdAt: Date, replacedAt: Date = Date(), name: String? = nil) {
        self.sha256 = sha256
        self.size = size
        self.createdAt = createdAt
        self.replacedAt = replacedAt
        self.name = name
    }
}

extension FileVersion {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sha256 = (try? container.decode(String.self, forKey: .sha256)) ?? ""
        size = (try? container.decode(Int64.self, forKey: .size)) ?? 0
        createdAt = (try? container.decode(Date.self, forKey: .createdAt)) ?? Date()
        replacedAt = (try? container.decode(Date.self, forKey: .replacedAt)) ?? createdAt
        name = try? container.decode(String.self, forKey: .name)
    }
}

struct FileEntry: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var sha256: String
    var size: Int64
    var logicalPath: String
    var storageVolumeId: String
    var storageRelPath: String
    var createdAt: Date
    var source: String
    /// 历史版本（新的在前），覆盖上传时自动累积
    var history: [FileVersion]
    /// 放进回收站的时间（nil = 正常存在）
    var trashedAt: Date?
    /// 进回收站前所在的逻辑路径，用于还原
    var originalPath: String?

    init(id: String = UUID().uuidString,
         name: String,
         sha256: String,
         size: Int64,
         logicalPath: String,
         storageVolumeId: String,
         storageRelPath: String,
         createdAt: Date = Date(),
         source: String = "web",
         history: [FileVersion] = [],
         trashedAt: Date? = nil,
         originalPath: String? = nil) {
        self.id = id
        self.name = name
        self.sha256 = sha256
        self.size = size
        self.logicalPath = logicalPath
        self.storageVolumeId = storageVolumeId
        self.storageRelPath = storageRelPath
        self.createdAt = createdAt
        self.source = source
        self.history = history
        self.trashedAt = trashedAt
        self.originalPath = originalPath
    }

    /// 逻辑所在目录，例如 "/照片/2026"
    var directory: String { LogicalPath.parent(logicalPath) }

    var fileExtension: String { (name as NSString).pathExtension.lowercased() }
}

extension FileEntry {
    /// 宽容解码：字段缺失时用安全默认值，避免一条坏记录让整份索引读不出来
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedName = (try? container.decode(String.self, forKey: .name)) ?? ""
        let decodedId = (try? container.decode(String.self, forKey: .id)) ?? ""
        let decodedPath = (try? container.decode(String.self, forKey: .logicalPath)) ?? ""

        id = decodedId.isEmpty ? UUID().uuidString : decodedId
        name = decodedName
        sha256 = (try? container.decode(String.self, forKey: .sha256)) ?? ""
        size = (try? container.decode(Int64.self, forKey: .size)) ?? 0
        logicalPath = decodedPath.isEmpty ? LogicalPath.join(LogicalPath.root, decodedName) : decodedPath
        storageVolumeId = (try? container.decode(String.self, forKey: .storageVolumeId)) ?? ""
        storageRelPath = (try? container.decode(String.self, forKey: .storageRelPath)) ?? ""
        createdAt = (try? container.decode(Date.self, forKey: .createdAt)) ?? Date()
        source = (try? container.decode(String.self, forKey: .source)) ?? "web"
        history = (try? container.decode([FileVersion].self, forKey: .history)) ?? []
        trashedAt = try? container.decode(Date.self, forKey: .trashedAt)
        originalPath = try? container.decode(String.self, forKey: .originalPath)
    }
}

// MARK: - 索引文件（info/index.json）

struct VolumeIndex: Codable {
    var version: Int = 1
    /// 磁盘格式版本：由写出这份文件的软件声明，用于判断“只读打开”还是“需要迁移”
    var formatVersion: Int = DiskSchema.currentVersion
    var volumeId: String
    var volumeName: String
    var updatedAt: Date = Date()
    /// 显式创建的空文件夹（逻辑路径），文件所在目录会自动推导，不重复记录
    var folders: [String] = []
    var entries: [FileEntry] = []
    /// 回收站：放在单独数组里，这样列表/搜索/去重统计等既有逻辑天然看不到它们
    var trashed: [FileEntry] = []
}

extension VolumeIndex {
    /// 宽容解码：任何字段缺失都用默认值补上，保证老/新版本互相读取都不会失败
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? container.decode(Int.self, forKey: .version)) ?? 1
        formatVersion = (try? container.decode(Int.self, forKey: .formatVersion)) ?? 1
        volumeId = (try? container.decode(String.self, forKey: .volumeId)) ?? ""
        volumeName = (try? container.decode(String.self, forKey: .volumeName)) ?? ""
        updatedAt = (try? container.decode(Date.self, forKey: .updatedAt)) ?? Date()
        folders = (try? container.decode([String].self, forKey: .folders)) ?? []
        entries = (try? container.decode([FileEntry].self, forKey: .entries)) ?? []
        trashed = (try? container.decode([FileEntry].self, forKey: .trashed)) ?? []
    }
}

/// 目录身份标记（info/volume.json），保证目录被移动/重新打开后 id 不变
struct VolumeMarker: Codable {
    static let appName = "MacNas"
    var app: String = VolumeMarker.appName
    var version: Int = 1
    var formatVersion: Int = DiskSchema.currentVersion
    var id: String
    var name: String
    var createdAt: Date
}

extension VolumeMarker {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        app = (try? container.decode(String.self, forKey: .app)) ?? VolumeMarker.appName
        version = (try? container.decode(Int.self, forKey: .version)) ?? 1
        formatVersion = (try? container.decode(Int.self, forKey: .formatVersion)) ?? 1
        id = (try? container.decode(String.self, forKey: .id)) ?? ""
        name = (try? container.decode(String.self, forKey: .name)) ?? ""
        createdAt = (try? container.decode(Date.self, forKey: .createdAt)) ?? Date()
    }
}

// MARK: - 列目录

struct FolderItem: Hashable {
    var name: String
    var path: String
    var fileCount: Int
    var explicit: Bool
}

struct DirectoryListing {
    var path: String
    var folders: [FolderItem]
    var files: [FileEntry]
}

// MARK: - 统计

struct VolumeStats {
    var volumeId: String
    var name: String
    var path: String
    var fileCount: Int
    var physicalBytes: Int64
    var logicalBytes: Int64
    var available: Bool
    var missingBlobs: Int
    /// 由更新版本的 MacNas 写入 → 以只读方式打开
    var readOnly: Bool = false
    /// 索引是从 document/blobs 重建出来的
    var rebuilt: Bool = false
}

/// 镜像导出结果：把逻辑目录树导出成真实文件，供 macOS 自带文件共享 / Time Machine 使用
struct MirrorReport {
    var target: String = ""
    var mode: String = "hardlink"      // hardlink | copy
    var linked: Int = 0
    var copied: Int = 0
    var skipped: Int = 0
    var directories: Int = 0
    var bytes: Int64 = 0
    var failures: [String] = []
    var duration: TimeInterval = 0

    var fileCount: Int { linked + copied + skipped }
    var summary: String {
        "共 \(fileCount) 个文件（新建链接 \(linked)、复制 \(copied)、已是最新 \(skipped)），" +
        "\(directories) 个目录，\(bytes / 1024 / 1024) MB，用时 \(String(format: "%.1f", duration)) 秒"
    }
}

/// 空间分析结果（供「存储分析」应用使用）
struct AnalyticsCategory {
    var key: String          // 扩展名，空表示「无扩展名」
    var fileCount: Int = 0
    var logicalBytes: Int64 = 0
    var physicalBytes: Int64 = 0   // 该类型独占的内容大小
}

struct AnalyticsDuplicate {
    var sha256: String
    var size: Int64
    var refCount: Int
    var names: [String]
    /// 因为重复而多占的空间（同一内容按条数算）
    var wastedBytes: Int64 { size * Int64(max(0, refCount - 1)) }
}

struct AnalyticsBigFile {
    var name: String
    var path: String
    var volumeId: String
    var size: Int64
    var entryId: String
}

struct AnalyticsTrashItem {
    var name: String
    var originalPath: String
    var size: Int64
    var volumeId: String
}

/// 大小分档：让用户一眼看出「是很多小文件占地方，还是少数大文件占地方」
struct AnalyticsSizeBucket {
    var label: String        // 展示用，如 "<100KB"
    var upperBound: Int64    // 上界（字节），最后一档为 Int64.max
    var fileCount: Int = 0
    var bytes: Int64 = 0
    /// 该档里最大的那个文件，方便直接跳过去看
    var largestName: String?
    var largestId: String?
    var largestVolumeId: String?
    var largestSize: Int64 = 0
}

struct Analytics {
    var fileCount: Int = 0
    var uniqueBlobCount: Int = 0
    var logicalBytes: Int64 = 0
    var physicalBytes: Int64 = 0
    var missingBlobs: Int = 0
    /// 历史版本占用的额外空间（只被历史版本引用的内容）
    var historyBytes: Int64 = 0
    var historyCount: Int = 0
    var sizeBuckets: [AnalyticsSizeBucket] = []
    var categories: [AnalyticsCategory] = []
    var duplicates: [AnalyticsDuplicate] = []
    var largest: [AnalyticsBigFile] = []
    var trashItems: [AnalyticsTrashItem] = []

    var savedBytes: Int64 { max(0, logicalBytes - physicalBytes) }
    var savedRatio: Double { logicalBytes > 0 ? Double(savedBytes) / Double(logicalBytes) : 0 }
    var wastedBytes: Int64 { duplicates.reduce(0) { $0 + $1.wastedBytes } }
    var trashBytes: Int64 { trashItems.reduce(0) { $0 + $1.size } }

    var dictionary: [String: Any] {
        var payload: [String: Any] = [
            "fileCount": fileCount,
            "uniqueBlobCount": uniqueBlobCount,
            "logicalBytes": logicalBytes,
            "physicalBytes": physicalBytes,
            "savedBytes": savedBytes,
            "savedRatio": savedRatio,
            "wastedBytes": wastedBytes,
            "historyBytes": historyBytes,
            "historyCount": historyCount,
            "trashCount": trashItems.count,
            "trashBytes": trashBytes,
            "missingBlobs": missingBlobs
        ]
        payload["categories"] = categories.map { category in
            ["key": category.key.isEmpty ? "其它" : category.key,
             "fileCount": category.fileCount,
             "logicalBytes": category.logicalBytes,
             "physicalBytes": category.physicalBytes]
        }
        payload["duplicates"] = duplicates.map { item in
            ["sha256": item.sha256, "size": item.size, "refCount": item.refCount,
             "wastedBytes": item.wastedBytes, "names": item.names]
        }
        payload["largest"] = largest.map { item in
            ["id": item.entryId, "name": item.name, "path": item.path,
             "volumeId": item.volumeId, "size": item.size]
        }
        payload["sizeBuckets"] = sizeBuckets.map { bucket in
            var entry: [String: Any] = [
                "label": bucket.label,
                "upperBound": bucket.upperBound == Int64.max ? -1 : bucket.upperBound,
                "fileCount": bucket.fileCount,
                "bytes": bucket.bytes
            ]
            if let name = bucket.largestName {
                entry["largestName"] = name
                entry["largestSize"] = bucket.largestSize
                if let id = bucket.largestId { entry["largestId"] = id }
                if let volumeId = bucket.largestVolumeId { entry["largestVolumeId"] = volumeId }
            }
            return entry
        }
        payload["trash"] = trashItems.map { item in
            ["name": item.name, "path": item.originalPath, "size": item.size, "volumeId": item.volumeId]
        }
        return payload
    }
}

struct StoreStats {
    var volumeCount: Int = 0
    var fileCount: Int = 0
    var uniqueBlobCount: Int = 0
    var physicalBytes: Int64 = 0
    var logicalBytes: Int64 = 0
    var missingBlobs: Int = 0
    var volumeStats: [VolumeStats] = []

    var savedBytes: Int64 { max(0, logicalBytes - physicalBytes) }
    var savedRatio: Double {
        logicalBytes > 0 ? Double(savedBytes) / Double(logicalBytes) : 0
    }
}

// MARK: - 上传结果

enum UploadOutcome: String {
    case stored        // 新文件，落盘
    case deduplicated  // 命中哈希，只写记录
}

// MARK: - 错误

enum StoreError: LocalizedError {
    case volumeNotFound
    case volumeUnavailable(String)
    case readOnly(String)
    case invalidPath(String)
    case invalidName(String)
    case conflict(String)
    case notFound(String)
    case io(String)

    var errorDescription: String? {
        switch self {
        case .volumeNotFound: return "找不到该目录"
        case .volumeUnavailable(let p): return "目录当前不可用：\(p)"
        case .readOnly(let name): return "「\(name)」由更新版本的 MacNas 写入，当前版本以只读方式打开，请升级软件后再修改"
        case .invalidPath(let p): return "路径不合法：\(p)"
        case .invalidName(let n): return "名称不合法：\(n)"
        case .conflict(let m): return m
        case .notFound(let m): return m
        case .io(let m): return m
        }
    }
}

// MARK: - 逻辑路径工具

enum LogicalPath {
    static let root = "/"

    /// 归一化：统一以 "/" 开头，去掉重复斜杠与结尾斜杠，"." 直接丢弃
    static func normalize(_ raw: String) -> String {
        let decoded = raw.removingPercentEncoding ?? raw
        var parts: [String] = []
        for segment in decoded.split(separator: "/", omittingEmptySubsequences: true) {
            let s = String(segment).trimmingCharacters(in: .whitespacesAndNewlines)
            if s.isEmpty || s == "." { continue }
            if s == ".." { if !parts.isEmpty { parts.removeLast() }; continue }
            parts.append(s)
        }
        if parts.isEmpty { return root }
        return "/" + parts.joined(separator: "/")
    }

    static func segments(_ path: String) -> [String] {
        normalize(path).split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    static func parent(_ path: String) -> String {
        var parts = segments(path)
        if parts.isEmpty { return root }
        parts.removeLast()
        return parts.isEmpty ? root : "/" + parts.joined(separator: "/")
    }

    static func lastSegment(_ path: String) -> String {
        segments(path).last ?? ""
    }

    static func join(_ directory: String, _ name: String) -> String {
        let dir = normalize(directory)
        let clean = name.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return dir == root ? "/" + clean : dir + "/" + clean
    }

    static func depth(_ path: String) -> Int { segments(path).count }

    static func isDescendant(_ path: String, of prefix: String) -> Bool {
        let p = normalize(path), q = normalize(prefix)
        if q == root { return p != root }
        return p.hasPrefix(q + "/")
    }

    /// 单个路径段（文件/文件夹名）校验：拒绝空、"."、".."、分隔符、控制字符
    static func sanitizedSegment(_ raw: String) -> String? {
        let name = raw.precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty { return nil }
        if name == "." || name == ".." { return nil }
        if name.contains("/") || name.contains(":") { return nil }
        if name.utf8.count > 200 { return nil }
        for scalar in name.unicodeScalars {
            if scalar.value < 0x20 || scalar.value == 0x7F { return nil }
        }
        return name
    }

    static func fileExtension(for name: String) -> String {
        let ext = (name as NSString).pathExtension.lowercased()
        let allowed = CharacterSet.alphanumerics
        guard !ext.isEmpty, ext.count <= 12,
              ext.unicodeScalars.allSatisfy({ allowed.contains($0) }) else { return "" }
        return ext
    }
}
