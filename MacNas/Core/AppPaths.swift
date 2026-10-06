//
//  AppPaths.swift
//  MacNas
//
//  应用自身的配置 / 日志 / 上传临时目录位置。
//

import Foundation

enum AppPaths {
    /// 支持通过 MACNAS_CONFIG_DIR 覆盖，便于测试与“命令行模式”
    static var supportDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["MACNAS_CONFIG_DIR"], !override.isEmpty {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("MacNas", isDirectory: true)
    }

    static var configURL: URL { supportDirectory.appendingPathComponent("config.json") }
    static var sharesURL: URL { supportDirectory.appendingPathComponent("shares.json") }
    static var logsDirectory: URL { supportDirectory.appendingPathComponent("logs", isDirectory: true) }
    static var uploadsDirectory: URL { supportDirectory.appendingPathComponent("uploads", isDirectory: true) }
    static var currentLogURL: URL { logsDirectory.appendingPathComponent("macnas.log") }

    @discardableResult
    static func ensureDirectories() -> Bool {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
            try fm.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
            try fm.createDirectory(at: uploadsDirectory, withIntermediateDirectories: true)
            return true
        } catch {
            return false
        }
    }

    /// 清掉上次异常退出残留的上传临时文件
    static func clearStaleUploads() {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: uploadsDirectory, includingPropertiesForKeys: nil) else { return }
        for item in items {
            try? fm.removeItem(at: item)
        }
    }
}
