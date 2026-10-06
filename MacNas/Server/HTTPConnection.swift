//
//  HTTPConnection.swift
//  MacNas
//
//  单条 TCP 连接上的 HTTP/1.1 状态机：解析请求头 → 流式接收请求体 → 写回响应 → 支持 keep-alive。
//

import Foundation
import Network

protocol HTTPRequestHandler: AnyObject {
    /// 请求体到达前决定怎么接收（上传走文件，其余走内存）
    func makeBodySink(for head: HTTPRequestHead, tempDirectory: URL) throws -> BodySink?
    func handle(_ request: HTTPRequest) -> HTTPResponse
}

final class HTTPConnection: @unchecked Sendable {

    private let connection: NWConnection
    private let queue: DispatchQueue
    private let handler: HTTPRequestHandler
    private let tempDirectory: URL
    private weak var owner: HTTPServer?

    private var buffer = Data()
    private var head: HTTPRequestHead?
    private var sink: BodySink?
    private var remaining: Int64 = 0
    private var keepAlive = true
    private var isResponding = false
    private var closed = false
    private var remoteAddress = "-"

    init(connection: NWConnection,
         queue: DispatchQueue,
         handler: HTTPRequestHandler,
         tempDirectory: URL,
         owner: HTTPServer) {
        self.connection = connection
        self.queue = queue
        self.handler = handler
        self.tempDirectory = tempDirectory
        self.owner = owner
    }

    // MARK: - 生命周期

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                if case let .hostPort(host, _) = self.connection.endpoint {
                    self.remoteAddress = "\(host)"
                }
                self.receiveNext()
            case .failed:
                self.finish()
            case .cancelled:
                self.finish()
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    func forceClose() {
        connection.cancel()
        finish()
    }

    private func finish() {
        guard !closed else { return }
        closed = true
        if let sink { sink.abort() }
        sink = nil
        owner?.connectionDidClose(ObjectIdentifier(self))
    }

    private func close() {
        connection.cancel()
        finish()
    }

    // MARK: - 接收

    private func receiveNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 256 * 1024) { [weak self] data, _, isComplete, error in
            guard let self, !self.closed else { return }
            if let error {
                LogCenter.shared.debug("接收数据出错：\(error.localizedDescription)")
                self.close()
                return
            }
            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.processBuffer()
            }
            if isComplete {
                self.close()
            } else if !self.closed {
                self.receiveNext()
            }
        }
    }

    // MARK: - 状态机

    private func processBuffer() {
        if closed || isResponding { return }

        while true {
            if head == nil {
                switch HTTPRequestHead.parse(buffer) {
                case .incomplete:
                    return

                case .invalid(let message):
                    keepAlive = false
                    LogCenter.shared.warn("收到非法请求：\(message)")
                    startResponse(.failure(400, message), forceClose: true)
                    return

                case .ok(let parsed, let consumed):
                    buffer.removeFirst(consumed)
                    head = parsed
                    keepAlive = parsed.wantsKeepAlive

                    if parsed.isChunked {
                        head = nil
                        startResponse(.failure(411, "不支持 Transfer-Encoding: chunked，请使用 Content-Length"),
                                      forceClose: true)
                        return
                    }
                    if parsed.expectsContinue, parsed.contentLength > 0 {
                        connection.send(content: Data("HTTP/1.1 100 Continue\r\n\r\n".utf8),
                                        completion: .contentProcessed { _ in })
                    }
                    if parsed.contentLength > 0 {
                        do {
                            guard let newSink = try handler.makeBodySink(for: parsed, tempDirectory: tempDirectory) else {
                                head = nil
                                startResponse(.failure(400, "该请求不应包含请求体"), forceClose: true)
                                return
                            }
                            sink = newSink
                            remaining = parsed.contentLength
                        } catch let error as HTTPError {
                            head = nil
                            startResponse(.failure(error.status, error.message), forceClose: true)
                            return
                        } catch {
                            head = nil
                            startResponse(.failure(500, "服务器内部错误"), forceClose: true)
                            return
                        }
                    } else {
                        completeRequest(body: .none)
                        return
                    }
                }
            }

            guard let activeSink = sink else { return }

            if remaining > 0 {
                guard !buffer.isEmpty else { return }
                let take = Int(min(remaining, Int64(buffer.count)))
                let chunk = Data(buffer.prefix(take))
                buffer.removeFirst(take)
                remaining -= Int64(take)
                do {
                    try activeSink.consume(chunk)
                } catch let error as HTTPError {
                    activeSink.abort()
                    sink = nil
                    remaining = 0
                    head = nil
                    startResponse(.failure(error.status, error.message), forceClose: true)
                    return
                } catch {
                    activeSink.abort()
                    sink = nil
                    remaining = 0
                    close()
                    return
                }
                if remaining > 0 { return }
            }

            let body: RequestBody
            do {
                body = try activeSink.finish()
            } catch {
                activeSink.abort()
                sink = nil
                close()
                return
            }
            sink = nil
            completeRequest(body: body)
            return
        }
    }

    private func completeRequest(body: RequestBody) {
        guard let parsed = head else { return }
        let request = HTTPRequest(method: parsed.method,
                                  path: parsed.path,
                                  query: parsed.query,
                                  headers: parsed.headers,
                                  cookies: parsed.cookies,
                                  body: body,
                                  remoteAddress: remoteAddress)
        let response = handler.handle(request)
        startResponse(response, forceClose: false)
    }

    // MARK: - 写响应

    private func startResponse(_ response: HTTPResponse, forceClose: Bool) {
        isResponding = true

        var headers = response.headers
        headers["Date"] = HTTPDate.string()
        headers["Server"] = "MacNas"
        headers["X-Content-Type-Options"] = "nosniff"
        if headers["Cache-Control"] == nil { headers["Cache-Control"] = "no-store" }
        let closeAfter = response.closeConnection || !keepAlive || forceClose
        headers["Connection"] = closeAfter ? "close" : "keep-alive"

        let payloadLength: Int64
        switch response.body {
        case .empty: payloadLength = 0
        case .data(let data): payloadLength = Int64(data.count)
        case .file(_, _, let length): payloadLength = length
        }
        headers["Content-Length"] = "\(payloadLength)"

        var headerText = "HTTP/1.1 \(response.status) \(HTTPResponse.statusText(response.status))\r\n"
        for (key, value) in headers.sorted(by: { $0.key < $1.key }) {
            headerText += "\(key): \(value)\r\n"
        }
        headerText += "\r\n"

        let isHeadRequest = head?.isHead ?? false
        if isHeadRequest || payloadLength == 0 {
            send(data: Data(headerText.utf8), isComplete: true)
            finishResponse(closeAfter: closeAfter)
            return
        }

        connection.send(content: Data(headerText.utf8),
                        contentContext: .defaultMessage,
                        isComplete: false,
                        completion: .contentProcessed { [weak self] error in
            guard let self else { return }
            if error != nil {
                self.close()
                return
            }
            switch response.body {
            case .file(let url, let offset, let length):
                self.streamFile(url: url, offset: offset, length: length, closeAfter: closeAfter)
            case .data(let data):
                self.send(data: data, isComplete: true)
                self.finishResponse(closeAfter: closeAfter)
            case .empty:
                self.finishResponse(closeAfter: closeAfter)
            }
        })
    }

    private func send(data: Data, isComplete: Bool) {
        connection.send(content: data,
                        contentContext: .defaultMessage,
                        isComplete: isComplete,
                        completion: .contentProcessed { [weak self] error in
            if error != nil { self?.close() }
        })
    }

    private func streamFile(url: URL, offset: Int64, length: Int64, closeAfter: Bool) {
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            LogCenter.shared.error("下载失败，无法打开文件：\(url.path)")
            close()
            return
        }
        if offset > 0 { try? handle.seek(toOffset: UInt64(offset)) }

        var remainingBytes = length

        func sendChunk() {
            if closed {
                try? handle.close()
                return
            }
            if remainingBytes <= 0 {
                try? handle.close()
                connection.send(content: nil,
                                contentContext: .finalMessage,
                                isComplete: true,
                                completion: .contentProcessed { [weak self] _ in
                    self?.finishResponse(closeAfter: closeAfter)
                })
                return
            }
            let want = Int(min(remainingBytes, 256 * 1024))
            let chunk = (try? handle.read(upToCount: want)) ?? Data()
            if chunk.isEmpty {
                // 文件在传输中被截断
                try? handle.close()
                connection.send(content: nil, contentContext: .finalMessage, isComplete: true,
                                completion: .contentProcessed { [weak self] _ in self?.close() })
                return
            }
            remainingBytes -= Int64(chunk.count)
            let isLast = remainingBytes <= 0
            connection.send(content: chunk,
                            contentContext: .defaultMessage,
                            isComplete: isLast,
                            completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                if error != nil {
                    try? handle.close()
                    self.close()
                    return
                }
                if isLast {
                    try? handle.close()
                    self.finishResponse(closeAfter: closeAfter)
                } else {
                    sendChunk()
                }
            })
        }

        sendChunk()
    }

    private func finishResponse(closeAfter: Bool) {
        head = nil
        sink = nil
        remaining = 0
        isResponding = false
        if closeAfter {
            close()
        } else if !closed {
            processBuffer()
        }
    }
}
