//
//  LogCenter.swift
//  MacNas
//
//  环形日志缓冲：界面展示最近日志，同时镜像写入日志文件。
//

import Foundation

struct LogEntry: Identifiable, Hashable {
    enum Level: String, CaseIterable {
        case debug, info, warn, error

        var label: String {
            switch self {
            case .debug: return "调试"
            case .info: return "信息"
            case .warn: return "警告"
            case .error: return "错误"
            }
        }
    }

    let id: UInt64
    let date: Date
    let level: Level
    let message: String
}

final class LogCenter: @unchecked Sendable {
    static let shared = LogCenter()

    private let queue = DispatchQueue(label: "cn.zenlc.macnas.log")
    private var storage: [LogEntry] = []
    private let capacity = 3000
    private var nextID: UInt64 = 1
    private var fileHandle: FileHandle?
    private var notify: (() -> Void)?
    private var notificationScheduled = false
    private let maxLogFileSize: UInt64 = 4 * 1024 * 1024

    private let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()

    private init() {}

    // MARK: - 写入

    func debug(_ message: String) { log(.debug, message) }
    func info(_ message: String) { log(.info, message) }
    func warn(_ message: String) { log(.warn, message) }
    func error(_ message: String) { log(.error, message) }

    func log(_ level: LogEntry.Level, _ message: String) {
        let now = Date()
        queue.async { [weak self] in
            guard let self else { return }
            let entry = LogEntry(id: self.nextID, date: now, level: level, message: message)
            self.nextID += 1
            self.storage.append(entry)
            if self.storage.count > self.capacity {
                self.storage.removeFirst(self.storage.count - self.capacity)
            }
            self.appendToFile(entry)
            self.scheduleNotification()
        }
    }

    // MARK: - 读取

    func snapshot(limit: Int = 800) -> [LogEntry] {
        queue.sync {
            if storage.count <= limit { return storage }
            return Array(storage.suffix(limit))
        }
    }

    func allSnapshot() -> [LogEntry] { queue.sync { storage } }

    func clear() {
        queue.sync {
            storage.removeAll()
        }
        scheduleNotification()
    }

    var logFileURL: URL { AppPaths.currentLogURL }

    /// 节流通知，避免大量日志时刷爆主线程
    func setObserver(_ handler: @escaping () -> Void) {
        queue.sync { notify = handler }
    }

    private func scheduleNotification() {
        if notificationScheduled { return }
        notificationScheduled = true
        queue.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self else { return }
            self.notificationScheduled = false
            let handler = self.notify
            DispatchQueue.main.async { handler?() }
        }
    }

    // MARK: - 文件

    private func appendToFile(_ entry: LogEntry) {
        guard AppPaths.ensureDirectories() else { return }
        if fileHandle == nil {
            let url = AppPaths.currentLogURL
            let fm = FileManager.default
            if !fm.fileExists(atPath: url.path) {
                fm.createFile(atPath: url.path, contents: nil)
            }
            rotateIfNeeded(url: url)
            fileHandle = try? FileHandle(forWritingTo: url)
            _ = try? fileHandle?.seekToEnd()
        }
        let line = "[\(formatter.string(from: entry.date))] [\(entry.level.rawValue.uppercased())] \(entry.message)\n"
        if let data = line.data(using: .utf8) {
            try? fileHandle?.write(contentsOf: data)
        }
    }

    private func rotateIfNeeded(url: URL) {
        let fm = FileManager.default
        guard let attrs = try? fm.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? UInt64, size > maxLogFileSize else { return }
        try? fileHandle?.close()
        fileHandle = nil
        let backup = url.deletingPathExtension().appendingPathExtension("1.log")
        try? fm.removeItem(at: backup)
        try? fm.moveItem(at: url, to: backup)
        fm.createFile(atPath: url.path, contents: nil)
    }
}
