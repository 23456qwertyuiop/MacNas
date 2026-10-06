//
//  ShareStore.swift
//  MacNas
//
//  分享链接：给一个文件或文件夹生成一条分享记录，凭链接可以匿名访问。
//
//  遵守与卷内数据相同的稳定性规则：
//  - 独立文件（Application Support/MacNas/shares.json），不改变任何卷的结构
//  - 宽容解码 + 未知字段原样保留 + formatVersion
//

import Foundation

struct ShareRecord: Codable {
    var token: String
    var volumeId: String
    /// "file" 或 "folder"
    var kind: String
    /// 分享文件时指向具体记录
    var entryId: String?
    /// 文件夹路径；或分享文件当时所在的逻辑路径（用于显示与兜底）
    var logicalPath: String
    var name: String
    var createdAt: Date
    /// nil 表示永久有效
    var expiresAt: Date?
    var passwordSalt: String?
    var passwordHash: String?
    var enabled: Bool
    var visits: Int
    var downloads: Int
    var formatVersion: Int

    // MARK: 照片收集（kind == "collect"）
    /// 是否允许访客上传
    var allowUpload: Bool
    /// 单个文件最大字节数（0 = 不限）
    var maxFileBytes: Int64
    /// 这个链接累计最多接收多少字节（0 = 不限）
    var maxTotalBytes: Int64
    /// 已经接收的字节数与文件数
    var uploadedBytes: Int64
    var uploadedCount: Int
    /// 只接受图片/视频
    var imagesOnly: Bool

    var isCollect: Bool { kind == "collect" }
    /// 还能接收多少字节（不限时为 nil）
    var remainingBytes: Int64? {
        guard maxTotalBytes > 0 else { return nil }
        return max(0, maxTotalBytes - uploadedBytes)
    }
    var quotaReached: Bool {
        maxTotalBytes > 0 && uploadedBytes >= maxTotalBytes
    }

    init(token: String,
         volumeId: String,
         kind: String,
         entryId: String?,
         logicalPath: String,
         name: String,
         createdAt: Date = Date(),
         expiresAt: Date? = nil,
         passwordSalt: String? = nil,
         passwordHash: String? = nil,
         enabled: Bool = true,
         visits: Int = 0,
         downloads: Int = 0,
         allowUpload: Bool = false,
         maxFileBytes: Int64 = 0,
         maxTotalBytes: Int64 = 0,
         uploadedBytes: Int64 = 0,
         uploadedCount: Int = 0,
         imagesOnly: Bool = true) {
        self.token = token
        self.volumeId = volumeId
        self.kind = kind
        self.entryId = entryId
        self.logicalPath = logicalPath
        self.name = name
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.passwordSalt = passwordSalt
        self.passwordHash = passwordHash
        self.enabled = enabled
        self.visits = visits
        self.downloads = downloads
        self.allowUpload = allowUpload
        self.maxFileBytes = maxFileBytes
        self.maxTotalBytes = maxTotalBytes
        self.uploadedBytes = uploadedBytes
        self.uploadedCount = uploadedCount
        self.imagesOnly = imagesOnly
        self.formatVersion = DiskSchema.currentVersion
    }

    var isFolder: Bool { kind == "folder" }
    var hasPassword: Bool { !(passwordHash ?? "").isEmpty }

    func isExpired(now: Date = Date()) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt <= now
    }

    var typeText: String {
        if isCollect { return "照片收集" }
        return isFolder ? "文件夹" : "文件"
    }

    /// 分享后用于校验“匿名访问密码”的 Cookie 值：只由服务端持有的哈希推导，可无状态校验
    var passwordCookieValue: String? {
        guard let hash = passwordHash, !hash.isEmpty else { return nil }
        return FileHash.sha256(of: Data((hash + "|" + token).utf8))
    }
}

extension ShareRecord {
    /// 宽容解码：字段缺失或类型不符也不至于让整份分享文件读不出来
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        token = (try? container.decode(String.self, forKey: .token)) ?? ""
        volumeId = (try? container.decode(String.self, forKey: .volumeId)) ?? ""
        kind = (try? container.decode(String.self, forKey: .kind)) ?? "file"
        entryId = try? container.decode(String.self, forKey: .entryId)
        logicalPath = (try? container.decode(String.self, forKey: .logicalPath)) ?? "/"
        name = (try? container.decode(String.self, forKey: .name)) ?? ""
        createdAt = (try? container.decode(Date.self, forKey: .createdAt)) ?? Date()
        expiresAt = try? container.decode(Date.self, forKey: .expiresAt)
        passwordSalt = try? container.decode(String.self, forKey: .passwordSalt)
        passwordHash = try? container.decode(String.self, forKey: .passwordHash)
        enabled = (try? container.decode(Bool.self, forKey: .enabled)) ?? true
        visits = (try? container.decode(Int.self, forKey: .visits)) ?? 0
        downloads = (try? container.decode(Int.self, forKey: .downloads)) ?? 0
        formatVersion = (try? container.decode(Int.self, forKey: .formatVersion)) ?? 1
        allowUpload = (try? container.decode(Bool.self, forKey: .allowUpload)) ?? false
        maxFileBytes = (try? container.decode(Int64.self, forKey: .maxFileBytes)) ?? 0
        maxTotalBytes = (try? container.decode(Int64.self, forKey: .maxTotalBytes)) ?? 0
        uploadedBytes = (try? container.decode(Int64.self, forKey: .uploadedBytes)) ?? 0
        uploadedCount = (try? container.decode(Int.self, forKey: .uploadedCount)) ?? 0
        imagesOnly = (try? container.decode(Bool.self, forKey: .imagesOnly)) ?? true
    }

    /// 记录一次上传（由 ShareStore 在锁内调用）
    mutating func recordUpload(bytes: Int64) {
        uploadedBytes += bytes
        uploadedCount += 1
    }
}

struct ShareFile: Codable {
    var formatVersion: Int = DiskSchema.currentVersion
    var shares: [ShareRecord] = []
}

extension ShareFile {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        formatVersion = (try? container.decode(Int.self, forKey: .formatVersion)) ?? 1
        shares = (try? container.decode([ShareRecord].self, forKey: .shares)) ?? []
    }
}

final class ShareStore: @unchecked Sendable {

    private let queue = DispatchQueue(label: "cn.zenlc.macnas.shares")
    private let url: URL
    private var file = ShareFile()
    private var preserved: JSONObject = [:]
    private var lastFlush = Date.distantPast

    init(url: URL = AppPaths.sharesURL) {
        self.url = url
        load()
    }

    // MARK: - 读

    func all() -> [ShareRecord] {
        queue.sync { file.shares.sorted { $0.createdAt > $1.createdAt } }
    }

    func count() -> Int { queue.sync { file.shares.count } }

    func find(token: String) -> ShareRecord? {
        queue.sync { file.shares.first(where: { $0.token == token }) }
    }

    func shares(forVolumeId volumeId: String) -> [ShareRecord] {
        queue.sync { file.shares.filter { $0.volumeId == volumeId } }
    }

    // MARK: - 写

    @discardableResult
    func create(volumeId: String,
                kind: String,
                entryId: String?,
                logicalPath: String,
                name: String,
                expiresInHours: Int?,
                password: String,
                maxFileBytes: Int64 = 0,
                maxTotalBytes: Int64 = 0,
                imagesOnly: Bool = true) -> ShareRecord {
        queue.sync {
            var record = ShareRecord(token: RandomBytes.hex(count: 16),
                                     volumeId: volumeId,
                                     kind: kind,
                                     entryId: entryId,
                                     logicalPath: logicalPath,
                                     name: name)
            if kind == "collect" {
                record.allowUpload = true
                record.maxFileBytes = max(0, maxFileBytes)
                record.maxTotalBytes = max(0, maxTotalBytes)
                record.imagesOnly = imagesOnly
            }
            if let hours = expiresInHours, hours > 0 {
                record.expiresAt = Date().addingTimeInterval(TimeInterval(hours) * 3600)
            }
            if !password.isEmpty {
                let salt = PasswordHasher.makeSalt()
                record.passwordSalt = salt
                record.passwordHash = PasswordHasher.derive(password: password, saltHex: salt)
            }
            file.shares.append(record)
            saveLocked(force: true)
            let quota = record.maxTotalBytes > 0 ? "，上限 \(record.maxTotalBytes / 1024 / 1024)MB" : ""
            LogCenter.shared.info("已创建分享链接：\(record.typeText)「\(name)」\(record.hasPassword ? "（有密码）" : "")\(record.isCollect ? quota : "")")
            return record
        }
    }

    /// 记录一次收集上传；返回更新后的记录（额度判断由调用方在锁外先做，这里只累加）
    @discardableResult
    func recordUpload(token: String, bytes: Int64) -> ShareRecord? {
        queue.sync {
            guard let index = file.shares.firstIndex(where: { $0.token == token }) else { return nil }
            file.shares[index].recordUpload(bytes: bytes)
            saveLocked(force: true)
            return file.shares[index]
        }
    }

    @discardableResult
    func revoke(token: String) -> Bool {
        queue.sync {
            guard let index = file.shares.firstIndex(where: { $0.token == token }) else { return false }
            let removed = file.shares.remove(at: index)
            saveLocked(force: true)
            LogCenter.shared.info("已取消分享：\(removed.name)")
            return true
        }
    }

    func recordVisit(token: String) {
        queue.sync {
            guard let index = file.shares.firstIndex(where: { $0.token == token }) else { return }
            file.shares[index].visits += 1
            saveLocked(force: false)
        }
    }

    func recordDownload(token: String) {
        queue.sync {
            guard let index = file.shares.firstIndex(where: { $0.token == token }) else { return }
            file.shares[index].downloads += 1
            saveLocked(force: false)
        }
    }

    // MARK: - 磁盘

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let object = JSONPreservation.object(from: data),
              let decoded = try? JSONDecoder.iso.decode(ShareFile.self, from: data) else {
            file = ShareFile()
            return
        }
        file = decoded
        preserved = JSONPreservation.unknownFields(in: object, known: SchemaFields.shareFile)
        LogCenter.shared.info("已读取 \(file.shares.count) 条分享链接")
    }

    /// 访问计数很频繁，这里做节流：最多每 3 秒落盘一次，创建/取消时立即落盘
    private func saveLocked(force: Bool) {
        let now = Date()
        if !force, now.timeIntervalSince(lastFlush) < 3 { return }
        lastFlush = now
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            var object = JSONPreservation.object(from: try JSONEncoder.pretty.encode(file)) ?? [:]
            JSONPreservation.merge(preserved, into: &object)
            guard let data = JSONPreservation.data(from: object) else { return }
            try data.write(to: url, options: .atomic)
        } catch {
            LogCenter.shared.warn("写入分享记录失败：\(error.localizedDescription)")
        }
    }
}
