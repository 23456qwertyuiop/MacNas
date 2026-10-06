//
//  HTTPServer.swift
//  MacNas
//
//  基于 Network.framework 的 HTTP/1.1 服务器（监听用户在软件里设定的端口）。
//

import Foundation
import Network

final class HTTPServer: @unchecked Sendable {

    enum State: Equatable {
        case stopped
        case starting
        case running(UInt16)
        case failed(String)

        var isRunning: Bool { if case .running = self { return true }; return false }

        var displayText: String {
            switch self {
            case .stopped: return "已停止"
            case .starting: return "启动中…"
            case .running(let port): return "运行中 · 端口 \(port)"
            case .failed(let message): return "启动失败：\(message)"
            }
        }
    }

    private let queue = DispatchQueue(label: "cn.zenlc.macnas.http")
    private let handler: HTTPRequestHandler
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: HTTPConnection] = [:]
    private var stopping = false

    private let stateLock = NSLock()
    private var _state: State = .stopped

    private let tempDirectory: URL

    var onStateChange: ((State) -> Void)?
    private(set) var port: UInt16 = 0

    var state: State {
        stateLock.lock()
        defer { stateLock.unlock() }
        return _state
    }

    init(handler: HTTPRequestHandler, tempDirectory: URL = AppPaths.uploadsDirectory) {
        self.handler = handler
        self.tempDirectory = tempDirectory
    }

    var isRunning: Bool { state.isRunning }

    // MARK: - 启停

    func start(port: UInt16) throws {
        stop()
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else {
            throw HTTPError(status: 400, message: "端口不合法")
        }

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.includePeerToPeer = false

        let listener: NWListener
        do {
            listener = try NWListener(using: parameters, on: endpointPort)
        } catch {
            let message = "端口 \(port) 无法使用：\(error.localizedDescription)"
            updateState(.failed(message))
            throw HTTPError(status: 500, message: message)
        }

        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { [weak self] newState in
            self?.handleListenerState(newState, requestedPort: port)
        }

        stopping = false
        self.listener = listener
        self.port = port
        updateState(.starting)
        listener.start(queue: queue)
    }

    func stop() {
        stopping = true
        listener?.stateUpdateHandler = nil
        listener?.cancel()
        listener = nil
        let active = connections.values
        connections.removeAll()
        for connection in active { connection.forceClose() }
        if state != .stopped { updateState(.stopped) }
        stopping = false
    }

    // MARK: - 连接

    private func accept(_ connection: NWConnection) {
        // 每条连接一个独立队列：WebDAV 客户端（Finder）会同时开十几条连接探测，
        // 如果全部串在同一条队列上，后面的连接会被前面的请求（尤其是首次密码验证）堵住而超时。
        let connectionQueue = DispatchQueue(label: "cn.zenlc.macnas.http.connection")
        let httpConnection = HTTPConnection(connection: connection,
                                            queue: connectionQueue,
                                            handler: handler,
                                            tempDirectory: tempDirectory,
                                            owner: self)
        connections[ObjectIdentifier(httpConnection)] = httpConnection
        httpConnection.start()
    }

    func connectionDidClose(_ id: ObjectIdentifier) {
        queue.async { [weak self] in
            self?.connections.removeValue(forKey: id)
        }
    }

    // MARK: - 状态

    private func handleListenerState(_ newState: NWListener.State, requestedPort: UInt16) {
        switch newState {
        case .ready:
            let actual = listener?.port?.rawValue ?? requestedPort
            self.port = actual
            if !state.isRunning {
                LogCenter.shared.info("网站已开放：http://0.0.0.0:\(actual)")
            }
            updateState(.running(actual))

        case .failed(let error):
            let message = error.localizedDescription
            updateState(.failed(message))
            LogCenter.shared.error("网站启动失败：\(message)")
            listener?.stateUpdateHandler = nil
            listener?.cancel()
            listener = nil

        case .cancelled:
            if !stopping { updateState(.stopped) }

        default:
            break
        }
    }

    private func updateState(_ newState: State) {
        stateLock.lock()
        let changed = _state != newState
        _state = newState
        stateLock.unlock()
        guard changed else { return }
        let callback = onStateChange
        DispatchQueue.main.async { callback?(newState) }
    }
}
