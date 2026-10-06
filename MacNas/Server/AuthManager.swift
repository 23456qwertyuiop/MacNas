//
//  AuthManager.swift
//  MacNas
//
//  账号密码校验与会话管理。账号密码由软件端设置，网页端只能登录，不能修改。
//

import Foundation

final class AuthManager: @unchecked Sendable {

    static let cookieName = "macnas_session"

    private let lock = NSLock()
    private var username = ""
    private var saltHex = ""
    private var hashHex = ""
    private var sessions: [String: Date] = [:]
    private let sessionTTL: TimeInterval = 7 * 24 * 60 * 60
    /// WebDAV 用的是 HTTP Basic：每个请求都带密码。
    /// 不能每次都跑一遍 PBKDF2（10 万次迭代 ~0.5 秒），否则 Finder 浏览会非常卡，
    /// 因此把“这组凭据刚刚验证通过”缓存几分钟（只存摘要，进程内存里，改密码即清空）。
    private var basicCache: [String: Date] = [:]
    private let basicCacheTTL: TimeInterval = 300

    func updateCredentials(username: String, saltHex: String, hashHex: String) {
        lock.lock()
        defer { lock.unlock() }
        self.username = username
        self.saltHex = saltHex
        self.hashHex = hashHex
        self.sessions.removeAll()
        self.basicCache.removeAll()
    }

    var currentUsername: String {
        lock.lock()
        defer { lock.unlock() }
        return username
    }

    /// WebDAV 基础认证（HTTP Basic）：只校验，不建立浏览器会话。
    /// 命中缓存时直接放行，避免每个请求都做一次昂贵的 PBKDF2。
    func verifyBasic(username inputName: String, password: String) -> Bool {
        let cacheKey = FileHash.sha256(of: Data((inputName + "\u{1F}" + password).utf8))

        lock.lock()
        if let verifiedAt = basicCache[cacheKey], Date().timeIntervalSince(verifiedAt) < basicCacheTTL {
            lock.unlock()
            return true
        }
        let storedName = username
        let salt = saltHex
        let hash = hashHex
        lock.unlock()

        guard !storedName.isEmpty, !hash.isEmpty else { return false }
        guard PasswordHasher.constantTimeEquals(inputName, storedName) else { return false }
        guard PasswordHasher.verify(password: password, saltHex: salt, expectedHex: hash) else { return false }

        lock.lock()
        purgeBasicCacheLocked()
        basicCache[cacheKey] = Date()
        lock.unlock()
        return true
    }

    private func primeBasicCacheLocked(username: String, password: String) {
        let key = FileHash.sha256(of: Data((username + "\u{1F}" + password).utf8))
        purgeBasicCacheLocked()
        basicCache[key] = Date()
    }

    private func purgeBasicCacheLocked() {
        let now = Date()
        basicCache = basicCache.filter { now.timeIntervalSince($0.value) < basicCacheTTL }
        if basicCache.count > 64 { basicCache.removeAll() }
    }

    /// 成功返回会话令牌，失败返回 nil
    func login(username inputName: String, password: String) -> String? {
        lock.lock()
        let storedName = username
        let salt = saltHex
        let hash = hashHex
        lock.unlock()

        guard !storedName.isEmpty, !hash.isEmpty else { return nil }
        guard PasswordHasher.constantTimeEquals(inputName, storedName) else {
            Thread.sleep(forTimeInterval: 0.6)
            return nil
        }
        guard PasswordHasher.verify(password: password, saltHex: salt, expectedHex: hash) else {
            Thread.sleep(forTimeInterval: 0.6)
            return nil
        }

        let token = RandomBytes.hex(count: 32)
        lock.lock()
        purgeExpiredLocked()
        sessions[token] = Date()
        // 顺手预热 WebDAV 的 Basic 缓存：这样挂载时的第一个请求也是毫秒级
        primeBasicCacheLocked(username: storedName, password: password)
        lock.unlock()
        return token
    }

    func validate(token: String?) -> Bool {
        guard let token, !token.isEmpty else { return false }
        lock.lock()
        defer { lock.unlock() }
        purgeExpiredLocked()
        return sessions[token] != nil
    }

    func logout(token: String?) {
        guard let token else { return }
        lock.lock()
        sessions.removeValue(forKey: token)
        lock.unlock()
    }

    func invalidateAllSessions() {
        lock.lock()
        sessions.removeAll()
        lock.unlock()
    }

    private func purgeExpiredLocked() {
        let now = Date()
        sessions = sessions.filter { now.timeIntervalSince($0.value) < sessionTTL }
    }
}
