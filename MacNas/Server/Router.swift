//
//  Router.swift
//  MacNas
//
//  路由：网页静态资源 + 登录 + 文件管理 API。
//  账号密码、端口只能在 macOS 软件里修改，网页端没有任何修改入口。
//

import Foundation

/// 供路由查询当前运行状态（端口 / 账号 / 启动时间）
final class ServerEnvironment: @unchecked Sendable {
    private let lock = NSLock()
    private var _port: UInt16 = 0
    private var _startedAt: Date?
    private var _version: String = MacNasInfo.version
    private var _webdavEnabled: Bool = true
    private var _webdavReadOnly: Bool = false
    /// 是否把 WebDAV 请求的原始头部写进日志（默认开，方便排查挂载问题）
    var webdavTraceRawRequests: Bool = true
    /// 回收站保留天数（仅用于展示与自动清理）
    var trashRetentionDays: Int = 30

    /// 允许跨域调用 API 的来源白名单（空 = 完全不开 CORS）
    private var _apiCorsOrigins: [String] = []
    func setAPICORSOrigins(_ origins: [String]) {
        lock.lock()
        _apiCorsOrigins = origins
        lock.unlock()
    }
    var apiCorsOrigins: [String] {
        lock.lock()
        defer { lock.unlock() }
        return _apiCorsOrigins
    }

    /// 最近一次 WebDAV 客户端请求（用于「系统信息」里直接看到挂载方到底发了什么）
    private var _webdavLastClient: String = ""
    private var _webdavLastRequest: String = ""
    private var _webdavLastStatus: Int = 0
    private var _webdavLastTime: Date?

    func recordWebDAV(client: String, method: String, path: String, status: Int) {
        lock.lock()
        _webdavLastClient = client
        _webdavLastRequest = "\(method) \(path)"
        _webdavLastStatus = status
        _webdavLastTime = Date()
        lock.unlock()
    }

    var webdavLastActivity: [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        var payload: [String: Any] = [:]
        if !_webdavLastClient.isEmpty { payload["client"] = _webdavLastClient }
        if !_webdavLastRequest.isEmpty { payload["request"] = _webdavLastRequest }
        if _webdavLastStatus != 0 { payload["status"] = _webdavLastStatus }
        if let time = _webdavLastTime { payload["at"] = ISO8601.string(time) }
        return payload
    }

    /// 供「系统信息」显示的统计：WebDAV 一共被请求过多少次、有多少次没带凭据
    private var _webdavRequestCount = 0
    private var _webdavUnauthorizedCount = 0

    func recordWebDAVRequest(authorized: Bool) {
        lock.lock()
        _webdavRequestCount += 1
        if !authorized { _webdavUnauthorizedCount += 1 }
        lock.unlock()
    }

    var webdavCounters: (total: Int, unauthorized: Int) {
        lock.lock()
        defer { lock.unlock() }
        return (_webdavRequestCount, _webdavUnauthorizedCount)
    }

    var port: UInt16 {
        get { lock.lock(); defer { lock.unlock() }; return _port }
        set { lock.lock(); _port = newValue; lock.unlock() }
    }

    var startedAt: Date? {
        get { lock.lock(); defer { lock.unlock() }; return _startedAt }
        set { lock.lock(); _startedAt = newValue; lock.unlock() }
    }

    var version: String {
        get { lock.lock(); defer { lock.unlock() }; return _version }
        set { lock.lock(); _version = newValue; lock.unlock() }
    }

    var webdavEnabled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _webdavEnabled }
        set { lock.lock(); _webdavEnabled = newValue; lock.unlock() }
    }

    var webdavReadOnly: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _webdavReadOnly }
        set { lock.lock(); _webdavReadOnly = newValue; lock.unlock() }
    }
}

enum MacNasInfo {
    static let version = "1.0"
    static let displayName = "MacNas"
}

final class Router: HTTPRequestHandler {

    private let store: Store
    private let auth: AuthManager
    private let shares: ShareStore
    private let webdav: WebDAVHandler
    private let assets = WebAssets()
    private let uploadsDirectory: URL
    private let environment: ServerEnvironment
    /// 第三方开发者用的 API Key
    let apiKeys: APIKeyStore
    private var apiKeysFile = true   // 保留字段便于将来热切换

    init(store: Store, auth: AuthManager, environment: ServerEnvironment, shares: ShareStore,
         apiKeys: APIKeyStore = APIKeyStore()) {
        self.store = store
        self.auth = auth
        self.environment = environment
        self.shares = shares
        self.apiKeys = apiKeys
        self.webdav = WebDAVHandler(store: store, auth: auth, environment: environment)
        self.uploadsDirectory = AppPaths.uploadsDirectory
    }

    // MARK: - 请求体

    func makeBodySink(for head: HTTPRequestHead, tempDirectory: URL) throws -> BodySink? {
        // WebDAV 上传同样流式落盘 + 边收边算哈希
        if head.method == "PUT", WebDAVHandler.isWebDAVPath(head.path), head.contentLength > 0 {
            let tempURL = tempDirectory.appendingPathComponent("dav-\(UUID().uuidString).part")
            return try UploadBodySink(tempURL: tempURL)
        }
        if head.method == "POST", head.path == "/api/upload" {
            let tempURL = tempDirectory.appendingPathComponent("upload-\(UUID().uuidString).part")
            return try UploadBodySink(tempURL: tempURL)
        }
        // 第三方 API 上传：同样流式落盘 + 边收边算哈希
        if head.method == "POST", head.path == "/api/v1/files/upload" {
            let tempURL = tempDirectory.appendingPathComponent("api-\(UUID().uuidString).part")
            return try UploadBodySink(tempURL: tempURL)
        }
        // 照片收集：访客上传也走流式落盘（免登录，但要受收集链接的额度约束）
        if head.method == "POST", head.path.hasPrefix("/api/pub/"), head.path.hasSuffix("/upload") {
            let tempURL = tempDirectory.appendingPathComponent("collect-\(UUID().uuidString).part")
            return try UploadBodySink(tempURL: tempURL)
        }
        if head.contentLength > 0 {
            return MemoryBodySink(limit: 4 * 1024 * 1024)
        }
        return nil
    }

    // MARK: - 入口

    func handle(_ request: HTTPRequest) -> HTTPResponse {
        let started = Date()
        let response: HTTPResponse
        do {
            response = try route(request)
        } catch let error as HTTPError {
            response = .failure(error.status, error.message)
        } catch let error as PreviewError {
            return .failure(500, "预览失败：" + (error.errorDescription ?? "未知错误"))
        } catch let error as StoreError {
            response = .failure(Self.status(for: error), error.localizedDescription)
        } catch {
            response = .failure(500, "服务器内部错误：\(error.localizedDescription)")
        }
        log(request, response, started)
        return response
    }

    private static func status(for error: StoreError) -> Int {
        switch error {
        case .volumeNotFound, .notFound: return 404
        case .volumeUnavailable: return 503
        case .readOnly: return 409
        case .invalidPath, .invalidName: return 400
        case .conflict: return 409
        case .io: return 500
        }
    }

    // MARK: - 路由

    private func route(_ request: HTTPRequest) throws -> HTTPResponse {
        let path = request.path

        // WebDAV：Finder 挂载用（Basic 认证 + /dav 下的逻辑目录树）
        if WebDAVHandler.isWebDAVPath(path) {
            return webdav.handle(request)
        }

        // 直接挂在服务器根（http://ip:端口）也支持：只对这些「只有 WebDAV 会用」的方法生效，
        // GET / 仍然是网页。这样万一用户没在地址后面写 /dav，也不会莫名其妙挂不上。
        if path == "/", WebDAVHandler.webdavOnlyMethods.contains(request.method) {
            return webdav.handle(request)
        }

        // 第三方 API：/api/v1/*（Bearer 鉴权）与 /api/admin/keys（只允许已登录会话）
        if path == "/api/v1" || path.hasPrefix("/api/v1/") || path.hasPrefix("/api/admin/keys") {
            return try handleAPI(request)
        }
        // 跨域预检：只有在软件里配置了允许的来源才应答，默认一律不响应 CORS
        if request.method == "OPTIONS", let origin = request.headers["origin"], path.hasPrefix("/api/") {
            if let allowed = allowedCORSOrigin(origin) {
                var response = HTTPResponse(status: 204, body: .empty)
                response.headers["Access-Control-Allow-Origin"] = allowed
                response.headers["Access-Control-Allow-Methods"] = "GET, POST, DELETE, OPTIONS"
                response.headers["Access-Control-Allow-Headers"] = "Authorization, Content-Type, X-API-Key"
                response.headers["Access-Control-Max-Age"] = "600"
                return response
            }
            return .failure(403, "这个来源没有在软件里被允许跨域访问")
        }

        // OPTIONS：服务级能力查询（WebDAV 客户端会先发 OPTIONS，路径可能是 * 或任意前缀）
        if request.method == "OPTIONS" {
            var response = HTTPResponse(status: 200, body: .empty)
            response.headers["DAV"] = "1, 2, 3"
            response.headers["Allow"] = "OPTIONS, GET, HEAD, PUT, DELETE, PROPFIND, PROPPATCH, MKCOL, COPY, MOVE, LOCK, UNLOCK"
            response.headers["MS-Author-Via"] = "DAV"
            response.headers["Accept-Ranges"] = "bytes"
            return response
        }

        // 分享页：仍是同一个网页，由前端根据 /s/<token> 渲染成分享视图
        if request.method == "GET" || request.method == "HEAD" {
            if path.hasPrefix("/s/") { return try serveAsset(request, name: "index.html") }
            switch path {
            case "/", "/index.html": return try serveAsset(request, name: "index.html")
            case "/app.js": return try serveAsset(request, name: "app.js")
            case "/styles.css": return try serveAsset(request, name: "styles.css")
            case "/logo.png": return try serveAsset(request, name: "logo.png")
            // PWA：可安装到主屏 + 离线外壳
            case "/manifest.webmanifest": return try serveAsset(request, name: "manifest.webmanifest")
            case "/sw.js": return try serveAsset(request, name: "sw.js")
            default: break
            }
        }

        switch path {
        case "/api/login":
            guard request.method == "POST" else { throw HTTPError(status: 405, message: "方法不允许") }
            return try handleLogin(request)
        case "/api/session":
            return handleSession(request)
        case "/api/logout":
            auth.logout(token: request.cookies[AuthManager.cookieName])
            return handleSession(request)
        default:
            break
        }

        // 凭分享链接匿名访问（不需要登录）
        if path.hasPrefix("/api/pub/") {
            return try handlePublicShare(request)
        }

        guard path.hasPrefix("/api/") else {
            throw HTTPError(status: 404, message: "页面不存在")
        }
        guard auth.validate(token: request.cookies[AuthManager.cookieName]) else {
            throw HTTPError(status: 401, message: "登录状态已失效，请重新登录")
        }

        switch path {
        case "/api/status": return handleStatus()
        case "/api/volumes": return handleVolumes()
        case "/api/list": return try handleList(request)
        case "/api/search": return handleSearch(request)
        case "/api/upload": return try handleUpload(request)
        case "/api/download": return try handleDownload(request)
        case "/api/trash": return try handleTrashList(request)
        case "/api/trash/restore": return try handleTrashRestore(request)
        case "/api/trash/purge": return try handleTrashPurge(request)
        case "/api/trash/empty": return try handleTrashEmpty(request)
        case "/api/versions": return try handleVersions(request)
        case "/api/versions/restore": return try handleVersionRestore(request)
        case "/api/versions/download": return try handleVersionDownload(request)
        case "/api/volume/compact": return try handleCompact(request)
        case "/api/analytics": return try handleAnalytics(request)
        case "/api/zip": return try handleZip(request)
        case "/api/has": return try handleHas(request)
        case "/api/register": return try handleRegister(request)
        case "/api/thumbnail": return try handleThumbnail(request)
        case "/api/media": return try handleMedia(request)
        case "/api/preview": return try handlePreview(request)
        case "/api/preview/content": return try handlePreviewContent(request)
        case "/api/mkdir": return try handleMkdir(request)
        case "/api/rename": return try handleRenameEntry(request)
        case "/api/rename-folder": return try handleRenameFolder(request)
        case "/api/delete": return try handleDelete(request)
        case "/api/delete-batch": return try handleDeleteBatch(request)
        case "/api/transfer": return try handleTransfer(request)
        case "/api/share/create": return try handleShareCreate(request)
        case "/api/shares": return handleShareList()
        case "/api/share/revoke": return try handleShareRevoke(request)
        default: throw HTTPError(status: 404, message: "接口不存在")
        }
    }

    // MARK: - 静态资源

    private func serveAsset(_ request: HTTPRequest, name: String) throws -> HTTPResponse {
        let isIndex = name == "index.html"
        guard var asset = isIndex ? assets.fingerprintedIndex() : assets.asset(named: name) else {
            throw HTTPError(status: 404, message: "缺少网页资源：\(name)")
        }
        if isIndex, asset.data.isEmpty { asset = assets.asset(named: name) ?? asset }
        if let noneMatch = request.headers["if-none-match"], noneMatch.contains(asset.etag) {
            var response = HTTPResponse(status: 304, body: .empty)
            response.headers["ETag"] = asset.etag
            response.headers["Cache-Control"] = "no-cache"
            return response
        }
        var response = HTTPResponse(status: 200, body: .data(asset.data))
        response.headers["Content-Type"] = asset.contentType
        response.headers["ETag"] = asset.etag
        // sw.js 必须每次都回源检查：它是唯一能触发 Service Worker 更新的文件
        response.headers["Cache-Control"] = name == "sw.js" ? "no-store" : "no-cache"
        return response
    }

    // MARK: - 登录

    private func handleLogin(_ request: HTTPRequest) throws -> HTTPResponse {
        guard let body = request.jsonBody else {
            throw HTTPError(status: 400, message: "请求格式错误")
        }
        let username = (body["username"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let password = body["password"] as? String ?? ""

        guard let token = auth.login(username: username, password: password) else {
            LogCenter.shared.warn("网页登录失败：\(username.isEmpty ? "(空账号)" : username) ← \(request.remoteAddress)")
            throw HTTPError(status: 401, message: "账号或密码错误")
        }
        LogCenter.shared.info("网页登录成功：\(username) ← \(request.remoteAddress)")

        var response = HTTPResponse.json(["ok": true, "username": username])
        response.headers["Set-Cookie"] = "\(AuthManager.cookieName)=\(token); Path=/; Max-Age=604800; HttpOnly; SameSite=Lax"
        return response
    }

    private func handleSession(_ request: HTTPRequest) -> HTTPResponse {
        let token = request.cookies[AuthManager.cookieName]
        let authenticated = auth.validate(token: token)
        return .json([
            "ok": true,
            "authenticated": authenticated,
            "username": authenticated ? auth.currentUsername : ""
        ])
    }

    // MARK: - 状态 / 目录

    private func handleStatus() -> HTTPResponse {
        let stats = store.stats()
        var payload: [String: Any] = [
            "ok": true,
            "version": environment.version,
            "formatVersion": DiskSchema.currentVersion,
            "port": Int(environment.port),
            "username": auth.currentUsername,
            "volumeCount": stats.volumeCount,
            "readOnlyVolumes": stats.volumeStats.filter { $0.readOnly }.count,
            "shareCount": shares.count(),
            "trashCount": store.trashCount(),
            "webdavLast": environment.webdavLastActivity,
            "webdavRequests": environment.webdavCounters.total,
            "webdavUnauthorized": environment.webdavCounters.unauthorized,
            "trashRetentionDays": environment.trashRetentionDays,
            "fileCount": stats.fileCount,
            "uniqueBlobCount": stats.uniqueBlobCount,
            "physicalBytes": stats.physicalBytes,
            "logicalBytes": stats.logicalBytes,
            "savedBytes": stats.savedBytes
        ]
        if let startedAt = environment.startedAt {
            payload["startedAt"] = ISO8601.string(startedAt)
        }
        return .json(payload)
    }

    private func handleVolumes() -> HTTPResponse {
        let stats = store.stats()
        let volumes = store.volumeList()
        let list: [[String: Any]] = volumes.map { volume in
            let volumeStats = stats.volumeStats.first(where: { $0.volumeId == volume.id })
            var item: [String: Any] = [
                "id": volume.id,
                "name": volume.name,
                "path": volume.path,
                "available": volume.isPrepared,
                "fileCount": volumeStats?.fileCount ?? 0,
                "physicalBytes": volumeStats?.physicalBytes ?? 0,
                "logicalBytes": volumeStats?.logicalBytes ?? 0,
                "readOnly": volumeStats?.readOnly ?? false,
                "rebuilt": volumeStats?.rebuilt ?? false
            ]
            if let values = try? URL(fileURLWithPath: volume.path).resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey]) {
                if let available = values.volumeAvailableCapacityForImportantUsage {
                    item["freeBytes"] = available
                }
                if let total = values.volumeTotalCapacity {
                    item["totalBytes"] = total
                }
            }
            return item
        }
        return .json(["ok": true, "volumes": list])
    }

    private func handleList(_ request: HTTPRequest) throws -> HTTPResponse {
        let volumeId = try requireQuery(request, "volume")
        let path = request.query["path"] ?? LogicalPath.root
        let listing = try store.list(volumeId: volumeId, path: path)
        let facts = store.dedupFacts()

        let folders: [[String: Any]] = listing.folders.map { folder in
            ["name": folder.name, "path": folder.path, "fileCount": folder.fileCount]
        }
        let files: [[String: Any]] = listing.files.map { entry in
            Self.filePayload(entry, facts: facts)
        }
        return .json([
            "ok": true,
            "path": listing.path,
            "breadcrumbs": Self.breadcrumbs(for: listing.path),
            "folders": folders,
            "files": files
        ])
    }

    private static func filePayload(_ entry: FileEntry,
                                    facts: (counts: [String: Int], owners: [String: Store.BlobLocation])) -> [String: Any] {
        var payload: [String: Any] = [
            "id": entry.id,
            "name": entry.name,
            "size": entry.size,
            "sha256": entry.sha256,
            "createdAt": ISO8601.string(entry.createdAt),
            "path": entry.logicalPath,
            "mime": MimeTypes.guess(forFileName: entry.name),
            "isImage": MimeTypes.isImage(entry.name)
        ]
        let refCount = facts.counts[entry.sha256] ?? 1
        payload["refCount"] = refCount
        payload["deduplicated"] = refCount > 1
        if let owner = facts.owners[entry.sha256] {
            payload["storageVolumeId"] = owner.volumeId
            payload["storedIn"] = entry.storageRelPath
        }
        return payload
    }

    private static func breadcrumbs(for path: String) -> [[String: Any]] {
        var items: [[String: Any]] = [["name": "根目录", "path": LogicalPath.root]]
        var current = LogicalPath.root
        for segment in LogicalPath.segments(path) {
            current = LogicalPath.join(current, segment)
            items.append(["name": segment, "path": current])
        }
        return items
    }

    // MARK: - 全局搜索

    private func handleSearch(_ request: HTTPRequest) -> HTTPResponse {
        let query = (request.query["q"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let volumeId = (request.query["volume"] ?? "").isEmpty ? nil : request.query["volume"]
        let limit = min(500, max(1, Int(request.query["limit"] ?? "") ?? 200))

        guard !query.isEmpty else {
            return .json(["ok": true, "query": "", "total": 0, "hits": [], "truncated": false])
        }

        let result = store.search(query: query, volumeId: volumeId, limit: limit)
        let hits: [[String: Any]] = result.hits.map { hit in
            var payload: [String: Any] = [
                "kind": hit.kind,
                "name": hit.name,
                "path": hit.logicalPath,
                "parent": LogicalPath.parent(hit.logicalPath),
                "volumeId": hit.volumeId,
                "volumeName": hit.volumeName,
                "size": hit.size,
                "fileCount": hit.fileCount
            ]
            if let entryId = hit.entryId { payload["id"] = entryId }
            if let createdAt = hit.createdAt { payload["createdAt"] = ISO8601.string(createdAt) }
            if hit.kind == "file" {
                payload["mime"] = MimeTypes.guess(forFileName: hit.name)
                payload["isImage"] = MimeTypes.isImage(hit.name)
            }
            return payload
        }
        return .json([
            "ok": true,
            "query": query,
            "total": result.total,
            "returned": hits.count,
            "truncated": result.total > hits.count,
            "hits": hits
        ])
    }

    // MARK: - 上传

    private func handleUpload(_ request: HTTPRequest) throws -> HTTPResponse {
        guard case .file(let tempURL, let sha256, let byteCount) = request.body else {
            throw HTTPError(status: 400, message: "上传请求格式错误")
        }
        let volumeId = try requireQuery(request, "volume")
        try store.ensureWritable(volumeId: volumeId)
        let directory = request.query["path"] ?? LogicalPath.root
        let name = request.query["name"] ?? "未命名文件"
        let overwrite = (request.query["overwrite"] ?? "") == "1"

        do {
            let result = try store.commitUpload(volumeId: volumeId,
                                                directory: directory,
                                                fileName: name,
                                                sha256: sha256,
                                                size: byteCount,
                                                tempFileURL: tempURL,
                                                overwrite: overwrite)
            let facts = store.dedupFacts()
            return .json([
                "ok": true,
                "outcome": result.outcome.rawValue,
                "savedBytes": result.outcome == .deduplicated ? byteCount : 0,
                "file": Self.filePayload(result.entry, facts: facts)
            ])
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }
    }

    // MARK: - 下载

    private func handleDownload(_ request: HTTPRequest) throws -> HTTPResponse {
        let volumeId = try requireQuery(request, "volume")
        let entryId = try requireQuery(request, "id")
        return try makeDownloadResponse(request, volumeId: volumeId, entryId: entryId,
                                        inline: (request.query["inline"] ?? "") == "1")
    }

    /// 下载响应的公共实现（登录下载、分享下载、WebDAV 都走这里）
    private func makeDownloadResponse(_ request: HTTPRequest,
                                      volumeId: String,
                                      entryId: String,
                                      inline: Bool) throws -> HTTPResponse {
        let (entry, url) = try store.resolveEntry(volumeId: volumeId, entryId: entryId)
        LogCenter.shared.info("下载：\(entry.name)（\(entry.size) 字节）← \(request.remoteAddress)")
        return FileResponse.make(request, entry: entry, url: url, inline: inline)
    }

    // MARK: - 文件夹 / 重命名 / 删除

    private func handleMkdir(_ request: HTTPRequest) throws -> HTTPResponse {
        let volumeId = try writableVolumeID(request)
        let path = request.jsonString("path") ?? LogicalPath.root
        let name = try requireBody(request, "name")
        let created = try store.createFolder(volumeId: volumeId, path: path, name: name)
        return .json(["ok": true, "path": created])
    }

    private func handleRenameEntry(_ request: HTTPRequest) throws -> HTTPResponse {
        let volumeId = try writableVolumeID(request)
        let entryId = try requireBody(request, "id")
        let name = try requireBody(request, "name")
        try store.renameEntry(volumeId: volumeId, entryId: entryId, newName: name)
        return .ok(message: "已重命名")
    }

    private func handleRenameFolder(_ request: HTTPRequest) throws -> HTTPResponse {
        let volumeId = try writableVolumeID(request)
        let path = try requireBody(request, "path")
        let name = try requireBody(request, "name")
        let target = try store.renameFolder(volumeId: volumeId, path: path, newName: name)
        return .json(["ok": true, "path": target])
    }

    private func handleDelete(_ request: HTTPRequest) throws -> HTTPResponse {
        let volumeId = try writableVolumeID(request)
        if let entryId = request.jsonString("id"), !entryId.isEmpty {
            try store.deleteEntry(volumeId: volumeId, entryId: entryId)
            return .ok(message: "已删除")
        }
        if let path = request.jsonString("path"), !path.isEmpty {
            let count = try store.deleteFolder(volumeId: volumeId, path: path)
            return .json(["ok": true, "deleted": count])
        }
        throw HTTPError(status: 400, message: "缺少删除目标")
    }

    private func handleDeleteBatch(_ request: HTTPRequest) throws -> HTTPResponse {
        let volumeId = try writableVolumeID(request)
        guard let body = request.jsonBody, let ids = body["ids"] as? [String], !ids.isEmpty else {
            throw HTTPError(status: 400, message: "缺少删除目标")
        }
        var deleted = 0
        var firstError: Error?
        for id in ids {
            do {
                try store.deleteEntry(volumeId: volumeId, entryId: id)
                deleted += 1
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        // 一条都没删掉 → 如实返回错误，不要假装成功
        if deleted == 0, let firstError { throw firstError }
        return .json(["ok": true, "deleted": deleted, "failed": ids.count - deleted])
    }

    /// 拖拽移动 / 复制（可跨目录）
    private func handleTransfer(_ request: HTTPRequest) throws -> HTTPResponse {
        let fromVolume = try requireBody(request, "fromVolume")
        let toVolume = try requireBody(request, "toVolume")
        let toPath = request.jsonString("toPath") ?? LogicalPath.root
        let copy = (request.jsonString("mode") ?? "move") == "copy"
        let body = request.jsonBody ?? [:]
        let ids = (body["ids"] as? [String]) ?? []
        let paths = (body["paths"] as? [String]) ?? []
        guard !ids.isEmpty || !paths.isEmpty else {
            throw HTTPError(status: 400, message: "没有要搬运的内容")
        }
        try store.ensureWritable(volumeId: toVolume)
        let summary = try store.transfer(fromVolumeId: fromVolume,
                                         entryIds: ids,
                                         folderPaths: paths,
                                         toVolumeId: toVolume,
                                         toPath: toPath,
                                         copy: copy)
        return .json([
            "ok": true,
            "mode": copy ? "copy" : "move",
            "moved": summary.moved,
            "copied": summary.copied,
            "renamed": summary.renamed
        ])
    }

    // MARK: - 分享链接（管理）

    private func publicBaseURL() -> String {
        let port = environment.port
        if let ip = NetworkInfo.primaryIPv4Address() { return "http://\(ip):\(port)" }
        return "http://127.0.0.1:\(port)"
    }

    private static func displayName(for path: String, fallback: String) -> String {
        let normalized = LogicalPath.normalize(path)
        return normalized == LogicalPath.root ? fallback : LogicalPath.lastSegment(normalized)
    }

    private static func sharePayload(_ record: ShareRecord,
                                     status: String,
                                     note: String = "",
                                     baseURL: String) -> [String: Any] {
        var payload: [String: Any] = [
            "token": record.token,
            "path": "/s/" + record.token,
            "url": baseURL + "/s/" + record.token,
            "name": record.name,
            "kind": record.kind,
            "type": record.typeText,
            "volumeId": record.volumeId,
            "logicalPath": record.logicalPath,
            "createdAt": ISO8601.string(record.createdAt),
            "hasPassword": record.hasPassword,
            "visits": record.visits,
            "downloads": record.downloads,
            "status": status,
            "permanent": record.expiresAt == nil
        ]
        if let expiresAt = record.expiresAt { payload["expiresAt"] = ISO8601.string(expiresAt) }
        if !note.isEmpty { payload["note"] = note }
        if record.isCollect {
            payload["collect"] = true
            payload["uploadedCount"] = record.uploadedCount
            payload["uploadedBytes"] = record.uploadedBytes
            payload["maxFileBytes"] = record.maxFileBytes
            payload["maxTotalBytes"] = record.maxTotalBytes
            payload["imagesOnly"] = record.imagesOnly
            if let remaining = record.remainingBytes { payload["remainingBytes"] = remaining }
        }
        return payload
    }

    private func handleShareCreate(_ request: HTTPRequest) throws -> HTTPResponse {
        let volumeId = try requireBody(request, "volume")
        guard let volume = store.volume(id: volumeId) else { throw StoreError.volumeNotFound }
        let password = request.jsonString("password") ?? ""
        let hours = (request.jsonBody?["expiresInHours"] as? Int) ?? 168

        let kind: String
        let entryId: String?
        let logicalPath: String
        let name: String

        // 照片收集：目标是一个文件夹（不存在就建），访客只能上传、不能浏览
        if request.jsonString("collect") != nil || (request.jsonString("kind") ?? "") == "collect" {
            let folderName = (request.jsonString("name") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            var target = LogicalPath.normalize(request.jsonString("path") ?? LogicalPath.root)
            let display = folderName.isEmpty ? (LogicalPath.lastSegment(target).isEmpty ? "照片收集" : LogicalPath.lastSegment(target) + "（收集）") : folderName
            if !(store.folderExists(volumeId: volumeId, path: target) || target == LogicalPath.root) {
                // 路径不存在时按「根目录 + 新文件夹名」处理
                let base = LogicalPath.parent(target)
                let leaf = LogicalPath.lastSegment(target)
                if base == LogicalPath.root, !leaf.isEmpty {
                    _ = try? store.createFolder(volumeId: volumeId, path: LogicalPath.root, name: leaf)
                    target = LogicalPath.join(LogicalPath.root, leaf)
                } else {
                    target = LogicalPath.root
                }
            }
            let maxFileMB = (request.jsonBody?["maxFileMB"] as? Int) ?? 20
            let maxTotalMB = (request.jsonBody?["maxTotalMB"] as? Int) ?? 2048
            let imagesOnly = request.jsonBool("imagesOnly") ?? true
            let record = shares.create(volumeId: volumeId,
                                       kind: "collect",
                                       entryId: nil,
                                       logicalPath: target,
                                       name: display,
                                       expiresInHours: hours,
                                       password: password,
                                       maxFileBytes: Int64(maxFileMB) * 1024 * 1024,
                                       maxTotalBytes: Int64(maxTotalMB) * 1024 * 1024,
                                       imagesOnly: imagesOnly)
            return .json(["ok": true, "share": Self.sharePayload(record, status: "valid", baseURL: publicBaseURL())])
        }

        if let id = request.jsonString("id"), !id.isEmpty {
            guard let entry = store.entry(volumeId: volumeId, entryId: id) else {
                throw StoreError.notFound("文件不存在")
            }
            kind = "file"
            entryId = id
            logicalPath = entry.logicalPath
            name = entry.name
        } else {
            let normalized = LogicalPath.normalize(request.jsonString("path") ?? LogicalPath.root)
            guard store.folderExists(volumeId: volumeId, path: normalized) else {
                throw StoreError.notFound("文件夹不存在")
            }
            kind = "folder"
            entryId = nil
            logicalPath = normalized
            name = Self.displayName(for: normalized, fallback: volume.name)
        }

        let record = shares.create(volumeId: volumeId,
                                   kind: kind,
                                   entryId: entryId,
                                   logicalPath: logicalPath,
                                   name: name,
                                   expiresInHours: hours,
                                   password: password)
        return .json(["ok": true, "share": Self.sharePayload(record, status: "valid", baseURL: publicBaseURL())])
    }

    private func handleShareList() -> HTTPResponse {
        let payloads = shares.all().map { record -> [String: Any] in
            var status = "valid"
            var note = ""
            if !record.enabled {
                status = "revoked"
                note = "已取消"
            } else if record.isExpired() {
                status = "expired"
                note = "已过期"
            } else if store.volume(id: record.volumeId) == nil {
                status = "broken"
                note = "目录已被移除"
            } else if record.isCollect {
                if !store.folderExists(volumeId: record.volumeId, path: record.logicalPath)
                    && record.logicalPath != LogicalPath.root {
                    status = "broken"
                    note = "目标文件夹已被删除"
                } else if record.quotaReached {
                    status = "full"
                    note = "已收满"
                }
            } else if record.isFolder {
                if !store.folderExists(volumeId: record.volumeId, path: record.logicalPath) {
                    status = "broken"
                    note = "文件夹已被删除"
                }
            } else if let entryId = record.entryId,
                      store.entry(volumeId: record.volumeId, entryId: entryId) == nil {
                status = "broken"
                note = "文件已被删除"
            }
            return Self.sharePayload(record, status: status, note: note, baseURL: publicBaseURL())
        }
        return .json(["ok": true, "shares": payloads])
    }

    private func handleShareRevoke(_ request: HTTPRequest) throws -> HTTPResponse {
        let token = try requireBody(request, "token")
        guard shares.revoke(token: token) else { throw StoreError.notFound("分享不存在") }
        return .ok(message: "已取消分享")
    }

    // MARK: - 分享链接（匿名访问）

    private func handlePublicShare(_ request: HTTPRequest) throws -> HTTPResponse {
        let rest = String(request.path.dropFirst("/api/pub/".count))
        let parts = rest.split(separator: "/").map(String.init)
        guard let token = parts.first, !token.isEmpty else {
            throw HTTPError(status: 404, message: "分享链接不存在")
        }
        guard let share = shares.find(token: token) else {
            throw HTTPError(status: 404, message: "分享链接不存在或已被取消")
        }
        guard share.enabled else { throw HTTPError(status: 410, message: "该分享已被取消") }
        guard !share.isExpired() else { throw HTTPError(status: 410, message: "该分享已过期") }

        // 注意：动作可能是多段的（例如 preview/content），所以要拼回来看，
        // 只取 parts[1] 会把 preview/content 误判成 preview。
        let action = parts.dropFirst().joined(separator: "/")
        switch action {
        case "":
            if share.isCollect { return try publicCollectInfo(request, share: share) }
            return try publicShareInfo(request, share: share)
        case "auth": return try publicShareAuth(request, share: share)
        case "download": return try publicShareDownload(request, share: share)
        case "preview": return try publicSharePreview(request, share: share)
        case "preview/content": return try publicSharePreviewContent(request, share: share)
        case "upload": return try publicCollectUpload(request, share: share)
        default: throw HTTPError(status: 404, message: "接口不存在")
        }
    }

    private func shareUnlocked(_ request: HTTPRequest, share: ShareRecord) -> Bool {
        guard share.hasPassword, let expected = share.passwordCookieValue else { return true }
        return PasswordHasher.constantTimeEquals(request.cookies["macnas_share_" + share.token] ?? "", expected)
    }

    private func isInside(_ path: String, root: String) -> Bool {
        let target = LogicalPath.normalize(path)
        let base = LogicalPath.normalize(root)
        return target == base || LogicalPath.isDescendant(target, of: base)
    }

    private static func shareBreadcrumbs(root: String, path: String, rootName: String) -> [[String: Any]] {
        var items: [[String: Any]] = [["name": rootName, "path": root]]
        guard path != root else { return items }
        var current = root
        let rootDepth = LogicalPath.depth(root)
        for (index, segment) in LogicalPath.segments(path).enumerated() where index >= rootDepth {
            current = LogicalPath.join(current, segment)
            items.append(["name": segment, "path": current])
        }
        return items
    }

    private func publicShareInfo(_ request: HTTPRequest, share: ShareRecord) throws -> HTTPResponse {
        guard shareUnlocked(request, share: share) else {
            return .json([
                "ok": true,
                "needsPassword": true,
                "name": share.name,
                "kind": share.kind,
                "type": share.typeText
            ])
        }
        shares.recordVisit(token: share.token)

        var payload: [String: Any] = [
            "ok": true,
            "needsPassword": false,
            "name": share.name,
            "kind": share.kind,
            "type": share.typeText,
            "createdAt": ISO8601.string(share.createdAt),
            "permanent": share.expiresAt == nil
        ]
        if let expiresAt = share.expiresAt { payload["expiresAt"] = ISO8601.string(expiresAt) }

        guard let volume = store.volume(id: share.volumeId) else {
            throw HTTPError(status: 404, message: "分享的目录已被移除")
        }
        payload["volumeName"] = volume.name

        if share.isFolder {
            let requested = LogicalPath.normalize(request.query["path"] ?? share.logicalPath)
            guard isInside(requested, root: share.logicalPath) else {
                throw HTTPError(status: 403, message: "该路径不在分享范围内")
            }
            let listing = try store.list(volumeId: share.volumeId, path: requested)
            let facts = store.dedupFacts()
            payload["path"] = listing.path
            payload["root"] = share.logicalPath
            payload["crumbs"] = Self.shareBreadcrumbs(root: share.logicalPath,
                                                      path: listing.path,
                                                      rootName: share.name)
            payload["folders"] = listing.folders.map {
                ["name": $0.name, "path": $0.path, "fileCount": $0.fileCount] as [String: Any]
            }
            payload["files"] = listing.files.map { Self.filePayload($0, facts: facts) }
        } else {
            guard let entryId = share.entryId,
                  let entry = store.entry(volumeId: share.volumeId, entryId: entryId) else {
                throw HTTPError(status: 404, message: "分享的文件已被删除")
            }
            payload["files"] = [Self.filePayload(entry, facts: store.dedupFacts())]
            payload["path"] = entry.directory
        }
        return .json(payload)
    }

    private func publicShareAuth(_ request: HTTPRequest, share: ShareRecord) throws -> HTTPResponse {
        guard share.hasPassword else { return .json(["ok": true]) }
        let password = request.jsonString("password") ?? ""
        guard PasswordHasher.verify(password: password,
                                    saltHex: share.passwordSalt ?? "",
                                    expectedHex: share.passwordHash ?? "") else {
            LogCenter.shared.warn("分享「\(share.name)」密码错误 ← \(request.remoteAddress)")
            Thread.sleep(forTimeInterval: 0.4)
            throw HTTPError(status: 401, message: "密码不正确")
        }
        var response = HTTPResponse.json(["ok": true])
        if let value = share.passwordCookieValue {
            let maxAge = share.expiresAt.map { max(60, Int($0.timeIntervalSinceNow)) } ?? 604800
            response.headers["Set-Cookie"] = "macnas_share_\(share.token)=\(value); Path=/; Max-Age=\(maxAge); HttpOnly; SameSite=Lax"
        }
        LogCenter.shared.info("分享「\(share.name)」通过密码验证 ← \(request.remoteAddress)")
        return response
    }

    /// 收集链接的公开信息：只给访客看「要传到哪里、还能传多少」，**不列出已有文件**
    private func publicCollectInfo(_ request: HTTPRequest, share: ShareRecord) throws -> HTTPResponse {
        var payload: [String: Any] = [
            "ok": true,
            "collect": true,
            "token": share.token,
            "name": share.name,
            "uploadedCount": share.uploadedCount,
            "uploadedBytes": share.uploadedBytes,
            "maxFileBytes": share.maxFileBytes,
            "maxTotalBytes": share.maxTotalBytes,
            "imagesOnly": share.imagesOnly,
            "needsPassword": share.hasPassword,
            "unlocked": shareUnlocked(request, share: share),
            "quotaReached": share.quotaReached,
            "expiresAt": share.expiresAt.map { ISO8601.string($0) } as Any
        ]
        if let remaining = share.remainingBytes { payload["remainingBytes"] = remaining }
        return .json(payload)
    }

    /// 访客上传照片：走和网页端一样的流式落盘 + 去重管线
    private func publicCollectUpload(_ request: HTTPRequest, share: ShareRecord) throws -> HTTPResponse {
        guard share.isCollect else { throw HTTPError(status: 404, message: "这个链接不支持上传") }
        guard share.allowUpload else { throw HTTPError(status: 403, message: "这个收集链接已关闭上传") }
        guard shareUnlocked(request, share: share) else {
            throw HTTPError(status: 401, message: "需要先输入收集密码")
        }
        guard !share.quotaReached else {
            throw HTTPError(status: 507, message: "这个收集链接已经收满啦，谢谢参与")
        }
        let rawName = try requireQuery(request, "name")
        guard let clean = LogicalPath.sanitizedSegment(rawName) else {
            throw HTTPError(status: 400, message: "文件名不合法")
        }
        // 只收图片/视频时，按扩展名拦一下（挡掉误传与乱传）
        if share.imagesOnly {
            let ext = LogicalPath.fileExtension(for: clean).lowercased()
            let allowed: Set<String> = ["jpg", "jpeg", "png", "gif", "webp", "heic", "heif", "bmp", "tiff", "tif",
                                        "avif", "mp4", "m4v", "mov", "webm", "3gp", "mp3", "m4a", "wav", "flac"]
            guard allowed.contains(ext) else {
                throw HTTPError(status: 415, message: "这里只收照片和视频，其它文件请用别的办法发送")
            }
        }

        let tempURL: URL
        let sha256: String
        let size: Int64
        switch request.body {
        case .file(let url, let hash, let bytes):
            tempURL = url
            sha256 = hash
            size = bytes
        case .data(let data):
            sha256 = FileHash.sha256(of: data)
            size = Int64(data.count)
            tempURL = AppPaths.uploadsDirectory.appendingPathComponent("collect-\(UUID().uuidString).part")
            try? FileManager.default.createDirectory(at: AppPaths.uploadsDirectory, withIntermediateDirectories: true)
            try data.write(to: tempURL)
        case .none:
            throw HTTPError(status: 400, message: "没有收到文件内容")
        }

        // 额度检查（单文件 / 总量）
        if share.maxFileBytes > 0, size > share.maxFileBytes {
            try? FileManager.default.removeItem(at: tempURL)
            throw HTTPError(status: 413, message: "这个文件太大了（上限 \(share.maxFileBytes / 1024 / 1024)MB）")
        }
        if share.maxTotalBytes > 0, share.uploadedBytes + size > share.maxTotalBytes {
            try? FileManager.default.removeItem(at: tempURL)
            throw HTTPError(status: 507, message: "剩余空间不够了，收集链接就要收满啦")
        }

        let directory = share.logicalPath
        if directory != LogicalPath.root, !store.folderExists(volumeId: share.volumeId, path: directory) {
            try? FileManager.default.createDirectory(at: tempURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        }
        // 收集场景里重名非常常见（IMG_0001.HEIC、合影.png…），
        // 这里自动改名而不是报错，否则访客会一脸茫然
        var finalName = clean
        var attempt = 2
        while store.entry(volumeId: share.volumeId, logicalPath: LogicalPath.join(directory, finalName)) != nil {
            let ext = LogicalPath.fileExtension(for: clean)
            let base = ext.isEmpty ? clean : String(clean.dropLast(ext.count + 1))
            if attempt > 50 {
                finalName = base + "-" + String(UUID().uuidString.prefix(6)) + (ext.isEmpty ? "" : "." + ext)
                break
            }
            finalName = ext.isEmpty ? "\(base) (\(attempt))" : "\(base) (\(attempt)).\(ext)"
            attempt += 1
        }
        let result = try store.commitUpload(volumeId: share.volumeId,
                                            directory: directory,
                                            fileName: finalName,
                                            sha256: sha256,
                                            size: size,
                                            tempFileURL: tempURL,
                                            overwrite: false)
        shares.recordUpload(token: share.token, bytes: result.entry.size)
        LogCenter.shared.info("收集上传：\(result.entry.name)（\(size) 字节）→ \(share.name) ← \(request.remoteAddress)")
        let updated = shares.find(token: share.token)
        return .json([
            "ok": true,
            "name": result.entry.name,
            "size": result.entry.size,
            "outcome": result.outcome == .deduplicated ? "deduplicated" : "stored",
            "uploadedCount": updated?.uploadedCount ?? share.uploadedCount + 1,
            "remainingBytes": updated?.remainingBytes as Any
        ], status: 201)
    }

    private func publicShareDownload(_ request: HTTPRequest, share: ShareRecord) throws -> HTTPResponse {
        guard shareUnlocked(request, share: share) else {
            throw HTTPError(status: 401, message: "需要先输入分享密码")
        }
        let entryId = try requireQuery(request, "id")
        guard let entry = store.entry(volumeId: share.volumeId, entryId: entryId) else {
            throw HTTPError(status: 404, message: "文件不存在")
        }
        let allowed = share.isFolder ? isInside(entry.logicalPath, root: share.logicalPath) : (entry.id == share.entryId)
        guard allowed else {
            throw HTTPError(status: 403, message: "该文件不在分享范围内")
        }
        shares.recordDownload(token: share.token)
        LogCenter.shared.info("分享下载：\(entry.name) ← \(request.remoteAddress)")
        return try makeDownloadResponse(request,
                                        volumeId: share.volumeId,
                                        entryId: entryId,
                                        inline: (request.query["inline"] ?? "") == "1")
    }

    // MARK: - 回收站

    private func entryJSON(_ entry: FileEntry, volumeId: String) -> [String: Any] {
        var payload: [String: Any] = [
            "id": entry.id,
            "name": entry.name,
            "size": entry.size,
            "path": entry.logicalPath,
            "createdAt": ISO8601.string(entry.createdAt),
            "sha256": entry.sha256,
            "historyCount": entry.history.count
        ]
        if let trashedAt = entry.trashedAt { payload["trashedAt"] = ISO8601.string(trashedAt) }
        if let originalPath = entry.originalPath { payload["originalPath"] = originalPath }
        payload["volumeId"] = volumeId
        payload["volumeName"] = store.volumeName(id: volumeId)
        return payload
    }

    private func handleTrashList(_ request: HTTPRequest) throws -> HTTPResponse {
        let volumeId = try requireQuery(request, "volume")
        let items = store.trash(volumeId: volumeId)
        return .json([
            "ok": true,
            "retentionDays": environment.trashRetentionDays,
            "items": items.map { entryJSON($0, volumeId: volumeId) }
        ])
    }

    private func handleTrashRestore(_ request: HTTPRequest) throws -> HTTPResponse {
        let volumeId = try writableVolumeID(request)
        let entryId = try requireBody(request, "id")
        let path = try store.restoreEntry(volumeId: volumeId, entryId: entryId)
        LogCenter.shared.info("回收站还原：\(path)")
        return .json(["ok": true, "path": path])
    }

    private func handleTrashPurge(_ request: HTTPRequest) throws -> HTTPResponse {
        let volumeId = try writableVolumeID(request)
        let entryId = try requireBody(request, "id")
        try store.purgeEntry(volumeId: volumeId, entryId: entryId)
        return .json(["ok": true])
    }

    private func handleTrashEmpty(_ request: HTTPRequest) throws -> HTTPResponse {
        let volumeId = try writableVolumeID(request)
        let removed = try store.emptyTrash(volumeId: volumeId)
        return .json(["ok": true, "removed": removed])
    }

    // MARK: - 历史版本

    private func handleVersions(_ request: HTTPRequest) throws -> HTTPResponse {
        let volumeId = try requireQuery(request, "volume")
        let entryId = try requireQuery(request, "id")
        let versions = store.versions(volumeId: volumeId, entryId: entryId)
        let items: [[String: Any]] = versions.map { item in
            var payload: [String: Any] = [
                "sha256": item.version.sha256,
                "size": item.version.size,
                "name": item.name,
                "isCurrent": item.isCurrent,
                "createdAt": ISO8601.string(item.version.createdAt)
            ]
            if !item.isCurrent {
                payload["replacedAt"] = ISO8601.string(item.version.replacedAt)
                payload["download"] = "/api/versions/download?volume=" +
                    (volumeId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? volumeId) +
                    "&id=" + (entryId.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? entryId) +
                    "&sha256=" + item.version.sha256
            }
            return payload
        }
        return .json(["ok": true, "versions": items])
    }

    private func handleVersionRestore(_ request: HTTPRequest) throws -> HTTPResponse {
        let volumeId = try writableVolumeID(request)
        let entryId = try requireBody(request, "id")
        let sha256 = try requireBody(request, "sha256")
        try store.restoreVersion(volumeId: volumeId, entryId: entryId, sha256: sha256)
        return .json(["ok": true])
    }

    /// 下载某个历史版本的内容（内容本身仍在库里，不需要重新上传）
    private func handleVersionDownload(_ request: HTTPRequest) throws -> HTTPResponse {
        let volumeId = try requireQuery(request, "volume")
        let entryId = try requireQuery(request, "id")
        let sha256 = try requireQuery(request, "sha256")
        guard let url = store.blobURL(sha256: sha256) else {
            throw HTTPError(status: 404, message: "这个版本的内容已经不在库里了")
        }
        let versions = store.versions(volumeId: volumeId, entryId: entryId)
        guard let match = versions.first(where: { $0.version.sha256 == sha256 }) else {
            throw HTTPError(status: 404, message: "这个版本不属于该文件")
        }
        let entry = FileEntry(name: match.version.name ?? match.name,
                              sha256: sha256,
                              size: match.version.size,
                              logicalPath: "/" + (match.version.name ?? match.name),
                              storageVolumeId: "",
                              storageRelPath: "")
        return FileResponse.make(request, entry: entry, url: url, inline: false)
    }

    /// 整理索引：把追加日志压缩成一份完整 index.json（体积更小、单文件可读）
    private func handleCompact(_ request: HTTPRequest) throws -> HTTPResponse {
        let volumeId = try writableVolumeID(request)
        let result = try store.compactIndex(volumeId: volumeId)
        return .json(["ok": true, "entries": result.entries, "bytes": result.bytes])
    }


    // MARK: - 第三方开发者 API（v1）

    /// 调用方身份
    private struct APICaller {
        var keyId: String?
        var name: String
        var canWrite: Bool
        var viaSession: Bool
        /// 被限流时要直接返回的响应
        var rateLimited: HTTPResponse?
    }

    /// API 统一错误格式：{"error": {"code": ..., "message": ...}}
    private struct APIError: Error {
        var status: Int
        var code: String
        var message: String
    }

    private func apiFailure(_ error: APIError) -> HTTPResponse {
        .json(["error": ["code": error.code, "message": error.message]], status: error.status)
    }

    /// 允许跨域的来源（在软件里配置；为空表示完全不开 CORS）
    private func allowedCORSOrigin(_ origin: String) -> String? {
        let allowed = environment.apiCorsOrigins
        guard !allowed.isEmpty else { return nil }
        if allowed.contains("*") { return origin }
        return allowed.contains(origin) ? origin : nil
    }

    /// 找出调用者：优先 Authorization: Bearer <key> / X-API-Key，其次已登录的网页会话
    private func apiCaller(_ request: HTTPRequest) throws -> APICaller {
        var token: String?
        if let raw = request.headers["authorization"], raw.lowercased().hasPrefix("bearer ") {
            token = String(raw.dropFirst(7)).trimmingCharacters(in: .whitespaces)
        } else if let raw = request.headers["x-api-key"], !raw.isEmpty {
            token = raw.trimmingCharacters(in: .whitespaces)
        }
        if let token, !token.isEmpty {
            guard let record = apiKeys.find(plaintext: token) else {
                throw APIError(status: 401, code: "invalid_key",
                               message: "API Key 无效。请检查是否复制完整，或它是否已被撤销。")
            }
            guard record.enabled else {
                throw APIError(status: 403, code: "key_disabled", message: "这个 API Key 已被撤销。")
            }
            guard !record.isExpired else {
                throw APIError(status: 403, code: "key_expired", message: "这个 API Key 已过期。")
            }
            // 限流：按 key 分别计读写
            let writing = request.method != "GET" && request.method != "HEAD"
            if case .limited(let retry) = apiKeys.checkRate(record, writing: writing) {
                var response = apiFailure(APIError(status: 429, code: "rate_limited",
                                                   message: "请求太频繁，请 \(retry) 秒后再试。"))
                response.headers["Retry-After"] = String(retry)
                return APICaller(keyId: record.id, name: record.name, canWrite: record.canWrite,
                                 viaSession: false, rateLimited: response)
            }
            apiKeys.recordUse(id: record.id)
            return APICaller(keyId: record.id, name: record.name, canWrite: record.canWrite, viaSession: false)
        }
        if auth.validate(token: request.cookies[AuthManager.cookieName]) {
            // 网页登录的自己是完全权限，且不限流
            return APICaller(keyId: nil, name: "网页登录", canWrite: true, viaSession: true)
        }
        throw APIError(status: 401, code: "unauthorized",
                       message: "缺少凭据。请在请求头里加 Authorization: Bearer <你的 API Key>。")
    }

    private func requireWrite(_ caller: APICaller) throws {
        guard caller.canWrite else {
            throw APIError(status: 403, code: "read_only_key",
                           message: "这个 API Key 只有只读权限，写操作被拒绝。")
        }
    }

    private static func apiEntryPayload(_ entry: FileEntry, volumeId: String, store: Store) -> [String: Any] {
        [
            "id": entry.id,
            "volumeId": volumeId,
            "name": entry.name,
            "path": entry.logicalPath,
            "size": entry.size,
            "sha256": entry.sha256,
            "createdAt": ISO8601.string(entry.createdAt),
            "isFolder": false,
            "extension": (entry.name as NSString).pathExtension.lowercased()
        ]
    }

    private func handleAPI(_ request: HTTPRequest) throws -> HTTPResponse {
        let path = request.path
        do {
            var response = try apiRoute(request, path: path)
            // 跨域：只有配置过的来源才带 CORS 头
            if let origin = request.headers["origin"], let allowed = allowedCORSOrigin(origin) {
                response.headers["Access-Control-Allow-Origin"] = allowed
                response.headers["Vary"] = "Origin"
            }
            return response
        } catch let error as APIError {
            return apiFailure(error)
        }
    }

    private func apiRoute(_ request: HTTPRequest, path: String) throws -> HTTPResponse {
        // ---- key 管理：只允许已登录的网页会话（软件里的 API Key 页面也用这套）----
        if path.hasPrefix("/api/admin/keys") {
            guard auth.validate(token: request.cookies[AuthManager.cookieName]) else {
                throw APIError(status: 401, code: "unauthorized", message: "管理 API Key 需要先在网页登录（或在软件里操作）。")
            }
            switch path {
            case "/api/admin/keys":
                if request.method == "GET" {
                    return .json(["ok": true, "keys": apiKeys.all().map { $0.dictionary }])
                }
                if request.method == "POST" {
                    let name = request.jsonString("name") ?? "未命名应用"
                    let scopes = (request.jsonBody?["scopes"] as? [String]) ?? ["read"]
                    let days = request.jsonBody?["expiresInDays"] as? Int
                    let created = try apiKeys.create(name: name, scopes: scopes, expiresInDays: days)
                    var payload = created.record.dictionary
                    // 明文只在这里出现一次
                    payload["key"] = created.plaintext
                    return .json(["ok": true, "key": payload,
                                  "note": "请立刻保存这个 key，之后无法再次查看。"], status: 201)
                }
            case "/api/admin/keys/revoke":
                let id = try requireBody(request, "id")
                guard apiKeys.revoke(id: id) else {
                    throw APIError(status: 404, code: "not_found", message: "找不到这个 API Key。")
                }
                return .json(["ok": true])
            default:
                break
            }
            throw APIError(status: 404, code: "not_found", message: "接口不存在：\(path)")
        }

        // ---- /api/v1/*：开发者接口 ----
        let caller = try apiCaller(request)
        if let limited = caller.rateLimited { return limited }
        let parts = path.split(separator: "/").map(String.init)
        // ["api","v1", ...]
        let rest = parts.dropFirst(2).joined(separator: "/")

        switch rest {
        case "", "me":
            return .json([
                "ok": true,
                "api": "MacNas",
                "apiVersion": "v1",
                "caller": caller.name,
                "scopes": caller.canWrite ? ["read", "write"] : ["read"],
                "volumeCount": store.stats().volumeCount,
                "docs": "https://github.com/23456qwertyuiop/MacNas/blob/main/docs/API.md"
            ])

        case "volumes":
            let volumes = store.stats().volumeStats.map { volume -> [String: Any] in
                ["id": volume.volumeId, "name": volume.name, "path": volume.path,
                 "fileCount": volume.fileCount, "size": volume.logicalBytes,
                 "available": volume.available, "readOnly": volume.readOnly]
            }
            return .json(["ok": true, "volumes": volumes])

        case "stats":
            let payload = store.analytics(volumeId: request.query["volume"]).dictionary
            return .json(["ok": true, "stats": payload])

        case "files":
            // 同一个路径按方法分派：GET 列表、POST/DELETE 删除（删进回收站）
            if request.method == "POST" || request.method == "DELETE" {
                try requireWrite(caller)
                let volumeId = try apiVolume(request)
                let body = request.jsonBody ?? [:]
                if let id = request.jsonString("id") ?? request.query["id"], !id.isEmpty {
                    try store.deleteEntry(volumeId: volumeId, entryId: id)
                    return .json(["ok": true, "deleted": id, "intoTrash": true])
                }
                if let raw = request.jsonString("path") ?? request.query["path"],
                   !raw.isEmpty, LogicalPath.normalize(raw) != LogicalPath.root {
                    try store.deleteFolder(volumeId: volumeId, path: LogicalPath.normalize(raw))
                    return .json(["ok": true, "deleted": raw, "intoTrash": true])
                }
                throw APIError(status: 400, code: "missing_target",
                               message: "请用 id 或 path 指定要删除的内容。")
            }
            guard request.method == "GET" else {
                throw APIError(status: 405, code: "method_not_allowed",
                               message: "列表用 GET，删除用 DELETE（或 POST /api/v1/files/delete）。")
            }
            let volumeId = try apiVolume(request)
            let path = LogicalPath.normalize(request.query["path"] ?? LogicalPath.root)
            let listing = try store.list(volumeId: volumeId, path: path)
            let folders = listing.folders.map { folder -> [String: Any] in
                ["name": folder.name, "path": folder.path, "fileCount": folder.fileCount, "isFolder": true]
            }
            let files = listing.files.map { Self.apiEntryPayload($0, volumeId: volumeId, store: store) }
            return .json(["ok": true, "volumeId": volumeId, "path": listing.path,
                          "folders": folders, "files": files])

        case "files/stat":
            let volumeId = try apiVolume(request)
            guard let entry = try apiResolveEntry(request, volumeId: volumeId) else {
                throw APIError(status: 404, code: "not_found", message: "文件不存在。")
            }
            return .json(["ok": true, "file": Self.apiEntryPayload(entry, volumeId: volumeId, store: store)])

        case "files/download", "files/content":
            let volumeId = try apiVolume(request)
            guard let entry = try apiResolveEntry(request, volumeId: volumeId) else {
                throw APIError(status: 404, code: "not_found", message: "文件不存在。")
            }
            let resolved = try store.resolveEntry(volumeId: volumeId, entryId: entry.id)
            var response = FileResponse.make(request, entry: resolved.entry, url: resolved.url, inline: false)
            response.headers["Cache-Control"] = "no-store"
            return response

        case "files/upload":
            guard request.method == "POST" else {
                throw APIError(status: 405, code: "method_not_allowed", message: "上传请用 POST。")
            }
            try requireWrite(caller)
            let volumeId = try apiVolume(request)
            let directory = LogicalPath.normalize(request.query["path"] ?? LogicalPath.root)
            guard let rawName = request.query["name"], let name = LogicalPath.sanitizedSegment(rawName) else {
                throw APIError(status: 400, code: "bad_name", message: "请用 ?name=文件名 指定要写入的文件名。")
            }
            let tempURL: URL
            let sha256: String
            let size: Int64
            switch request.body {
            case .file(let url, let hash, let bytes):
                tempURL = url; sha256 = hash; size = bytes
            case .data(let data):
                sha256 = FileHash.sha256(of: data); size = Int64(data.count)
                tempURL = AppPaths.uploadsDirectory.appendingPathComponent("api-\(UUID().uuidString).part")
                try? FileManager.default.createDirectory(at: AppPaths.uploadsDirectory, withIntermediateDirectories: true)
                try data.write(to: tempURL)
            case .none:
                throw APIError(status: 400, code: "empty_body", message: "请求体里没有文件内容。")
            }
            let overwrite = (request.query["overwrite"] ?? "") == "1"
            // 同名默认自动改名，避免开发者还要自己处理冲突
            var finalName = name
            if !overwrite {
                var attempt = 2
                while store.entry(volumeId: volumeId, logicalPath: LogicalPath.join(directory, finalName)) != nil {
                    let ext = LogicalPath.fileExtension(for: name)
                    let base = ext.isEmpty ? name : String(name.dropLast(ext.count + 1))
                    finalName = ext.isEmpty ? "\(base) (\(attempt))" : "\(base) (\(attempt)).\(ext)"
                    attempt += 1
                    if attempt > 200 { break }
                }
            }
            let result = try store.commitUpload(volumeId: volumeId, directory: directory, fileName: finalName,
                                                sha256: sha256, size: size, tempFileURL: tempURL, overwrite: overwrite)
            return .json(["ok": true,
                          "file": Self.apiEntryPayload(result.entry, volumeId: volumeId, store: store),
                          "outcome": result.outcome == .deduplicated ? "deduplicated" : "stored"], status: 201)

        case "folders":
            guard request.method == "POST" else {
                throw APIError(status: 405, code: "method_not_allowed", message: "新建文件夹请用 POST。")
            }
            try requireWrite(caller)
            let volumeId = try apiVolume(request)
            let parent = LogicalPath.normalize(request.jsonString("path") ?? LogicalPath.root)
            guard let name = LogicalPath.sanitizedSegment(request.jsonString("name") ?? "") else {
                throw APIError(status: 400, code: "bad_name", message: "请用 name 指定文件夹名。")
            }
            let created = try store.createFolder(volumeId: volumeId, path: parent, name: name)
            return .json(["ok": true, "folder": ["name": name, "path": created, "isFolder": true]], status: 201)

        case "files/rename":
            guard request.method == "POST" else {
                throw APIError(status: 405, code: "method_not_allowed", message: "重命名请用 POST。")
            }
            try requireWrite(caller)
            let volumeId = try apiVolume(request)
            guard let name = LogicalPath.sanitizedSegment(request.jsonString("name") ?? "") else {
                throw APIError(status: 400, code: "bad_name", message: "请用 name 指定新名字。")
            }
            if let id = request.jsonString("id"), !id.isEmpty {
                guard let entry = store.entry(volumeId: volumeId, entryId: id) else {
                    throw APIError(status: 404, code: "not_found", message: "文件不存在。")
                }
                try store.renameEntry(volumeId: volumeId, entryId: id, newName: name)
                return .json(["ok": true, "from": entry.name, "name": name])
            }
            let from = try requireBody(request, "from")
            try store.renameFolder(volumeId: volumeId, path: LogicalPath.normalize(from), newName: name)
            return .json(["ok": true, "from": from, "name": name])

        case "files/move":
            guard request.method == "POST" else {
                throw APIError(status: 405, code: "method_not_allowed", message: "移动/复制请用 POST。")
            }
            try requireWrite(caller)
            let volumeId = try apiVolume(request)
            guard let toPath = request.jsonString("toPath") else {
                throw APIError(status: 400, code: "missing_toPath", message: "请用 toPath 指定目标目录。")
            }
            let body = request.jsonBody ?? [:]
            let ids = (body["ids"] as? [String]) ?? []
            let paths = (body["paths"] as? [String]) ?? []
            guard !ids.isEmpty || !paths.isEmpty else {
                throw APIError(status: 400, code: "nothing_selected", message: "请用 ids 或 paths 指定要移动的内容。")
            }
            let copy = (request.jsonString("mode") ?? "move") == "copy"
            let result = try store.transfer(fromVolumeId: volumeId, entryIds: ids, folderPaths: paths,
                                            toVolumeId: volumeId, toPath: LogicalPath.normalize(toPath),
                                            copy: copy)
            return .json(["ok": true, "mode": copy ? "copy" : "move",
                          "moved": result.moved, "copied": result.copied, "renamed": result.renamed])

        case "files/delete":
            guard request.method == "POST" || request.method == "DELETE" else {
                throw APIError(status: 405, code: "method_not_allowed", message: "删除请用 POST。")
            }
            try requireWrite(caller)
            let volumeId = try apiVolume(request)
            let body = request.jsonBody ?? [:]
            if let id = request.jsonString("id") ?? request.query["id"], !id.isEmpty {
                try store.deleteEntry(volumeId: volumeId, entryId: id)
                return .json(["ok": true, "deleted": id, "intoTrash": true])
            }
            if let raw = request.jsonString("path") ?? request.query["path"],
               !raw.isEmpty, LogicalPath.normalize(raw) != LogicalPath.root {
                try store.deleteFolder(volumeId: volumeId, path: LogicalPath.normalize(raw))
                return .json(["ok": true, "deleted": raw, "intoTrash": true])
            }
            throw APIError(status: 400, code: "missing_target", message: "请用 id 或 path 指定要删除的内容。")

        case "search":
            let query = (request.query["q"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else {
                throw APIError(status: 400, code: "missing_query", message: "请用 ?q= 指定搜索词。")
            }
            let found = store.search(query: query, volumeId: request.query["volume"], limit: 200)
            let payload = found.hits.map { hit -> [String: Any] in
                var item: [String: Any] = ["kind": hit.kind, "name": hit.name, "path": hit.logicalPath,
                                           "volumeId": hit.volumeId, "volumeName": hit.volumeName,
                                           "size": hit.size, "fileCount": hit.fileCount]
                if let id = hit.entryId { item["id"] = id }
                if let createdAt = hit.createdAt { item["createdAt"] = ISO8601.string(createdAt) }
                return item
            }
            return .json(["ok": true, "query": query, "results": payload])

        case "thumbnails":
            let volumeId = try apiVolume(request)
            guard let entry = try apiResolveEntry(request, volumeId: volumeId) else {
                throw APIError(status: 404, code: "not_found", message: "文件不存在。")
            }
            let resolved = try store.resolveEntry(volumeId: volumeId, entryId: entry.id)
            let size = max(32, min(1024, Int(request.query["size"] ?? "256") ?? 256))
            let image = try PreviewService.shared.thumbnail(fileURL: resolved.url,
                                                            cacheKey: entry.sha256,
                                                            maxPixel: size)
            var response = HTTPResponse(status: 200, body: .data(image.data))
            response.headers["Content-Type"] = image.mime
            response.headers["Cache-Control"] = "public, max-age=86400"
            return response

        case "preview":
            let volumeId = try apiVolume(request)
            guard let entry = try apiResolveEntry(request, volumeId: volumeId) else {
                throw APIError(status: 404, code: "not_found", message: "文件不存在。")
            }
            let resolved = try store.resolveEntry(volumeId: volumeId, entryId: entry.id)
            return previewMetaResponse(request,
                                       target: PreviewTarget(entry: resolved.entry, url: resolved.url),
                                       volumeId: volumeId)

        case "preview/content":
            let volumeId = try apiVolume(request)
            guard let entry = try apiResolveEntry(request, volumeId: volumeId) else {
                throw APIError(status: 404, code: "not_found", message: "文件不存在。")
            }
            let resolved = try store.resolveEntry(volumeId: volumeId, entryId: entry.id)
            return try previewContentResponse(request, target: PreviewTarget(entry: resolved.entry, url: resolved.url))

        default:
            throw APIError(status: 404, code: "not_found",
                           message: "接口不存在：\(path)。可用接口见 docs/API.md。")
        }
    }

    private func apiVolume(_ request: HTTPRequest) throws -> String {
        let volumeId = request.query["volume"] ?? request.jsonString("volume") ?? ""
        guard !volumeId.isEmpty else {
            throw APIError(status: 400, code: "missing_volume", message: "请用 ?volume=<目录 id> 指定要操作的目录，可用 /api/v1/volumes 获取。")
        }
        guard store.volume(id: volumeId) != nil else {
            throw APIError(status: 404, code: "unknown_volume", message: "找不到这个目录（volume）。")
        }
        return volumeId
    }

    private func apiResolveEntry(_ request: HTTPRequest, volumeId: String) throws -> FileEntry? {
        if let id = request.query["id"] ?? request.jsonString("id"), !id.isEmpty {
            return store.entry(volumeId: volumeId, entryId: id)
        }
        if let path = request.query["path"] ?? request.jsonString("path"),
           LogicalPath.normalize(path) != LogicalPath.root {
            return store.entry(volumeId: volumeId, logicalPath: LogicalPath.normalize(path))
        }
        return nil
    }

    // MARK: - 空间分析

    /// 去重收益、类型分布、重复内容报告、大文件排行榜
    private func handleAnalytics(_ request: HTTPRequest) throws -> HTTPResponse {
        let volumeId = request.query["volume"]
        let selected: String?
        if let volumeId, !volumeId.isEmpty {
            guard store.volume(id: volumeId) != nil else { throw StoreError.volumeNotFound }
            selected = volumeId
        } else {
            selected = nil
        }
        var payload = store.analytics(volumeId: selected).dictionary
        payload["ok"] = true
        payload["scope"] = selected ?? "all"
        payload["volumes"] = store.stats().volumeStats.map { volume in
            ["id": volume.volumeId, "name": volume.name, "fileCount": volume.fileCount,
             "logicalBytes": volume.logicalBytes, "physicalBytes": volume.physicalBytes]
        }
        return .json(payload)
    }

    // MARK: - 打包下载

    /// 多选之后打包下载。压缩包写到临时文件而不是内存，选很多大文件也不会撑爆内存。
    private func handleZip(_ request: HTTPRequest) throws -> HTTPResponse {
        // 支持 GET + payload=<JSON>：这样浏览器可以直接导航过去原生下载，
        // 不用把整个压缩包先读进 JS 内存（大包时差别很大）。
        var body: [String: Any] = [:]
        if let raw = request.query["payload"], let data = raw.data(using: .utf8),
           let decoded = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            body = decoded
        } else if let json = request.jsonBody {
            body = json
        }
        guard let volumeId = body["volume"] as? String, !volumeId.isEmpty else {
            throw HTTPError(status: 400, message: "缺少参数：volume")
        }
        let ids = (body["ids"] as? [String]) ?? []
        let paths = (body["paths"] as? [String]) ?? []
        guard !ids.isEmpty || !paths.isEmpty else {
            throw HTTPError(status: 400, message: "没有要打包的内容")
        }

        struct Selected {
            var archiveName: String
            var folderPath: String?     // nil = 单个文件
            var entry: FileEntry?
        }
        var selected: [Selected] = []
        var usedNames = Set<String>()

        func uniqueName(_ raw: String) -> String {
            var name = raw
            if name.isEmpty { name = "未命名" }
            guard usedNames.contains(name) else { usedNames.insert(name); return name }
            let ext = (name as NSString).pathExtension
            let base = ext.isEmpty ? name : (name as NSString).deletingPathExtension
            var counter = 2
            while true {
                let candidate = ext.isEmpty ? "\(base) (\(counter))" : "\(base) (\(counter)).\(ext)"
                if !usedNames.contains(candidate) { usedNames.insert(candidate); return candidate }
                counter += 1
            }
        }

        for id in ids {
            guard let entry = store.entry(volumeId: volumeId, entryId: id) else { continue }
            selected.append(Selected(archiveName: uniqueName(entry.name), folderPath: nil, entry: entry))
        }
        for path in paths {
            let normalized = LogicalPath.normalize(path)
            guard normalized != LogicalPath.root else { continue }
            let name = uniqueName(LogicalPath.lastSegment(normalized))
            selected.append(Selected(archiveName: name, folderPath: normalized, entry: nil))
        }
        guard !selected.isEmpty else { throw HTTPError(status: 404, message: "选中的内容都不存在了") }

        // 打包临时文件放在 uploads 目录里，软件启动时会清理过期文件
        try? FileManager.default.createDirectory(at: AppPaths.uploadsDirectory, withIntermediateDirectories: true)
        cleanStaleArchives()
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd-HHmm"
        let archiveURL = AppPaths.uploadsDirectory
            .appendingPathComponent("pack-\(UUID().uuidString).zip")
        let writer = try ZipWriter(destination: archiveURL)

        var fileCount = 0
        var totalBytes: Int64 = 0
        do {
            for item in selected {
                if let entry = item.entry {
                    guard let blob = store.blobURL(sha256: entry.sha256) else { continue }
                    try writer.addFile(at: blob, archivePath: item.archiveName)
                    fileCount += 1
                    totalBytes += entry.size
                } else if let folder = item.folderPath {
                    let children = store.descendantEntries(volumeId: volumeId, path: folder)
                    if children.isEmpty {
                        try writer.addDirectory(archivePath: item.archiveName)
                        continue
                    }
                    for child in children {
                        guard let blob = store.blobURL(sha256: child.sha256) else { continue }
                        let relative = String(child.logicalPath.dropFirst(folder.count))
                        let inner = relative.hasPrefix("/") ? String(relative.dropFirst()) : relative
                        try writer.addFile(at: blob, archivePath: item.archiveName + "/" + inner)
                        fileCount += 1
                        totalBytes += child.size
                    }
                }
            }
            _ = try writer.finish()
        } catch {
            writer.discard()
            throw error
        }

        guard fileCount > 0 else {
            writer.discard()
            throw HTTPError(status: 404, message: "选中的内容都取不到了")
        }

        let attributes = try? FileManager.default.attributesOfItem(atPath: archiveURL.path)
        let archiveSize = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        LogCenter.shared.info("打包下载：\(fileCount) 个文件 / \(totalBytes) 字节 → \(archiveSize) 字节 ← \(request.remoteAddress)")

        let fileName = "MacNas-\(stamp.string(from: Date())).zip"
        var response = HTTPResponse(status: 200, body: .file(url: archiveURL, offset: 0, length: archiveSize))
        response.headers["Content-Type"] = "application/zip"
        response.headers["Content-Disposition"] = FileResponse.contentDisposition(name: fileName, inline: false)
        response.headers["Cache-Control"] = "no-store"
        return response
    }

    /// 清理一小时前的打包临时文件
    private func cleanStaleArchives() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: AppPaths.uploadsDirectory,
                                                     includingPropertiesForKeys: [.contentModificationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-3600)
        for file in files where file.pathExtension == "zip" && file.lastPathComponent.hasPrefix("pack-") {
            let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
            if modified < cutoff { try? fm.removeItem(at: file) }
        }
    }

    // MARK: - 秒传（客户端先算哈希，命中就零字节建记录）

    /// 问一句「这个哈希库里有没有」，网页端据此跳过整个上传
    private func handleHas(_ request: HTTPRequest) throws -> HTTPResponse {
        let hash = (request.query["sha256"] ?? "").lowercased()
        guard hash.count == 64 else {
            throw HTTPError(status: 400, message: "sha256 参数不合法")
        }
        if let url = store.blobURL(sha256: hash),
           let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value {
            return .json(["ok": true, "exists": true, "sha256": hash, "size": size])
        }
        return .json(["ok": true, "exists": false, "sha256": hash])
    }

    /// 内容已在库里时直接建记录（不传文件体）。服务器会再校验一次内容确实存在，
    /// 避免客户端伪造哈希造出「指向不存在内容」的坏记录。
    private func handleRegister(_ request: HTTPRequest) throws -> HTTPResponse {
        let volumeId = try writableVolumeID(request)
        guard let body = request.jsonBody else { throw HTTPError(status: 400, message: "请求体不是 JSON") }
        guard let hash = (body["sha256"] as? String)?.lowercased(), hash.count == 64 else {
            throw HTTPError(status: 400, message: "sha256 参数不合法")
        }
        let directory = (body["path"] as? String) ?? LogicalPath.root
        guard let name = body["name"] as? String, !name.isEmpty else {
            throw HTTPError(status: 400, message: "缺少参数：name")
        }
        let overwrite = (body["overwrite"] as? Bool) ?? false
        guard let blobURL = store.blobURL(sha256: hash) else {
            throw HTTPError(status: 404, message: "库里没有这份内容，请正常上传")
        }
        let size = Int64((try? FileManager.default.attributesOfItem(atPath: blobURL.path)[.size] as? NSNumber)?.int64Value ?? 0)

        // 内容已存在，传一个不存在的临时路径即可：去重分支会忽略它
        let placeholder = AppPaths.uploadsDirectory.appendingPathComponent("instant-\(UUID().uuidString).part")
        let result = try store.commitUpload(volumeId: volumeId, directory: directory, fileName: name,
                                            sha256: hash, size: size, tempFileURL: placeholder,
                                            overwrite: overwrite)
        LogCenter.shared.info("秒传命中：\(name)（\(size) 字节，未传输内容）← \(request.remoteAddress)")
        let facts = store.dedupFacts()
        return .json([
            "ok": true,
            "instant": true,
            "file": Self.filePayload(result.entry, facts: facts)
        ])
    }

    // MARK: - 缩略图与媒体列表

    private func handleThumbnail(_ request: HTTPRequest) throws -> HTTPResponse {
        let volumeId = try requireQuery(request, "volume")
        let target = try previewTarget(volumeId: volumeId, request: request)
        let requested = Int(request.query["size"] ?? "") ?? 320
        let maxPixel = min(max(requested, 64), 1024)
        let thumb = try PreviewService.shared.thumbnail(fileURL: target.url,
                                                        cacheKey: target.entry.sha256,
                                                        maxPixel: maxPixel)
        var response = HTTPResponse(status: 200, body: .data(thumb.data))
        response.headers["Content-Type"] = thumb.mime
        // 内容寻址，天然可以长期缓存
        response.headers["Cache-Control"] = "public, max-age=604800, immutable"
        response.headers["ETag"] = "\"\(target.entry.sha256)-\(maxPixel)\""
        return response
    }

    /// 某个目录（含子目录）下的图片/视频列表，供「照片」时间线使用
    private func handleMedia(_ request: HTTPRequest) throws -> HTTPResponse {
        let volumeId = try requireQuery(request, "volume")
        let root = LogicalPath.normalize(request.query["path"] ?? LogicalPath.root)
        let kind = request.query["kind"] ?? "all"
        let limit = min(max(Int(request.query["limit"] ?? "") ?? 400, 1), 2000)
        let offset = max(Int(request.query["offset"] ?? "") ?? 0, 0)

        let items = store.mediaEntries(volumeId: volumeId, path: root, kind: kind)
        let slice = items.dropFirst(offset).prefix(limit)
        let facts = store.dedupFacts()
        return .json([
            "ok": true,
            "total": items.count,
            "offset": offset,
            "items": slice.map { entry -> [String: Any] in
                var payload = Self.filePayload(entry, facts: facts)
                payload["path"] = entry.logicalPath
                return payload
            }
        ])
    }

    // MARK: - 预览

    private struct PreviewTarget {
        var entry: FileEntry
        var url: URL
    }

    /// 定位要预览的文件：既支持按记录 id，也支持按逻辑路径
    private func previewTarget(volumeId: String, request: HTTPRequest) throws -> PreviewTarget {
        if let entryId = request.query["id"], !entryId.isEmpty {
            let resolved = try store.resolveEntry(volumeId: volumeId, entryId: entryId)
            return PreviewTarget(entry: resolved.entry, url: resolved.url)
        }
        let path = try requireQuery(request, "path")
        guard let entry = store.entry(volumeId: volumeId, logicalPath: path) else {
            throw HTTPError(status: 404, message: "文件不存在")
        }
        let resolved = try store.resolveEntry(volumeId: volumeId, entryId: entry.id)
        return PreviewTarget(entry: resolved.entry, url: resolved.url)
    }

    private func handlePreview(_ request: HTTPRequest) throws -> HTTPResponse {
        let volumeId = try requireQuery(request, "volume")
        let target = try previewTarget(volumeId: volumeId, request: request)
        return previewMetaResponse(request, target: target, volumeId: volumeId)
    }

    private func previewMetaResponse(_ request: HTTPRequest, target: PreviewTarget, volumeId: String) -> HTTPResponse {
        let meta = PreviewRegistry.meta(forFileName: target.entry.name)
        var payload: [String: Any] = [
            "ok": true,
            "name": target.entry.name,
            "size": target.entry.size,
            "mime": meta.mime,
            "kind": meta.kind.rawValue,
            "previewable": meta.previewable,
            "content": previewContentURL(request, target: target, volumeId: volumeId),
            "download": previewDownloadURL(request, target: target, volumeId: volumeId)
        ]
        if let note = meta.note { payload["note"] = note }
        return .json(payload)
    }

    /// 分享页走 /api/pub/<token>/…，登录态走 /api/…
    private func previewContentURL(_ request: HTTPRequest, target: PreviewTarget, volumeId: String) -> String {
        if request.path.hasPrefix("/api/pub/") {
            let token = String(request.path.dropFirst("/api/pub/".count)).split(separator: "/").first.map(String.init) ?? ""
            var components = URLComponents()
            components.path = "/api/pub/\(token)/preview/content"
            components.queryItems = [URLQueryItem(name: "id", value: target.entry.id)]
            return components.string ?? components.path
        }
        var components = URLComponents()
        components.path = "/api/preview/content"
        components.queryItems = [
            URLQueryItem(name: "volume", value: volumeId),
            URLQueryItem(name: "id", value: target.entry.id)
        ]
        return components.string ?? components.path
    }

    private func previewDownloadURL(_ request: HTTPRequest, target: PreviewTarget, volumeId: String) -> String {
        if request.path.hasPrefix("/api/pub/") {
            let token = String(request.path.dropFirst("/api/pub/".count)).split(separator: "/").first.map(String.init) ?? ""
            var components = URLComponents()
            components.path = "/api/pub/\(token)/download"
            components.queryItems = [URLQueryItem(name: "id", value: target.entry.id)]
            return components.string ?? components.path
        }
        var components = URLComponents()
        components.path = "/api/download"
        components.queryItems = [
            URLQueryItem(name: "volume", value: volumeId),
            URLQueryItem(name: "id", value: target.entry.id)
        ]
        return components.string ?? components.path
    }

    private func handlePreviewContent(_ request: HTTPRequest) throws -> HTTPResponse {
        let volumeId = try requireQuery(request, "volume")
        let target = try previewTarget(volumeId: volumeId, request: request)
        return try previewContentResponse(request, target: target)
    }

    /// 真正取预览内容：图片/视频/音频/PDF 直接给原文件（支持 Range），
    /// 文本读出来，Word 转 HTML，其余用 QuickLook 出图。
    private func previewContentResponse(_ request: HTTPRequest, target: PreviewTarget) throws -> HTTPResponse {
        let meta = PreviewRegistry.meta(forFileName: target.entry.name)
        switch meta.kind {
        case .image, .video, .audio, .pdf:
            return FileResponse.make(request, entry: target.entry, url: target.url, inline: true)

        case .text:
            let data = try PreviewService.shared.plainText(fileURL: target.url)
            var response = HTTPResponse(status: 200, body: .data(data))
            response.headers["Content-Type"] = "text/plain; charset=utf-8"
            response.headers["Cache-Control"] = "no-store"
            return response

        case .document:
            let data = try PreviewService.shared.documentHTML(fileURL: target.url, cacheKey: target.entry.sha256)
            var response = HTTPResponse(status: 200, body: .data(data))
            response.headers["Content-Type"] = "text/html; charset=utf-8"
            response.headers["Cache-Control"] = "no-store"
            return response

        case .render:
            let data = try PreviewService.shared.renderedImage(fileURL: target.url, cacheKey: target.entry.sha256)
            var response = HTTPResponse(status: 200, body: .data(data))
            response.headers["Content-Type"] = "image/png"
            response.headers["Cache-Control"] = "no-store"
            return response

        case .none:
            throw HTTPError(status: 415, message: "这个格式不支持预览，请下载后查看")
        }
    }

    private func publicSharePreview(_ request: HTTPRequest, share: ShareRecord) throws -> HTTPResponse {
        let (target, volumeId) = try sharePreviewTarget(request, share: share)
        return previewMetaResponse(request, target: target, volumeId: volumeId)
    }

    private func publicSharePreviewContent(_ request: HTTPRequest, share: ShareRecord) throws -> HTTPResponse {
        let (target, _) = try sharePreviewTarget(request, share: share)
        return try previewContentResponse(request, target: target)
    }

    /// 分享页预览：和下载一样要校验文件确实在分享范围内
    private func sharePreviewTarget(_ request: HTTPRequest, share: ShareRecord) throws -> (PreviewTarget, String) {
        guard shareUnlocked(request, share: share) else {
            throw HTTPError(status: 401, message: "需要先输入分享密码")
        }
        let entryId = try requireQuery(request, "id")
        guard let entry = store.entry(volumeId: share.volumeId, entryId: entryId) else {
            throw HTTPError(status: 404, message: "文件不存在")
        }
        let allowed = share.isFolder ? isInside(entry.logicalPath, root: share.logicalPath) : (entry.id == share.entryId)
        guard allowed else {
            throw HTTPError(status: 403, message: "该文件不在分享范围内")
        }
        let resolved = try store.resolveEntry(volumeId: share.volumeId, entryId: entryId)
        return (PreviewTarget(entry: resolved.entry, url: resolved.url), share.volumeId)
    }

    // MARK: - 辅助

    /// 取出卷 id 并确认可写（只读卷直接 409，不做任何改动）
    private func writableVolumeID(_ request: HTTPRequest) throws -> String {
        let volumeId = try requireBody(request, "volume")
        try store.ensureWritable(volumeId: volumeId)
        return volumeId
    }

    private func requireQuery(_ request: HTTPRequest, _ key: String) throws -> String {
        guard let value = request.query[key], !value.isEmpty else {
            throw HTTPError(status: 400, message: "缺少参数：\(key)")
        }
        return value
    }

    private func requireBody(_ request: HTTPRequest, _ key: String) throws -> String {
        guard let value = request.jsonString(key), !value.isEmpty else {
            throw HTTPError(status: 400, message: "缺少参数：\(key)")
        }
        return value
    }

    private func log(_ request: HTTPRequest, _ response: HTTPResponse, _ started: Date) {
        let milliseconds = Int(Date().timeIntervalSince(started) * 1000)
        let level: LogEntry.Level
        if response.status >= 500 {
            level = .error
        } else if response.status >= 400 {
            level = .warn
        } else {
            level = .debug
        }
        let detail = response.status >= 400 ? " \(Self.errorMessage(from: response))" : ""
        LogCenter.shared.log(level, "\(request.remoteAddress) \(request.method) \(request.path) → \(response.status) (\(milliseconds)ms)\(detail)")
    }

    private static func errorMessage(from response: HTTPResponse) -> String {
        guard case .data(let data) = response.body,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = object["error"] as? String else { return "" }
        return message
    }
}
