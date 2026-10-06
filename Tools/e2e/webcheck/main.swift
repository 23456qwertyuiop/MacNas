//
//  main.swift
//  MacNas 网页界面检查工具（开发期用）
//
//  用法：webcheck <url> <截图输出.png> [场景脚本.js] [宽] [高]
//
//  它用系统自带的 WebKit 真正渲染网页，先等页面加载完，再执行一段
//  JavaScript 场景（可以是 async/await，返回值会打印出来），最后截图存盘。
//  用来在没有浏览器自动化环境的情况下验证网页 DOM 与外观。
//

import Foundation
import AppKit
import WebKit

let arguments = CommandLine.arguments
guard arguments.count >= 3 else {
    FileHandle.standardError.write(Data("usage: webcheck <url> <out.png> [script.js] [width] [height]\n".utf8))
    exit(2)
}

let targetURL = URL(string: arguments[1])!
let outputURL = URL(fileURLWithPath: arguments[2])
let scriptPath = arguments.count > 3 && !arguments[3].isEmpty ? arguments[3] : nil
let width = arguments.count > 4 ? (Double(arguments[4]) ?? 1440) : 1440
let height = arguments.count > 5 ? (Double(arguments[5]) ?? 900) : 900

let script = scriptPath.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }

final class Checker: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    let window: NSWindow
    var finished = false

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: width, height: height), configuration: configuration)

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: width, height: height),
                          styleMask: [.borderless],
                          backing: .buffered,
                          defer: false)
        super.init()
        webView.navigationDelegate = self
        window.contentView = webView
        // 放到屏幕外，避免打扰正在使用电脑的人；WebKit 仍然会正常渲染
        window.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        window.orderFrontRegardless()
    }

    func start() {
        webView.load(URLRequest(url: targetURL))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !finished else { return }
        finished = true

        guard let script, !script.isEmpty else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { self.finish() }
            return
        }

        webView.callAsyncJavaScript(script,
                                    arguments: [:],
                                    in: nil,
                                    in: .page) { result in
            switch result {
            case .success(let value):
                print("JS 结果：\(value)")
            case .failure(let error):
                print("JS 失败：\(error.localizedDescription)")
                if let jsError = error as? WKError, let details = jsError.userInfo["WKJavaScriptExceptionMessage"] {
                    print("异常信息：\(details)")
                }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self.finish() }
        }
    }

    private func finish() {
        let configuration = WKSnapshotConfiguration()
        configuration.rect = NSRect(x: 0, y: 0, width: width, height: height)
        webView.takeSnapshot(with: configuration) { image, error in
            if let image,
               let tiff = image.tiffRepresentation,
               let bitmap = NSBitmapImageRep(data: tiff),
               let png = bitmap.representation(using: .png, properties: [:]) {
                try? png.write(to: outputURL)
                print("截图已保存：\(outputURL.path) (\(Int(image.size.width))x\(Int(image.size.height)))")
            } else {
                print("截图失败：\(error?.localizedDescription ?? "未知错误")")
            }
            exit(0)
        }
    }
}

let application = NSApplication.shared
application.setActivationPolicy(.accessory)
let checker = Checker()
checker.start()

DispatchQueue.main.asyncAfter(deadline: .now() + 90) {
    print("超时退出")
    exit(3)
}

application.run()
