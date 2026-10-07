//
//  APIKeyStore.swift
//  MacNas
//
//  第三方开发者用的 API Key。
//
//  设计要点（对外公开 API 的安全底线）：
//  1. 明文 key 只在创建时返回一次，磁盘上只存 SHA-256 哈希 —— 即使配置文件泄露也无法反推 key。
//  2. 每个 key 带权限范围（read / write）与可选过期时间，可以随时在软件里撤销。
//  3. 每个 key 单独限流，避免某个开发者把服务器打满。
//  4. 记录最后使用时间与调用次数，方便用户判断某个 key 是否还在被使用。
//

import Foundation

/// Core 层不能依赖 Server 层的 ISO8601 工具，这里自带一个
private let apiKeyISOFormatter: ISO8601DateFormatter = {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    return formatter
}()

struct APIKeyRecord: Codable {
    var id: String
    var name: String
    /// 展示用前缀（例如 macnas_a1b2c3…），方便识别，不足以反推完整 key
    var prefix: String
    /// 明文 key 的 SHA-256（十六进制）
    var keyHash: String
    /// "read" / "write"（write 隐含 read）
    var scopes: [String]
    var createdAt: Date
    var expiresAt: Date?
    var enabled: Bool
    var lastUsedAt: Date?
    var requestCount: Int

    var isExpired: Bool {
        guard let expiresAt else { return false }
        return Date() > expiresAt
    }

    var canRead: Bool { enabled && !isExpired && (scopes.contains("read") || scopes.contains("write")) }
    var canWrite: Bool { enabled && !isExpired && scopes.contains("write") }

    /// 对外展示用（绝不包含 key 本身）
    var dictionary: [String: Any] {
        var payload: [String: Any] = [
            "id": id,
            "name": name,
            "prefix": prefix,
            "scopes": scopes,
            "createdAt": apiKeyISOFormatter.string(from: createdAt),
            "enabled": enabled,
            "requestCount": requestCount,
            "expired": isExpired
        ]
        if let expiresAt { payload["expiresAt"] = apiKeyISOFormatter.string(from: expiresAt) }
        if let lastUsedAt { payload["lastUsedAt"] = apiKeyISOFormatter.string(from: lastUsedAt) }
        return payload
    }
}

struct APIKeyFile: Codable {
    var formatVersion: Int = DiskSchema.currentVersion
    var keys: [APIKeyRecord] = []
}

/// 新建 key 的结果：明文只在这里出现一次
struct APIKeyCreation {
    var record: APIKeyRecord
    var plaintext: String
}

final class APIKeyStore: @unchecked Sendable {

    private let url: URL
    private let queue = DispatchQueue(label: "cn.zenlc.macnas.apikeys")
    private var file = APIKeyFile()

    /// 限流窗口
    private var windows: [String: (start: Date, count: Int)] = [:]
    private let readPerMinute = 600
    private let writePerMinute = 120

    init(url: URL? = nil) {
        self.url = url ?? AppPaths.supportDirectory.appendingPathComponent("api-keys.json")
        load()
    }

    // MARK: - 读取

    func all() -> [APIKeyRecord] {
        queue.sync { file.keys.sorted { $0.createdAt > $1.createdAt } }
    }

    func count() -> Int { queue.sync { file.keys.count } }

    /// 用明文 key 找到对应记录（只做哈希比对）
    func find(plaintext: String) -> APIKeyRecord? {
        let hash = FileHash.sha256(of: Data(plaintext.utf8))
        return queue.sync { file.keys.first { $0.keyHash == hash } }
    }

    @discardableResult
    func recordUse(id: String) -> APIKeyRecord? {
        queue.sync {
            guard let index = file.keys.firstIndex(where: { $0.id == id }) else { return nil }
            file.keys[index].lastUsedAt = Date()
            file.keys[index].requestCount += 1
            saveLocked(force: false)
            return file.keys[index]
        }
    }

    // MARK: - 创建 / 撤销

    func create(name: String, scopes: [String], expiresInDays: Int?) throws -> APIKeyCreation {
        let cleaned = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalName = cleaned.isEmpty ? "未命名应用" : cleaned
        let validScopes = scopes.filter { $0 == "read" || $0 == "write" }
        guard !validScopes.isEmpty else { throw StoreError.invalidPath("至少要给一个权限（read 或 write）") }

        // 32 字节随机 + 固定前缀，便于用户识别与日志排查
        let secret = RandomBytes.hex(count: 32)
        let plaintext = "macnas_" + secret
        var record = APIKeyRecord(id: UUID().uuidString,
                                  name: finalName,
                                  prefix: "macnas_" + secret.prefix(8),
                                  keyHash: FileHash.sha256(of: Data(plaintext.utf8)),
                                  scopes: validScopes,
                                  createdAt: Date(),
                                  expiresAt: nil,
                                  enabled: true,
                                  lastUsedAt: nil,
                                  requestCount: 0)
        if let days = expiresInDays, days > 0 {
            record.expiresAt = Date().addingTimeInterval(TimeInterval(days) * 86400)
        }
        queue.sync {
            file.keys.append(record)
            saveLocked(force: true)
        }
        LogCenter.shared.info("已创建 API Key：\(finalName)（权限 \(validScopes.joined(separator: "+"))）")
        return APIKeyCreation(record: record, plaintext: plaintext)
    }

    @discardableResult
    func revoke(id: String) -> Bool {
        queue.sync {
            guard let index = file.keys.firstIndex(where: { $0.id == id }) else { return false }
            let removed = file.keys.remove(at: index)
            windows[removed.id] = nil
            saveLocked(force: true)
            LogCenter.shared.info("已撤销 API Key：\(removed.name)")
            return true
        }
    }

    // MARK: - 限流

    enum RateLimitResult {
        case allowed
        case limited(retryAfter: Int)
    }

    /// 简单的每分钟窗口限流，按 key + 读写分别计数
    func checkRate(_ record: APIKeyRecord, writing: Bool) -> RateLimitResult {
        queue.sync {
            let key = record.id + (writing ? ":write" : ":read")
            let limit = writing ? writePerMinute : readPerMinute
            let now = Date()
            if var window = windows[key], now.timeIntervalSince(window.start) < 60 {
                if window.count >= limit {
                    let retry = max(1, Int(60 - now.timeIntervalSince(window.start)))
                    return .limited(retryAfter: retry)
                }
                window.count += 1
                windows[key] = window
                return .allowed
            }
            windows[key] = (start: now, count: 1)
            return .allowed
        }
    }

    // MARK: - 磁盘

    private func load() {
        guard let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder.iso.decode(APIKeyFile.self, from: data) else {
            file = APIKeyFile()
            return
        }
        file = decoded
    }

    private func saveLocked(force: Bool) {
        guard let data = try? JSONEncoder.pretty.encode(file) else { return }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }
}
