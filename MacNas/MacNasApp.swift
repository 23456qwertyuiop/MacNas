//
//  MacNasApp.swift
//  MacNas
//

import SwiftUI
import AppKit

/// 让「点 Dock 图标 / 双击 App」永远能把窗口找回来。
///
/// 为什么需要它：MacNas 是「窗口关了但网站还要继续跑」的软件，
/// 用户按了 ⌘W 或关掉窗口之后进程还活着（这是有意的），
/// 但如果没有这段处理，之后再点图标就没有任何反应，看起来就像「软件点不开」。
final class AppDelegate: NSObject, NSApplicationDelegate {

    /// 已经在跑的那个实例收到这个通知就把窗口显示出来（跨进程，用来「点哪份都能出窗口」）
    static let showWindowNotification = Notification.Name("cn.zenlc.macnas.showWindow")

    /// 同一个 App 已经在运行时，把自己退掉、把对方的窗口叫出来。
    ///
    /// 为什么需要：MacNas 可能同时存在两份（Xcode 构建产物一份、/Applications 里一份）。
    /// 点其中一份时如果系统只是"激活"另一个实例，而那个实例又没有重开窗口的处理，
    /// 用户看到的就是「点了完全没反应」；两份还会抢同一个端口。
    private func foldIntoRunningInstanceIfNeeded() {
        // 测试/自检时可以显式要求开第二个实例
        if ProcessInfo.processInfo.environment["MACNAS_ALLOW_SECOND_INSTANCE"] == "1" { return }
        guard let bundleId = Bundle.main.bundleIdentifier, !bundleId.isEmpty else { return }
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: bundleId)
            .filter { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
        guard let running = others.first else { return }
        running.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        DistributedNotificationCenter.default().postNotificationName(Self.showWindowNotification,
                                                                    object: nil, userInfo: nil,
                                                                    deliverImmediately: true)
        LogCenter.shared.info("已经有一个 MacNas 在运行（PID \(running.processIdentifier)），把它的窗口叫到前台后退出本次启动")
        exit(0)
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        foldIntoRunningInstanceIfNeeded()
        DistributedNotificationCenter.default().addObserver(
            forName: Self.showWindowNotification, object: nil, queue: .main
        ) { _ in
            NSApp.activate(ignoringOtherApps: true)
            Self.bringMainWindowToFront(NSApp)
        }
    }

    /// 关掉最后一个窗口不退出：网站要继续服务其它设备
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // 不要让系统保存/恢复窗口状态：这个 App 允许「窗口关掉、服务继续跑」，
    // 一旦系统照着「上次没有窗口」恢复，启动后就会什么都不出现（看着像软件打不开）。
    func applicationShouldSaveApplicationState(_ sender: NSApplication) -> Bool { false }
    func applicationShouldRestoreApplicationState(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { Self.bringMainWindowToFront(sender) }
        NSApp.activate(ignoringOtherApps: true)
        return true
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 启动后主动把窗口推到前台：从命令行、后台或 LaunchServices 启动时，
        // 窗口有可能自己不出来（用户看到的就是「点了没反应」）。
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            Self.bringMainWindowToFront(NSApp)
        }
        // 兜底：万一还是没窗口（系统变化、状态异常），稍后再叫一次
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            Self.bringMainWindowToFront(NSApp)
        }
        // 极端情况：窗口被恢复到一块已经不存在的显示器上（外面拔了外接屏），
        // 这时窗口坐标会落在所有屏幕之外，用户看不到也点不到 —— 拉回主屏中间。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            Self.rescueOffscreenWindows(NSApp)
        }
    }

    static func bringMainWindowToFront(_ sender: NSApplication) {
        rescueOffscreenWindows(sender)
        let candidates = sender.windows.filter { $0.canBecomeMain && !($0 is NSPanel) }
        guard let window = candidates.first else { return }
        if window.isMiniaturized { window.deminiaturize(nil) }
        window.makeKeyAndOrderFront(nil)
    }

    static func rescueOffscreenWindows(_ sender: NSApplication) {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return }
        for window in sender.windows where window.canBecomeMain && !(window is NSPanel) {
            let visibleSomewhere = screens.contains { screen in
                screen.visibleFrame.intersects(window.frame.insetBy(dx: 40, dy: 40))
            }
            guard !visibleSomewhere else { continue }
            LogCenter.shared.warn("窗口不在任何屏幕上，已挪回主屏中央")
            let frame = screens[0].visibleFrame
            window.setFrame(NSRect(x: frame.midX - window.frame.width / 2,
                                   y: frame.midY - window.frame.height / 2,
                                   width: window.frame.width,
                                   height: window.frame.height), display: true)
        }
    }
}

@main
struct MacNasApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appState)
                .frame(minWidth: 1000, minHeight: 680)
                .tint(Palette.accent)
                .task { appState.bootstrap() }
        }
        .defaultSize(width: 1180, height: 800)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandMenu("服务") {
                Button(appState.serverState.isRunning ? "停止网站" : "启动网站") {
                    appState.toggleServer()
                }
                .keyboardShortcut("r", modifiers: [.command, .shift])

                Button("在浏览器中打开") { appState.openInBrowser() }
                    .keyboardShortcut("o", modifiers: [.command, .shift])

                Divider()

                Button("打开日志文件所在目录") {
                    NSWorkspace.shared.activateFileViewerSelecting([AppPaths.currentLogURL])
                }
                Button("打开配置目录") {
                    NSWorkspace.shared.activateFileViewerSelecting([AppPaths.supportDirectory])
                }
            }
        }
    }
}
