//
//  ConfigStore.swift
//  MacNas
//
//  应用配置（账号 / 端口 / 目录列表）读写。
//
//  与卷内数据一样遵守稳定性契约：
//  - 缺字段不会导致整份配置读不出来（宽容解码）
//  - 不认识的字段会原样保留再写回，老版本不会抹掉新版本的设置
//

import Foundation

struct AppConfig: Codable {
    var version: Int = 1
    var formatVersion: Int = DiskSchema.currentVersion
    var initialized: Bool = false
    var username: String = ""
    var passwordSalt: String = ""
    var passwordHash: String = ""
    var port: UInt16 = 8080
    var volumes: [Volume] = []
    var autoStartServer: Bool = true
    /// WebDAV 共享（Finder 里挂载 /dav）
    var webdavEnabled: Bool = true
    var webdavReadOnly: Bool = false
    /// 回收站保留天数（超期自动清理；0 表示不自动清理）
    var trashRetentionDays: Int = 30

    static let defaultPort: UInt16 = 8080
}

extension AppConfig {
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = (try? container.decode(Int.self, forKey: .version)) ?? 1
        formatVersion = (try? container.decode(Int.self, forKey: .formatVersion)) ?? 1
        initialized = (try? container.decode(Bool.self, forKey: .initialized)) ?? false
        username = (try? container.decode(String.self, forKey: .username)) ?? ""
        passwordSalt = (try? container.decode(String.self, forKey: .passwordSalt)) ?? ""
        passwordHash = (try? container.decode(String.self, forKey: .passwordHash)) ?? ""
        if let decodedPort = try? container.decode(UInt16.self, forKey: .port), decodedPort > 0 {
            port = decodedPort
        } else {
            port = AppConfig.defaultPort
        }
        volumes = (try? container.decode([Volume].self, forKey: .volumes)) ?? []
        autoStartServer = (try? container.decode(Bool.self, forKey: .autoStartServer)) ?? true
        webdavEnabled = (try? container.decode(Bool.self, forKey: .webdavEnabled)) ?? true
        webdavReadOnly = (try? container.decode(Bool.self, forKey: .webdavReadOnly)) ?? false
        trashRetentionDays = (try? container.decode(Int.self, forKey: .trashRetentionDays)) ?? 30
    }
}

final class ConfigStore {
    private let url: URL
    /// 配置文件里当前版本不认识的字段
    private var preserved: JSONObject = [:]

    init(url: URL = AppPaths.configURL) {
        self.url = url
    }

    private var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    private var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }

    func load() -> AppConfig? {
        guard let data = try? Data(contentsOf: url),
              let object = JSONPreservation.object(from: data),
              let config = try? decoder.decode(AppConfig.self, from: data) else { return nil }
        preserved = JSONPreservation.unknownFields(in: object, known: SchemaFields.config)
        if !preserved.isEmpty {
            LogCenter.shared.info("配置文件里保留了 \(preserved.count) 个当前版本不认识的字段（不会被覆盖）")
        }
        return config
    }

    func save(_ config: AppConfig) throws {
        var updated = config
        updated.formatVersion = DiskSchema.currentVersion
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)

        var object = JSONPreservation.object(from: try encoder.encode(updated)) ?? [:]
        JSONPreservation.merge(preserved, into: &object)
        guard let data = JSONPreservation.data(from: object) else {
            throw StoreError.io("无法序列化配置文件")
        }
        try data.write(to: url, options: .atomic)
    }

    func delete() {
        try? FileManager.default.removeItem(at: url)
        preserved = [:]
    }

    var fileURL: URL { url }
}
