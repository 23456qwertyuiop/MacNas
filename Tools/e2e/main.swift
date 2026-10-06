//
//  main.swift
//  MacNas 端到端测试入口（不依赖 GUI）
//
//  用法：macnas-e2e <目录根[,目录根2,...]> <端口> [账号] [密码]
//  编译：swiftc MacNas/Core/*.swift MacNas/Server/*.swift Tools/e2e/main.swift -o macnas-e2e
//
//  这个可执行文件只用于开发期验证：它把真实 HTTP 服务器跑起来，
//  方便用 curl 直接测试上传 / 去重 / 下载 / 删除等逻辑。
//

import Foundation

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    FileHandle.standardError.write(Data("usage: macnas-e2e <root[,root2]> <port> [user] [pass]\n".utf8))
    exit(2)
}

let rootPaths = arguments[1].split(separator: ",").map(String.init)
let port = UInt16(arguments[2]) ?? 18080
let username = arguments.count > 3 ? arguments[3] : "admin"
let password = arguments.count > 4 ? arguments[4] : "1234"

AppPaths.ensureDirectories()
AppPaths.clearStaleUploads()

let rootURL = URL(fileURLWithPath: rootPaths[0], isDirectory: true)
try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

// 与软件端一致：先尝试读回已有目录（document + info），否则新建
var volumes: [Volume] = []
for path in rootPaths {
    let url = URL(fileURLWithPath: path, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    let volume = VolumeBootstrap.inspect(url).isMacNasVolume
        ? try VolumeBootstrap.open(url, fallbackName: url.lastPathComponent)
        : try VolumeBootstrap.prepare(url, name: url.lastPathComponent)
    volumes.append(volume)
    print("volume: \(volume.id) @ \(volume.path)")
}

let store = Store()
_ = store.setVolumes(volumes)

let auth = AuthManager()
let salt = PasswordHasher.makeSalt()
auth.updateCredentials(username: username, saltHex: salt, hashHex: PasswordHasher.derive(password: password, saltHex: salt))

let environment = ServerEnvironment()
if ProcessInfo.processInfo.environment["MACNAS_WEBDAV_RO"] == "1" { environment.webdavReadOnly = true }
if ProcessInfo.processInfo.environment["MACNAS_WEBDAV"] == "0" { environment.webdavEnabled = false }
let shares = ShareStore()
let router = Router(store: store, auth: auth, environment: environment, shares: shares)
let server = HTTPServer(handler: router)

do {
    try server.start(port: port)
} catch {
    FileHandle.standardError.write(Data("start failed: \(error)\n".utf8))
    exit(1)
}

// 等待监听就绪
var ready = false
for _ in 0..<50 {
    if server.state.isRunning { ready = true; break }
    Thread.sleep(forTimeInterval: 0.1)
}
guard ready else {
    FileHandle.standardError.write(Data("server did not become ready\n".utf8))
    exit(1)
}

environment.port = port
environment.startedAt = Date()
print("READY port=\(port) user=\(username) support=\(AppPaths.supportDirectory.path)")
fflush(stdout)

signal(SIGINT) { _ in
    print("\nshutting down")
    exit(0)
}

RunLoop.main.run()
