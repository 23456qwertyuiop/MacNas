//
//  HTTPMessage.swift
//  MacNas
//
//  极简 HTTP/1.1 报文模型与解析（只实现项目需要的部分）。
//

import Foundation

struct HTTPError: Error {
    var status: Int
    var message: String

    init(status: Int, message: String) {
        self.status = status
        self.message = message
    }
}

// MARK: - 请求头

struct HTTPRequestHead {
    var method: String
    var target: String
    var version: String
    var headers: [String: String]
    var path: String
    var rawQuery: String
    var query: [String: String]
    var cookies: [String: String]

    var contentLength: Int64 {
        Int64(headers["content-length"] ?? "") ?? 0
    }

    var isChunked: Bool {
        (headers["transfer-encoding"] ?? "").lowercased().contains("chunked")
    }

    var expectsContinue: Bool {
        (headers["expect"] ?? "").lowercased().contains("100-continue")
    }

    var isHead: Bool { method.uppercased() == "HEAD" }

    var wantsKeepAlive: Bool {
        let connection = (headers["connection"] ?? "").lowercased()
        if connection.contains("close") { return false }
        if version == "HTTP/1.0" { return connection.contains("keep-alive") }
        return true
    }

    enum ParseResult {
        case incomplete
        case invalid(String)
        case ok(HTTPRequestHead, consumed: Int)
    }

    static let maxHeadBytes = 64 * 1024

    static func parse(_ data: Data) -> ParseResult {
        guard let separator = data.range(of: Data("\r\n\r\n".utf8)) else {
            if data.count > maxHeadBytes { return .invalid("请求头过大") }
            // 容忍只有 \n 的客户端
            if let lfSeparator = data.range(of: Data("\n\n".utf8)) {
                return parseHead(data: data[data.startIndex..<lfSeparator.lowerBound], terminatorLength: data.distance(from: data.startIndex, to: lfSeparator.upperBound))
            }
            return .incomplete
        }
        let headBytes = data[data.startIndex..<separator.lowerBound]
        let consumed = data.distance(from: data.startIndex, to: separator.upperBound)
        return parseHead(data: headBytes, terminatorLength: consumed)
    }

    private static func parseHead(data: Data, terminatorLength: Int) -> ParseResult {
        guard let text = String(data: data, encoding: .utf8) else { return .invalid("请求头编码错误") }
        var lines = text.components(separatedBy: "\n").map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        while let last = lines.last, last.isEmpty { lines.removeLast() }
        guard let requestLine = lines.first, !requestLine.isEmpty else { return .invalid("请求行为空") }

        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 2 else { return .invalid("请求行格式错误") }
        let method = parts[0].uppercased()
        var target = parts[1]
        let version = parts.count >= 3 ? parts[2] : "HTTP/1.1"

        if let schemeRange = target.range(of: "://") {
            let afterScheme = target[schemeRange.upperBound...]
            if let slashIndex = afterScheme.firstIndex(of: "/") {
                target = String(afterScheme[slashIndex...])
            } else {
                target = "/"
            }
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            if key.isEmpty { continue }
            if let existing = headers[key] {
                headers[key] = existing + ", " + value
            } else {
                headers[key] = value
            }
        }

        var rawPath = target
        var rawQuery = ""
        if let questionMark = target.firstIndex(of: "?") {
            rawPath = String(target[target.startIndex..<questionMark])
            rawQuery = String(target[target.index(after: questionMark)...])
        }

        let path = rawPath.removingPercentEncoding ?? rawPath
        let query = parseQuery(rawQuery)
        let cookies = parseCookies(headers["cookie"] ?? "")

        let head = HTTPRequestHead(method: method,
                                  target: target,
                                  version: version,
                                  headers: headers,
                                  path: path.isEmpty ? "/" : path,
                                  rawQuery: rawQuery,
                                  query: query,
                                  cookies: cookies)
        return .ok(head, consumed: terminatorLength)
    }

    static func parseQuery(_ raw: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in raw.split(separator: "&", omittingEmptySubsequences: true) {
            let pieces = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let key = String(pieces[0]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String(pieces[0])
            let value = pieces.count > 1
                ? (String(pieces[1]).replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? String(pieces[1]))
                : ""
            if !key.isEmpty { result[key] = value }
        }
        return result
    }

    private static func parseCookies(_ header: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in header.split(separator: ";") {
            let pieces = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pieces.count == 2 else { continue }
            let key = pieces[0].trimmingCharacters(in: .whitespaces)
            let value = pieces[1].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { result[key] = value }
        }
        return result
    }
}

// MARK: - 请求

enum RequestBody {
    case none
    case data(Data)
    case file(URL, sha256: String, byteCount: Int64)
}

struct HTTPRequest {
    var method: String
    var path: String
    var query: [String: String]
    var headers: [String: String]
    var cookies: [String: String]
    var body: RequestBody
    var remoteAddress: String
    var requestedAt: Date = Date()

    var jsonBody: [String: Any]? {
        guard case .data(let data) = body else { return nil }
        guard !data.isEmpty else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    func jsonString(_ key: String) -> String? {
        jsonBody?[key] as? String
    }

    func jsonBool(_ key: String) -> Bool? {
        if let value = jsonBody?[key] as? Bool { return value }
        if let value = jsonBody?[key] as? NSNumber { return value.boolValue }
        return nil
    }
}

// MARK: - 响应

enum HTTPBody {
    case empty
    case data(Data)
    case file(url: URL, offset: Int64, length: Int64)
}

struct HTTPResponse {
    var status: Int
    var headers: [String: String]
    var body: HTTPBody
    var closeConnection: Bool

    init(status: Int = 200,
         headers: [String: String] = [:],
         body: HTTPBody = .empty,
         closeConnection: Bool = false) {
        self.status = status
        self.headers = headers
        self.body = body
        self.closeConnection = closeConnection
    }

    static func json(_ object: Any, status: Int = 200) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        var response = HTTPResponse(status: status, body: .data(data))
        response.headers["Content-Type"] = "application/json; charset=utf-8"
        return response
    }

    static func text(_ string: String, status: Int = 200, contentType: String = "text/plain; charset=utf-8") -> HTTPResponse {
        var response = HTTPResponse(status: status, body: .data(Data(string.utf8)))
        response.headers["Content-Type"] = contentType
        return response
    }

    static func ok(message: String = "ok") -> HTTPResponse {
        .json(["ok": true, "message": message])
    }

    static func failure(_ status: Int, _ message: String) -> HTTPResponse {
        .json(["ok": false, "error": message], status: status)
    }

    static func html(_ string: String) -> HTTPResponse {
        .text(string, contentType: "text/html; charset=utf-8")
    }

    static func statusText(_ code: Int) -> String {
        switch code {
        case 200: return "OK"
        case 201: return "Created"
        case 204: return "No Content"
        case 206: return "Partial Content"
        case 207: return "Multi-Status"
        case 301: return "Moved Permanently"
        case 302: return "Found"
        case 304: return "Not Modified"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 409: return "Conflict"
        case 411: return "Length Required"
        case 412: return "Precondition Failed"
        case 423: return "Locked"
        case 413: return "Payload Too Large"
        case 416: return "Range Not Satisfiable"
        case 429: return "Too Many Requests"
        case 500: return "Internal Server Error"
        case 507: return "Insufficient Storage"
        case 503: return "Service Unavailable"
        default: return "Unknown"
        }
    }
}

// MARK: - 工具

enum HTTPDate {
    private static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "GMT")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        return f
    }()

    static func string(_ date: Date = Date()) -> String { formatter.string(from: date) }
}

enum ISO8601 {
    static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func string(_ date: Date) -> String { formatter.string(from: date) }
    static func date(from text: String) -> Date? { formatter.date(from: text) }
}
