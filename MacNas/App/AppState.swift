//
//  AppState.swift
//  MacNas
//
//  应用总状态：配置、目录、服务、日志。
//  账号密码与端口只在这里（macOS 软件内）修改。
//

import Foundation
import AppKit
import Observation

@MainActor
@Observable
final class AppState {

    enum Phase {
        case loading
        case onboarding
        case ready
    }

    enum VolumeAddMode {
        case createNew
        case openExisting
    }

    private(set) var phase: Phase = .loading
    private(set) var config: AppConfig
    private(set) var serverState: HTTPServer.State = .stopped
    private(set) var stats = StoreStats()
    /// 最近一次 WebDAV 客户端请求（用于设置页排查挂载问题）
    private(set) var webdavActivity: String = "还没有客户端连过 WebDAV"
    private(set) var logs: [LogEntry] = []
    private(set) var isBusy = false
    private(set) var busyMessage = ""

    var lastError: String?
    var toast: String?

    let store: Store
    /// 第三方开发者 API 的 key 存储（设置页里管理）
    let apiKeys: APIKeyStore
    let auth: AuthManager
    let environment: ServerEnvironment
    let shares: ShareStore
    let server: HTTPServer

    private let configStore: ConfigStore
    private var didBootstrap = false

    // MARK: - 初始化

    init() {
        let configStore = ConfigStore()
        let store = Store()
        let auth = AuthManager()
        let environment = ServerEnvironment()
        let shares = ShareStore()
        let apiKeys = APIKeyStore()
        let router = Router(store: store, auth: auth, environment: environment, shares: shares, apiKeys: apiKeys)
        self.apiKeys = apiKeys

        self.configStore = configStore
        self.store = store
        self.auth = auth
        self.environment = environment
        self.shares = shares
        self.server = HTTPServer(handler: router)
        self.config = configStore.load() ?? AppConfig()
    }

    func bootstrap() {
        guard !didBootstrap else { return }
        didBootstrap = true
        AppPaths.ensureDirectories()
        AppPaths.clearStaleUploads()
        LogCenter.shared.setObserver { [weak self] in
            Task { @MainActor in self?.refreshLogs() }
        }
        LogCenter.shared.info("MacNas \(MacNasInfo.version) 启动")
        LogCenter.shared.info("配置目录：\(AppPaths.supportDirectory.path)")

        server.onStateChange = { [weak self] state in
            guard let self else { return }
            self.serverState = state
            if case .running(let port) = state {
                self.environment.port = port
                self.environment.startedAt = Date()
            }
        }

        refreshLogs()

        if bootstrapFromEnvironmentIfNeeded() {
            phase = .ready
            refreshStats()
            return
        }

        if config.initialized, !config.username.isEmpty, !config.volumes.isEmpty {
            startReadyPhase()
        } else {
            if config.volumes.isEmpty {
                LogCenter.shared.info("尚未初始化，等待用户选择第一个目录")
            } else {
                LogCenter.shared.warn("配置不完整（缺少账号密码），重新进入初始化流程")
            }
            phase = .onboarding
        }
    }

    private func startReadyPhase() {
        let resolved = store.setVolumes(config.volumes)
        if resolved.map(\.id) != config.volumes.map(\.id) || resolved.map(\.name) != config.volumes.map(\.name) {
            config.volumes = resolved
            persist()
        }
        auth.updateCredentials(username: config.username, saltHex: config.passwordSalt, hashHex: config.passwordHash)
        environment.version = MacNasInfo.version
        environment.webdavEnabled = config.webdavEnabled
        environment.webdavReadOnly = config.webdavReadOnly
        environment.trashRetentionDays = config.trashRetentionDays
        environment.setAPICORSOrigins(config.apiCorsOrigins)
        // 启动时清理过期的回收站项（保留天数在设置里可改）
        if config.trashRetentionDays > 0 {
            _ = store.pruneExpiredTrash(olderThanDays: config.trashRetentionDays)
        }
        phase = .ready
        refreshStats()
        if config.autoStartServer {
            startServer()
        }
    }

    /// 命令行 / 自动化模式：MACNAS_ROOT / MACNAS_PORT / MACNAS_USER / MACNAS_PASS
    private func bootstrapFromEnvironmentIfNeeded() -> Bool {
        let environmentVariables = ProcessInfo.processInfo.environment
        guard let root = environmentVariables["MACNAS_ROOT"], !root.isEmpty else { return false }
        if phase == .ready { return true }

        let url = URL(fileURLWithPath: root, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let volume = VolumeBootstrap.inspect(url).isMacNasVolume
                ? try VolumeBootstrap.open(url, fallbackName: url.lastPathComponent)
                : try VolumeBootstrap.prepare(url, name: url.lastPathComponent)

            var updated = configStore.load() ?? AppConfig()
            if !updated.volumes.contains(where: { $0.id == volume.id }) {
                updated.volumes.append(volume)
            }
            updated.username = environmentVariables["MACNAS_USER"] ?? updated.username
            let password = environmentVariables["MACNAS_PASS"] ?? ""
            if !password.isEmpty {
                let salt = PasswordHasher.makeSalt()
                updated.passwordSalt = salt
                updated.passwordHash = PasswordHasher.derive(password: password, saltHex: salt)
            }
            if let portText = environmentVariables["MACNAS_PORT"], let port = UInt16(portText) {
                updated.port = port
            }
            updated.initialized = true
            config = updated
            persist()

            auth.updateCredentials(username: updated.username, saltHex: updated.passwordSalt, hashHex: updated.passwordHash)
            _ = store.setVolumes(updated.volumes)
            LogCenter.shared.info("命令行模式：已装载目录 \(url.path)")
            DispatchQueue.main.async { [weak self] in
                self?.refreshStats()
                self?.startServer()
            }
            return true
        } catch {
            LogCenter.shared.error("命令行模式初始化失败：\(error.localizedDescription)")
            return false
        }
    }

    // MARK: - 初始化流程

    var pendingVolumes: [Volume] { config.volumes }

    @discardableResult
    func addVolume(root: URL, name: String?, mode: VolumeAddMode) -> String? {
        do {
            let displayName = (name?.isEmpty == false ? name! : root.lastPathComponent)
            let volume: Volume
            switch mode {
            case .createNew:
                volume = try VolumeBootstrap.prepare(root, name: displayName)
                LogCenter.shared.info("已创建目录结构：\(root.path)（document / info）")
            case .openExisting:
                volume = try VolumeBootstrap.open(root, fallbackName: displayName)
                LogCenter.shared.info("已打开已有目录：\(root.path)")
            }

            if config.volumes.contains(where: { $0.path == volume.path }) {
                return "这个目录已经添加过了"
            }
            if config.volumes.contains(where: { $0.id == volume.id }) {
                return "这个目录已经添加过了"
            }

            var updated = config.volumes
            updated.append(volume)
            config.volumes = updated
            persist()

            let resolved = store.setVolumes(config.volumes)
            config.volumes = resolved
            persist()
            refreshStats()
            return nil
        } catch {
            LogCenter.shared.error("添加目录失败：\(error.localizedDescription)")
            return error.localizedDescription
        }
    }

    func removeVolume(id: String) {
        config.volumes.removeAll { $0.id == id }
        persist()
        let resolved = store.setVolumes(config.volumes)
        config.volumes = resolved
        persist()
        refreshStats()
        LogCenter.shared.info("已从软件中移除目录（磁盘文件未删除）")
    }

    func renameVolume(id: String, name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = config.volumes.firstIndex(where: { $0.id == id }) else { return }
        config.volumes[index].name = trimmed
        persist()
        store.setVolumeName(volumeId: id, name: trimmed)
    }

    func reloadVolumes() {
        runInBackground { [store] in store.reload() } completion: { [weak self] resolved in
            guard let self else { return }
            self.config.volumes = resolved
            self.persist()
            self.refreshStats()
            self.toast = "已重新读取目录记录"
        }
    }

    /// 完成初始化：写入账号密码与端口，开启网站
    func finishOnboarding(username: String, password: String, port: UInt16) -> String? {
        let name = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return "请填写账号" }
        guard password.count >= 4 else { return "密码至少 4 位" }
        guard !config.volumes.isEmpty else { return "请先选择至少一个目录" }
        guard port >= 1024 else { return "请使用 1024 以上的端口" }
        guard NetworkInfo.isPortAvailable(port) else { return "端口 \(port) 已被占用，请换一个" }

        let salt = PasswordHasher.makeSalt()
        config.username = name
        config.passwordSalt = salt
        config.passwordHash = PasswordHasher.derive(password: password, saltHex: salt)
        config.port = port
        config.initialized = true
        persist()

        auth.updateCredentials(username: name, saltHex: salt, hashHex: config.passwordHash)
        let resolved = store.setVolumes(config.volumes)
        config.volumes = resolved
        persist()

        phase = .ready
        refreshStats()
        startServer()
        LogCenter.shared.info("初始化完成，账号 \(name)，端口 \(port)")
        return nil
    }

    // MARK: - 服务

    func startServer() {
        do {
            try server.start(port: config.port)
        } catch let error as HTTPError {
            lastError = error.message
            LogCenter.shared.error(error.message)
        } catch {
            lastError = error.localizedDescription
            LogCenter.shared.error("启动网站失败：\(error.localizedDescription)")
        }
    }

    func stopServer() {
        server.stop()
        LogCenter.shared.info("网站已停止")
    }

    func toggleServer() {
        if serverState.isRunning {
            stopServer()
        } else {
            startServer()
        }
    }

    /// 修改端口（会自动重启网站）
    func updatePort(_ port: UInt16) -> String? {
        guard port >= 1024 else { return "请使用 1024 以上的端口" }
        guard port != config.port else { return nil }
        let wasRunning = serverState.isRunning
        if serverState.isRunning { server.stop() }
        guard NetworkInfo.isPortAvailable(port) else {
            if wasRunning { startServer() }
            return "端口 \(port) 已被占用，请换一个"
        }
        config.port = port
        persist()
        LogCenter.shared.info("端口已修改为 \(port)")
        if wasRunning { startServer() }
        return nil
    }

    /// 修改账号密码（会注销所有网页登录状态）
    func updateCredentials(username: String, password: String) -> String? {
        let name = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return "账号不能为空" }
        guard password.count >= 4 else { return "密码至少 4 位" }

        let salt = PasswordHasher.makeSalt()
        config.username = name
        config.passwordSalt = salt
        config.passwordHash = PasswordHasher.derive(password: password, saltHex: salt)
        persist()
        auth.updateCredentials(username: name, saltHex: salt, hashHex: config.passwordHash)
        LogCenter.shared.info("账号密码已更新，网页端需重新登录")
        return nil
    }

    func setAutoStart(_ enabled: Bool) {
        config.autoStartServer = enabled
        persist()
    }

    /// 给某个目录启用追加日志（格式 v2）：写入不再随文件数线性变慢。
    /// 代价是旧版 MacNas 之后只能只读打开这个目录，所以要用户明确点。
    func enableFastWrites(volumeId: String) {
        runInBackground { [store] in
            Result { try store.enableJournal(volumeId: volumeId) }
        } completion: { [weak self] result in
            guard let self else { return }
            switch result {
            case .success:
                self.toast = "已启用快速写入（格式 v2），之后的改动不再整份重写索引"
            case .failure(let error):
                self.toast = "启用失败：" + error.localizedDescription
            }
            self.refreshStats()
        }
    }

    /// 整理索引：把追加日志压缩成一份完整 index.json
    func compactIndex(volumeId: String) {
        runInBackground { [store] in
            Result { try store.compactIndex(volumeId: volumeId) }
        } completion: { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let value):
                self.toast = "索引已整理：\(value.entries) 条记录，\(ByteFormatter.string(value.bytes))"
            case .failure(let error):
                self.toast = "整理失败：" + error.localizedDescription
            }
            self.refreshStats()
        }
    }

    /// 某个目录是否已启用追加日志
    func usesJournal(volumeId: String) -> Bool {
        store.usesJournal(volumeId: volumeId)
    }

    /// 镜像导出：把逻辑目录树铺成真实文件（默认硬链接），供 macOS 自带文件共享 / Time Machine 使用。
    /// 导出可能比较久，放到后台队列执行。
    func exportMirror(volumeId: String,
                      target: URL,
                      preferHardlink: Bool = true,
                      completion: @escaping (Result<MirrorReport, Error>) -> Void) {
        let volumeName = store.volumeName(id: volumeId)
        LogCenter.shared.info("开始镜像导出：\(volumeName) → \(target.path)")
        DispatchQueue.global(qos: .userInitiated).async { [store] in
            do {
                let report = try store.mirror(volumeId: volumeId, target: target, preferHardlink: preferHardlink)
                DispatchQueue.main.async { completion(.success(report)) }
            } catch {
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
    }

    /// 生成一把第三方 API Key（明文只在返回值里出现一次）
    func createAPIKey(name: String, scopes: [String], expiresInDays: Int?) -> APIKeyCreation? {
        do {
            let created = try apiKeys.create(name: name, scopes: scopes, expiresInDays: expiresInDays)
            LogCenter.shared.info("已生成 API Key：\(created.record.name)")
            return created
        } catch {
            lastError = "生成 API Key 失败：\(error.localizedDescription)"
            return nil
        }
    }

    func revokeAPIKey(id: String) {
        _ = apiKeys.revoke(id: id)
    }

    var apiKeysList: [APIKeyRecord] { apiKeys.all() }

    /// 设置允许跨域调用 API 的来源（逗号分隔；空 = 不开 CORS）
    func setAPICORSOrigins(_ origins: [String]) {
        config.apiCorsOrigins = origins
        environment.setAPICORSOrigins(origins)
        persist()
    }

    /// 回收站保留天数（超期自动清理；0 = 不自动清理）
    func setTrashRetention(days: Int) {
        config.trashRetentionDays = max(0, days)
        persist()
        environment.trashRetentionDays = config.trashRetentionDays
        environment.setAPICORSOrigins(config.apiCorsOrigins)
        LogCenter.shared.info("回收站保留期已设为 \(config.trashRetentionDays) 天")
    }

    /// WebDAV 共享开关（只读模式禁止写操作，浏览下载不受影响）
    func setWebDAV(enabled: Bool, readOnly: Bool) {
        config.webdavEnabled = enabled
        config.webdavReadOnly = readOnly
        persist()
        environment.webdavEnabled = enabled
        environment.webdavReadOnly = readOnly
        LogCenter.shared.info("WebDAV 已" + (enabled ? "开启" : "关闭") + (readOnly ? "（只读）" : ""))
    }

    /// 自检：不带凭据请求 /dav，正常应当返回 401 + Basic 挑战 + DAV 头。
    /// 用 URLSession 走一遍，和 Finder 的 WebDAV 客户端是同一套网络栈。
    func testWebDAV(completion: @escaping (Bool, String) -> Void) {
        guard let url = URL(string: webdavAddressText) else {
            completion(false, "地址不合法")
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "OPTIONS"
        request.setValue("MacNas-SelfTest", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 8
        let configuration = URLSessionConfiguration.ephemeral
        URLSession(configuration: configuration).dataTask(with: request) { _, response, error in
            DispatchQueue.main.async {
                if let error {
                    completion(false, "连不上：" + error.localizedDescription)
                    return
                }
                guard let http = response as? HTTPURLResponse else {
                    completion(false, "没有拿到 HTTP 响应")
                    return
                }
                let challenge = http.value(forHTTPHeaderField: "WWW-Authenticate") ?? ""
                let dav = http.value(forHTTPHeaderField: "DAV") ?? ""
                if http.statusCode == 401, challenge.lowercased().contains("basic"), !dav.isEmpty {
                    completion(true, "服务器就绪：/dav 返回 401 挑战，DAV: \(dav)")
                } else if http.statusCode == 200 {
                    completion(true, "服务器就绪：/dav 返回 200，DAV: \(dav.isEmpty ? "（缺少 DAV 头）" : dav)")
                } else {
                    completion(false, "异常响应：HTTP \(http.statusCode)（DAV: \(dav.isEmpty ? "无" : dav)）")
                }
            }
        }.resume()
    }

    var webdavAddressText: String {
        let port = config.port
        if let ip = NetworkInfo.primaryIPv4Address() { return "http://\(ip):\(port)/dav" }
        return "http://127.0.0.1:\(port)/dav"
    }

    // MARK: - 维护

    func pruneOrphans(volumeId: String) {
        do {
            let result = try store.pruneOrphans(volumeId: volumeId)
            refreshStats()
            toast = "已清理 \(result.files) 个孤立文件，释放 \(ByteFormatter.string(result.bytes))"
        } catch {
            lastError = error.localizedDescription
            LogCenter.shared.error("清理失败：\(error.localizedDescription)")
        }
    }

    var shareCount: Int { shares.count() }

    /// 卷是否因为“由更新版本的 MacNas 写入”而只读
    func isReadOnly(volumeId: String) -> Bool {
        stats.volumeStats.first(where: { $0.volumeId == volumeId })?.readOnly ?? false
    }

    func isRebuilt(volumeId: String) -> Bool {
        stats.volumeStats.first(where: { $0.volumeId == volumeId })?.rebuilt ?? false
    }

    /// 按内容哈希从 document/blobs 重建索引（info 丢失后的救援手段）
    func rebuildIndex(volumeId: String) {
        runInBackground { [store] () -> Result<Int, Error> in
            do { return .success(try store.rebuildIndexFromBlobs(volumeId: volumeId)) }
            catch { return .failure(error) }
        } completion: { [weak self] result in
            guard let self else { return }
            switch result {
            case .success(let count):
                self.refreshStats()
                self.toast = count > 0 ? "已按哈希重建 \(count) 条记录" : "没有找到可恢复的内容"
            case .failure(let error):
                self.lastError = error.localizedDescription
            }
        }
    }

    func revealInFinder(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    func openInBrowser() {
        guard let url = primaryURL else { return }
        NSWorkspace.shared.open(url)
    }

    func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        toast = "已复制：\(text)"
    }

    func chooseDirectory(prompt: String, message: String) -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = prompt
        panel.message = message
        return panel.runModal() == .OK ? panel.url : nil
    }

    func resetConfiguration() {
        server.stop()
        configStore.delete()
        config = AppConfig()
        store.setVolumes([])
        stats = StoreStats()
        phase = .onboarding
        LogCenter.shared.warn("已清除本机配置（磁盘上的 document / info 不会被动到）")
    }

    // MARK: - 展示辅助

    var primaryURL: URL? {
        let port = config.port
        if let ip = NetworkInfo.primaryIPv4Address() {
            return URL(string: "http://\(ip):\(port)")
        }
        return URL(string: "http://127.0.0.1:\(port)")
    }

    var primaryAddressText: String { primaryURL?.absoluteString ?? "-" }

    var localAddressText: String { "http://127.0.0.1:\(config.port)" }

    var accessAddresses: [String] {
        var addresses = NetworkInfo.localIPv4Addresses().map { "http://\($0):\(config.port)" }
        addresses.append(localAddressText)
        return addresses
    }

    func refreshStats() {
        runInBackground { [store] in store.stats() } completion: { [weak self] result in
            self?.stats = result
        }
    }

    /// 刷新 WebDAV 活动摘要：把「谁在什么时候发了什么请求」直接显示出来
    func refreshWebDAVActivity() {
        let last = environment.webdavLastActivity
        let counters = environment.webdavCounters
        guard !last.isEmpty else {
            webdavActivity = "还没有客户端连过 WebDAV"
            return
        }
        let client = last["client"] as? String ?? "未知客户端"
        let request = last["request"] as? String ?? ""
        let at = (last["at"] as? String) ?? ""
        var text = "\(client) · \(request)"
        if let stamp = ISO8601.date(from: at) {
            let formatter = DateFormatter()
            formatter.dateFormat = "MM-dd HH:mm:ss"
            text += " · " + formatter.string(from: stamp)
        }
        text += "\n累计 \(counters.total) 次请求，其中 \(counters.unauthorized) 次没带凭据"
        webdavActivity = text
    }

    func refreshLogs() {
        logs = LogCenter.shared.snapshot(limit: 1200)
    }

    func persist() {
        do {
            try configStore.save(config)
        } catch {
            LogCenter.shared.error("保存配置失败：\(error.localizedDescription)")
        }
    }

    private func runInBackground<T>(_ work: @escaping () -> T, completion: @escaping (T) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let value = work()
            DispatchQueue.main.async { completion(value) }
        }
    }
}

// MARK: - 格式化

enum ByteFormatter {
    static func string(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        return formatter.string(fromByteCount: bytes)
    }

    static func short(_ bytes: Int64) -> String {
        string(bytes)
    }
}

enum DateFormatterCache {
    static let short: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss"
        return f
    }()

    static let full: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return f
    }()
}
