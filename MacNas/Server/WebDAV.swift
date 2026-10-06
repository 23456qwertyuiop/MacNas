//
//  WebDAV.swift
//  MacNas
//
//  把「卷 + 逻辑路径」这棵逻辑目录树以 WebDAV 暴露出去（挂在 /dav），
//  Finder 里 ⌘K → http://<IP>:<端口>/dav 即可挂载。
//
//  为什么这样做：写入直接走 Store 的同一套去重管线，
//  所以 WebDAV 侧的新增/改名/删除都会落到 info/index.json，
//  不会出现「磁盘上另有一份真相」的问题。
//

import Foundation

final class WebDAVHandler: @unchecked Sendable {

    static let prefix = "/dav"

    private let store: Store
    private let auth: AuthManager
    private let environment: ServerEnvironment

    init(store: Store, auth: AuthManager, environment: ServerEnvironment) {
        self.store = store
        self.auth = auth
        self.environment = environment
    }

    static func isWebDAVPath(_ path: String) -> Bool {
        path == prefix || path.hasPrefix(prefix + "/")
    }

    /// 只有 WebDAV 客户端会用的方法（网页端不会用），用于支持直接挂载服务器根
    static let webdavOnlyMethods: Set<String> = ["PROPFIND", "PROPPATCH", "LOCK", "UNLOCK", "MKCOL", "MOVE", "COPY"]

    // MARK: - 入口

    func handle(_ request: HTTPRequest) -> HTTPResponse {
        let client = request.headers["user-agent"] ?? "-"
        guard environment.webdavEnabled else {
            environment.recordWebDAV(client: client, method: request.method, path: request.path, status: 403)
            return .failure(403, "WebDAV 已在软件里关闭")
        }
        let authorized = auth.validate(token: request.cookies[AuthManager.cookieName])
            || (request.headers["authorization"]?.lowercased().hasPrefix("basic ") ?? false)
        environment.recordWebDAV(client: client, method: request.method, path: request.path, status: 0)
        environment.recordWebDAVRequest(authorized: authorized)

        // 把客户端发来的原始请求头原样记下来（排查挂载问题时这是最有用的一条）
        if environment.webdavTraceRawRequests {
            let headerText = request.headers.keys.sorted()
                .map { "\($0): \(request.headers[$0] ?? "")" }
                .joined(separator: " | ")
            LogCenter.shared.debug("WebDAV 原始请求 \(request.method) \(request.path) ← \(request.remoteAddress) ｜ \(headerText)")
        }

        // OPTIONS 免认证，直接返回能力声明。
        //
        // 这一条是 macOS 能否挂载的关键：Finder 的 WebDAV 客户端第一部会发一个
        // 不带凭据的 OPTIONS 探测能力。如果这里回 401，客户端在「手上没有凭据」时
        // 会反复重试并最终放弃 —— 永远走不到 PROPFIND，也就永远不会弹密码框，
        // 表现就是「输入网址后直接提示连接服务器出现问题」。
        // 实测：OPTIONS 回 401 时客户端只发 3 个请求就放弃；回 200 时会继续 PROPFIND。
        // OPTIONS 只暴露协议能力，不含任何文件信息，免认证是安全的（也是 Apache/nginx 的常见做法）。
        if request.method == "OPTIONS" {
            LogCenter.shared.debug("WebDAV OPTIONS \(request.path)（免认证）ua=\(request.headers["user-agent"] ?? "-") ← \(request.remoteAddress)")
            return optionsResponse()
        }

        guard authorize(request) else {
            // 注意：401 刻意返回**空响应体**，不带 JSON。
            // macOS 的 WebDAV 客户端（WebDAVLib）对 401 的响应体很敏感，
            // 带 JSON 体时它会认为「认证也帮不上忙」而直接放弃挂载。
            var response = HTTPResponse(status: 401, body: .empty)
            // 只写最标准的写法：加 charset="UTF-8" 会让部分 macOS 客户端
            // 在钥匙串里按不同「保护空间」查找凭据，结果找不到就既不发送也不弹窗。
            response.headers["WWW-Authenticate"] = "Basic realm=\"MacNas\""
            response.headers["DAV"] = "1, 2, 3"
            response.headers["MS-Author-Via"] = "DAV"
            return response
        }
        do {
            return try route(request)
        } catch let error as HTTPError {
            return .failure(error.status, error.message)
        } catch let error as StoreError {
            switch error {
            case .volumeNotFound, .notFound: return .failure(404, error.localizedDescription)
            case .volumeUnavailable: return .failure(503, error.localizedDescription)
            case .readOnly: return .failure(403, error.localizedDescription)
            case .invalidPath, .invalidName: return .failure(409, error.localizedDescription)
            case .conflict: return .failure(405, error.localizedDescription)
            case .io: return .failure(500, error.localizedDescription)
            }
        } catch {
            return .failure(500, "服务器内部错误：\(error.localizedDescription)")
        }
    }

    private func authorize(_ request: HTTPRequest) -> Bool {
        let client = request.headers["user-agent"] ?? "-"
        if auth.validate(token: request.cookies[AuthManager.cookieName]) { return true }

        guard let header = request.headers["authorization"], !header.isEmpty else {
            LogCenter.shared.debug("WebDAV 未带凭据（会回 401 挑战）：\(request.method) \(request.path) ua=\(client) ← \(request.remoteAddress)")
            return false
        }
        guard header.lowercased().hasPrefix("basic ") else {
            let scheme = header.split(separator: " ").first.map(String.init) ?? "?"
            LogCenter.shared.warn("WebDAV 收到非 Basic 认证（\(scheme)）：\(request.method) \(request.path) ua=\(client) ← \(request.remoteAddress)")
            return false
        }
        guard let data = Data(base64Encoded: String(header.dropFirst(6)).trimmingCharacters(in: .whitespaces)) else {
            LogCenter.shared.warn("WebDAV Basic 凭据无法 base64 解码 ua=\(client) ← \(request.remoteAddress)")
            return false
        }

        // 不同客户端对非 ASCII 密码的编码不一致：先按 UTF-8，再退回 Latin-1
        var candidates: [String] = []
        for encoding in [String.Encoding.utf8, .isoLatin1] {
            if let text = String(data: data, encoding: encoding), !candidates.contains(text) {
                candidates.append(text)
            }
        }

        for text in candidates {
            let pieces = text.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard pieces.count == 2 else { continue }
            let rawName = String(pieces[0])
            let password = String(pieces[1])
            let name = normalizedUsername(rawName)

            if auth.verifyBasic(username: name, password: password) {
                if name != rawName {
                    LogCenter.shared.info("WebDAV 认证成功（用户名已归一化：「\(rawName)」→「\(name)」）← \(request.remoteAddress)")
                }
                return true
            }
        }

        // 只记录用户名与密码长度，绝不记录密码内容
        let readable = candidates.first ?? ""
        let pieces = readable.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
        let rawName = pieces.count == 2 ? String(pieces[0]) : "（无法解析）"
        let passwordLength = pieces.count == 2 ? pieces[1].count : 0
        LogCenter.shared.warn("WebDAV 认证失败：用户名「\(rawName)」，密码长度 \(passwordLength)（软件账号「\(auth.currentUsername)」）ua=\(client) ← \(request.remoteAddress)")
        return false
    }

    /// 客户端可能把用户名写成 “域\\用户”、或前后带空格，这里做一次归一化
    private func normalizedUsername(_ raw: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if let backslash = name.firstIndex(of: "\\"), backslash != name.startIndex {
            name = String(name[name.index(after: backslash)...])
        }
        return name
    }

    /// WebDAV 能力声明（OPTIONS 响应）
    private func optionsResponse() -> HTTPResponse {
        var response = HTTPResponse(status: 200, body: .empty)
        response.headers["DAV"] = "1, 2, 3"
        response.headers["Allow"] = "OPTIONS, GET, HEAD, PUT, DELETE, PROPFIND, PROPPATCH, MKCOL, COPY, MOVE, LOCK, UNLOCK"
        response.headers["MS-Author-Via"] = "DAV"
        response.headers["Accept-Ranges"] = "bytes"
        return response
    }

    private var readOnly: Bool { environment.webdavReadOnly }

    private func route(_ request: HTTPRequest) throws -> HTTPResponse {
        let parsed = parse(path: request.path)

        switch request.method {
        case "PROPFIND":
            return try propfind(request, parsed)
        case "PROPPATCH":
            return propPatch()
        case "LOCK":
            return lock(request)
        case "UNLOCK":
            return HTTPResponse(status: 204, body: .empty)

        case "GET", "HEAD":
            guard let volume = parsed.volume, let entry = currentEntry(volumeId: volume.id, path: parsed.logicalPath) else {
                throw HTTPError(status: 404, message: "文件不存在")
            }
            guard let url = try? store.resolveEntry(volumeId: volume.id, entryId: entry.id).url else {
                throw HTTPError(status: 404, message: "内容不存在")
            }
            return FileResponse.make(request, entry: entry, url: url, inline: true)

        case "PUT":
            return try put(request, parsed)
        case "MKCOL":
            return try mkcol(parsed)

        case "DELETE":
            return try remove(parsed)

        case "MOVE":
            return try moveOrCopy(request, from: parsed, copy: false)
        case "COPY":
            return try moveOrCopy(request, from: parsed, copy: true)

        default:
            throw HTTPError(status: 405, message: "不支持的方法：\(request.method)")
        }
    }

    // MARK: - 路径解析

    private struct ParsedPath {
        var volume: Volume?
        var logicalPath: String
        var firstSegment: String?
        var exists: Bool
    }

    private func parse(path: String) -> ParsedPath {
        var rest = path
        if rest.hasPrefix(Self.prefix) { rest = String(rest.dropFirst(Self.prefix.count)) }
        let decoded = rest.removingPercentEncoding ?? rest
        var segments = decoded.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let first = segments.first else {
            return ParsedPath(volume: nil, logicalPath: LogicalPath.root, firstSegment: nil, exists: true)
        }
        let volume = resolveVolume(first)
        segments.removeFirst()
        let logicalPath = segments.isEmpty ? LogicalPath.root : "/" + segments.joined(separator: "/")
        return ParsedPath(volume: volume, logicalPath: LogicalPath.normalize(logicalPath), firstSegment: first, exists: volume != nil)
    }

    /// 卷在 WebDAV 里的显示名：用卷名（重名自动加序号），也允许直接用卷 id
    private func volumeSegments() -> [(segment: String, volume: Volume)] {
        var used = Set<String>()
        var result: [(String, Volume)] = []
        for volume in store.volumeList() {
            var base = LogicalPath.sanitizedSegment(volume.name) ?? "卷"
            base = base.replacingOccurrences(of: "/", with: "-")
            if base.isEmpty { base = "卷" }
            var segment = base
            var counter = 2
            while used.contains(segment) {
                segment = "\(base) (\(counter))"
                counter += 1
            }
            used.insert(segment)
            result.append((segment, volume))
        }
        return result
    }

    private func resolveVolume(_ segment: String) -> Volume? {
        let decoded = segment.removingPercentEncoding ?? segment
        if let match = volumeSegments().first(where: { $0.segment == decoded }) { return match.volume }
        return store.volume(id: decoded)
    }

    private func segment(for volume: Volume) -> String {
        volumeSegments().first(where: { $0.volume.id == volume.id })?.segment ?? volume.id
    }

    private func currentEntry(volumeId: String, path: String) -> FileEntry? {
        store.entry(volumeId: volumeId, logicalPath: path)
    }

    private func currentFolderExists(volumeId: String, path: String) -> Bool {
        path == LogicalPath.root || store.folderExists(volumeId: volumeId, path: path)
    }

    // MARK: - PROPFIND

    private func propfind(_ request: HTTPRequest, _ parsed: ParsedPath) throws -> HTTPResponse {
        let depth = (request.headers["depth"] ?? "1").lowercased()
        guard depth != "infinity" else {
            throw HTTPError(status: 403, message: "不支持 Depth: infinity，请用 0 或 1")
        }

        var items: [String] = []

        if parsed.volume == nil {
            // 根：列出所有卷
            items.append(responseXML(href: href(volumeSegment: nil, logicalPath: LogicalPath.root, isCollection: true),
                                     isCollection: true, name: "MacNas",
                                     modified: Date(), size: 0, etag: nil, contentType: nil))
            if depth == "1" {
                for entry in volumeSegments() {
                    items.append(responseXML(href: href(volumeSegment: entry.segment, logicalPath: LogicalPath.root, isCollection: true),
                                             isCollection: true,
                                             name: entry.segment,
                                             modified: Date(),
                                             size: 0,
                                             etag: nil,
                                             contentType: nil))
                }
            }
            return multiStatus(items)
        }

        guard let volume = parsed.volume else { throw HTTPError(status: 404, message: "路径不存在") }
        let volumeSegment = segment(for: volume)

        if parsed.logicalPath == LogicalPath.root {
            items.append(responseXML(href: href(volumeSegment: volumeSegment, logicalPath: LogicalPath.root, isCollection: true),
                                     isCollection: true, name: volume.name,
                                     modified: Date(), size: 0, etag: nil, contentType: nil))
            if depth == "1", volume.isPrepared {
                let listing = try store.list(volumeId: volume.id, path: LogicalPath.root)
                items.append(contentsOf: childrenXML(listing: listing, volumeSegment: volumeSegment))
            }
            return multiStatus(items)
        }

        if let entry = currentEntry(volumeId: volume.id, path: parsed.logicalPath) {
            items.append(responseXML(href: href(volumeSegment: volumeSegment, logicalPath: entry.logicalPath, isCollection: false),
                                     isCollection: false,
                                     name: entry.name, modified: entry.createdAt, size: entry.size,
                                     etag: entry.sha256, contentType: MimeTypes.guess(forFileName: entry.name)))
            return multiStatus(items)
        }

        guard currentFolderExists(volumeId: volume.id, path: parsed.logicalPath) else {
            throw HTTPError(status: 404, message: "路径不存在")
        }
        items.append(responseXML(href: href(volumeSegment: volumeSegment, logicalPath: parsed.logicalPath, isCollection: true),
                                 isCollection: true,
                                 name: LogicalPath.lastSegment(parsed.logicalPath),
                                 modified: Date(), size: 0, etag: nil, contentType: nil))
        if depth == "1" {
            let listing = try store.list(volumeId: volume.id, path: parsed.logicalPath)
            items.append(contentsOf: childrenXML(listing: listing, volumeSegment: volumeSegment))
        }
        return multiStatus(items)
    }

    private func childrenXML(listing: DirectoryListing, volumeSegment: String) -> [String] {
        var items: [String] = []
        for folder in listing.folders {
            items.append(responseXML(href: href(volumeSegment: volumeSegment, logicalPath: folder.path, isCollection: true),
                                     isCollection: true,
                                     name: folder.name, modified: Date(), size: 0, etag: nil, contentType: nil))
        }
        for file in listing.files {
            items.append(responseXML(href: href(volumeSegment: volumeSegment, logicalPath: file.logicalPath, isCollection: false),
                                     isCollection: false,
                                     name: file.name, modified: file.createdAt, size: file.size,
                                     etag: file.sha256, contentType: MimeTypes.guess(forFileName: file.name)))
        }
        return items
    }

    private func multiStatus(_ items: [String]) -> HTTPResponse {
        let xml = "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n"
            + "<D:multistatus xmlns:D=\"DAV:\">\n"
            + items.joined(separator: "\n")
            + "\n</D:multistatus>\n"
        var response = HTTPResponse(status: 207, body: .data(Data(xml.utf8)))
        response.headers["Content-Type"] = "application/xml; charset=utf-8"
        return response
    }

    private func responseXML(href: String,
                             isCollection: Bool,
                             name: String,
                             modified: Date,
                             size: Int64,
                             etag: String?,
                             contentType: String?) -> String {
        var props = "<D:displayname>\(Self.escape(name))</D:displayname>"
        props += "<D:getlastmodified>\(HTTPDate.string(modified))</D:getlastmodified>"
        props += "<D:creationdate>\(ISO8601.string(modified))</D:creationdate>"
        props += isCollection
            ? "<D:resourcetype><D:collection/></D:resourcetype><D:getcontentlength>0</D:getcontentlength>"
            : "<D:resourcetype/><D:getcontentlength>\(size)</D:getcontentlength>"
        if let contentType { props += "<D:getcontenttype>\(Self.escape(contentType))</D:getcontenttype>" }
        if let etag { props += "<D:getetag>\"\(etag)\"</D:getetag>" }
        props += "<D:supportedlock><D:lockentry><D:lockscope><D:exclusive/></D:lockscope>"
        props += "<D:locktype><D:write/></D:locktype></D:lockentry></D:supportedlock>"
        return "<D:response><D:href>\(Self.escape(href))</D:href>"
            + "<D:propstat><D:prop>\(props)</D:prop>"
            + "<D:status>HTTP/1.1 200 OK</D:status></D:propstat></D:response>"
    }

    private func propPatch() -> HTTPResponse {
        let body = "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n"
            + "<D:multistatus xmlns:D=\"DAV:\"><D:response>"
            + "<D:propstat><D:prop/><D:status>HTTP/1.1 200 OK</D:status></D:propstat>"
            + "</D:response></D:multistatus>\n"
        var response = HTTPResponse(status: 207, body: .data(Data(body.utf8)))
        response.headers["Content-Type"] = "application/xml; charset=utf-8"
        return response
    }

    /// 不做真正的锁管理，但给出合法的锁令牌，Office / Finder 保存时才不会拒绝写入
    private func lock(_ request: HTTPRequest) -> HTTPResponse {
        let token = "opaquelocktoken:macnas-\(RandomBytes.hex(count: 8))"
        let body = "<?xml version=\"1.0\" encoding=\"utf-8\"?>\n"
            + "<D:prop xmlns:D=\"DAV:\"><D:lockdiscovery><D:activelock>"
            + "<D:locktype><D:write/></D:locktype>"
            + "<D:lockscope><D:exclusive/></D:lockscope>"
            + "<D:depth>0</D:depth>"
            + "<D:owner><D:href>MacNas</D:href></D:owner>"
            + "<D:timeout>Second-3600</D:timeout>"
            + "<D:locktoken><D:href>\(token)</D:href></D:locktoken>"
            + "</D:activelock></D:lockdiscovery></D:prop>"
        var response = HTTPResponse(status: 200, body: .data(Data(body.utf8)))
        response.headers["Content-Type"] = "application/xml; charset=utf-8"
        response.headers["Lock-Token"] = "<\(token)>"
        return response
    }

    // MARK: - 写操作

    private func put(_ request: HTTPRequest, _ parsed: ParsedPath) throws -> HTTPResponse {
        guard !readOnly else { throw HTTPError(status: 403, message: "WebDAV 当前是只读模式") }
        guard let volume = parsed.volume else { throw HTTPError(status: 409, message: "目标目录不存在") }
        guard volume.isPrepared else { throw HTTPError(status: 503, message: "该目录当前不可用") }

        let logical = parsed.logicalPath
        guard logical != LogicalPath.root else { throw HTTPError(status: 405, message: "不能这样写入卷根") }
        let name = LogicalPath.lastSegment(logical)
        let directory = LogicalPath.parent(logical)
        guard currentFolderExists(volumeId: volume.id, path: directory) else {
            throw HTTPError(status: 409, message: "上级文件夹不存在")
        }

        let existed = currentEntry(volumeId: volume.id, path: logical) != nil
        let result: (entry: FileEntry, outcome: UploadOutcome)

        switch request.body {
        case .file(let url, let sha, let bytes):
            // 流式上传：临时文件已写好、哈希已算完
            result = try store.commitUpload(volumeId: volume.id, directory: directory, fileName: name,
                                            sha256: sha, size: bytes, tempFileURL: url, overwrite: true)
        case .data(let data):
            let tempURL = makeTempFile()
            try data.write(to: tempURL)
            result = try store.commitUpload(volumeId: volume.id, directory: directory, fileName: name,
                                            sha256: FileHash.sha256(of: data), size: Int64(data.count),
                                            tempFileURL: tempURL, overwrite: true)
        case .none:
            let tempURL = makeTempFile()
            FileManager.default.createFile(atPath: tempURL.path, contents: Data())
            result = try store.commitUpload(volumeId: volume.id, directory: directory, fileName: name,
                                            sha256: FileHash.sha256(of: Data()), size: 0,
                                            tempFileURL: tempURL, overwrite: true)
        }

        var response = HTTPResponse(status: existed ? 204 : 201, body: .empty)
        response.headers["ETag"] = "\"\(result.entry.sha256)\""
        return response
    }

    private func makeTempFile() -> URL {
        try? FileManager.default.createDirectory(at: AppPaths.uploadsDirectory, withIntermediateDirectories: true)
        return AppPaths.uploadsDirectory.appendingPathComponent("dav-\(UUID().uuidString).part")
    }

    private func mkcol(_ parsed: ParsedPath) throws -> HTTPResponse {
        guard !readOnly else { throw HTTPError(status: 403, message: "WebDAV 当前是只读模式") }
        guard let volume = parsed.volume, parsed.logicalPath != LogicalPath.root else {
            throw HTTPError(status: 405, message: "不能在这里创建文件夹")
        }
        let name = LogicalPath.lastSegment(parsed.logicalPath)
        let directory = LogicalPath.parent(parsed.logicalPath)
        guard currentFolderExists(volumeId: volume.id, path: directory) else {
            throw HTTPError(status: 409, message: "上级文件夹不存在")
        }
        if currentFolderExists(volumeId: volume.id, path: parsed.logicalPath) || currentEntry(volumeId: volume.id, path: parsed.logicalPath) != nil {
            throw HTTPError(status: 405, message: "同名资源已存在")
        }
        _ = try store.createFolder(volumeId: volume.id, path: directory, name: name)
        return HTTPResponse(status: 201, body: .empty)
    }

    private func remove(_ parsed: ParsedPath) throws -> HTTPResponse {
        guard !readOnly else { throw HTTPError(status: 403, message: "WebDAV 当前是只读模式") }
        guard let volume = parsed.volume, parsed.logicalPath != LogicalPath.root else {
            throw HTTPError(status: 403, message: "不能删除卷根")
        }
        if let entry = currentEntry(volumeId: volume.id, path: parsed.logicalPath) {
            try store.deleteEntry(volumeId: volume.id, entryId: entry.id)
            return HTTPResponse(status: 204, body: .empty)
        }
        guard currentFolderExists(volumeId: volume.id, path: parsed.logicalPath) else {
            throw HTTPError(status: 404, message: "资源不存在")
        }
        _ = try store.deleteFolder(volumeId: volume.id, path: parsed.logicalPath)
        return HTTPResponse(status: 204, body: .empty)
    }

    private func moveOrCopy(_ request: HTTPRequest, from source: ParsedPath, copy: Bool) throws -> HTTPResponse {
        guard !readOnly else { throw HTTPError(status: 403, message: "WebDAV 当前是只读模式") }
        guard let sourceVolume = source.volume else { throw HTTPError(status: 409, message: "源路径不存在") }

        let destination = try parseDestination(request)
        guard let targetVolume = destination.volume else { throw HTTPError(status: 409, message: "目标目录不存在") }
        guard destination.logicalPath != LogicalPath.root else { throw HTTPError(status: 403, message: "目标不能是卷根") }

        let overwrite = (request.headers["overwrite"] ?? "T").uppercased() != "F"
        let targetName = LogicalPath.lastSegment(destination.logicalPath)
        let targetDir = LogicalPath.parent(destination.logicalPath)
        guard currentFolderExists(volumeId: targetVolume.id, path: targetDir) else {
            throw HTTPError(status: 409, message: "目标文件夹不存在")
        }

        let existingTargetFile = currentEntry(volumeId: targetVolume.id, path: destination.logicalPath)
        let existingTargetFolder = currentFolderExists(volumeId: targetVolume.id, path: destination.logicalPath)
        if (existingTargetFile != nil || existingTargetFolder), !overwrite {
            throw HTTPError(status: 412, message: "目标已存在，且要求不覆盖")
        }
        // 覆盖：先把目标清掉
        if let existing = existingTargetFile {
            try store.deleteEntry(volumeId: targetVolume.id, entryId: existing.id)
        } else if existingTargetFolder {
            _ = try store.deleteFolder(volumeId: targetVolume.id, path: destination.logicalPath)
        }

        let sourceName = LogicalPath.lastSegment(source.logicalPath)
        let sameParent = sourceVolume.id == targetVolume.id && LogicalPath.parent(source.logicalPath) == targetDir

        if let entry = currentEntry(volumeId: sourceVolume.id, path: source.logicalPath) {
            // 文件
            if sameParent, !copy {
                try store.renameEntry(volumeId: sourceVolume.id, entryId: entry.id, newName: targetName)
            } else {
                let summary = try store.transfer(fromVolumeId: sourceVolume.id, entryIds: [entry.id], folderPaths: [],
                                                 toVolumeId: targetVolume.id, toPath: targetDir, copy: copy)
                if let createdId = summary.createdIds.first, sourceName != targetName {
                    try store.renameEntry(volumeId: targetVolume.id, entryId: createdId, newName: targetName)
                }
            }
        } else if currentFolderExists(volumeId: sourceVolume.id, path: source.logicalPath) {
            // 文件夹
            if sameParent, !copy {
                _ = try store.renameFolder(volumeId: sourceVolume.id, path: source.logicalPath, newName: targetName)
            } else {
                let summary = try store.transfer(fromVolumeId: sourceVolume.id, entryIds: [], folderPaths: [source.logicalPath],
                                                 toVolumeId: targetVolume.id, toPath: targetDir, copy: copy)
                if let createdPath = summary.createdPaths.first, sourceName != targetName {
                    _ = try store.renameFolder(volumeId: targetVolume.id, path: createdPath, newName: targetName)
                }
            }
        } else {
            throw HTTPError(status: 404, message: "源资源不存在")
        }

        return HTTPResponse(status: (existingTargetFile != nil || existingTargetFolder) ? 204 : 201, body: .empty)
    }

    private func parseDestination(_ request: HTTPRequest) throws -> ParsedPath {
        guard let raw = request.headers["destination"], !raw.isEmpty else {
            throw HTTPError(status: 400, message: "缺少 Destination 头")
        }
        var path = raw
        if let range = raw.range(of: "://") {
            let afterScheme = raw[range.upperBound...]
            if let slash = afterScheme.firstIndex(of: "/") {
                path = String(afterScheme[slash...])
            } else {
                path = "/"
            }
        }
        return parse(path: path)
    }

    // MARK: - 工具

    private static func escape(_ text: String) -> String {
        var out = text
        out = out.replacingOccurrences(of: "&", with: "&amp;")
        out = out.replacingOccurrences(of: "<", with: "&lt;")
        out = out.replacingOccurrences(of: ">", with: "&gt;")
        out = out.replacingOccurrences(of: "\"", with: "&quot;")
        out = out.replacingOccurrences(of: "'", with: "&apos;")
        return out
    }

    private func encodeSegment(_ segment: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#[]@!$&'()*+,;=")
        return segment.addingPercentEncoding(withAllowedCharacters: allowed) ?? segment
    }

    /// 生成规范 href：卷根 → /dav/<卷>/，文件 → /dav/<卷>/a/b.txt（集合带结尾斜杠）
    private func href(volumeSegment: String?, logicalPath: String, isCollection: Bool) -> String {
        var path = Self.prefix
        if let volumeSegment {
            path += "/" + encodeSegment(volumeSegment)
            if logicalPath != LogicalPath.root {
                for segment in LogicalPath.segments(logicalPath) {
                    path += "/" + encodeSegment(segment)
                }
            }
        }
        if isCollection { path += "/" }
        return path
    }
}
