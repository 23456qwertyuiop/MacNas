//
//  SettingsView.swift
//  MacNas
//
//  账号密码与端口只能在这里（软件内）修改；网页端没有任何修改入口。
//

import SwiftUI
import AppKit

struct SettingsView: View {
    @Environment(AppState.self) private var app

    @State private var username = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var portText = ""
    @State private var autoStart = true
    @State private var webdavEnabled = true
    @State private var webdavReadOnly = false
    @State private var trashDays = 30
    @State private var newKeyName = ""
    @State private var newKeyWrite = false
    @State private var newKeyDays = 0
    @State private var freshKeyPlaintext: String?
    @State private var corsField = ""
    @State private var corsSaved = false
    @State private var mirrorReport: String?
    @State private var mirrorError = false
    @State private var mirrorHardlink = true
    @State private var mirrorBusy = false
    @State private var webdavTestResult: String?
    @State private var webdavTestOK = false
    @State private var message: String?
    @State private var messageIsError = false
    @State private var showResetConfirm = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                accountCard
                portCard
                apiCard
                fastWriteCard
                mirrorCard
                trashCard
                webdavCard
                generalCard
                aboutCard
            }
            .padding(22)
        }
        .onAppear {
            username = app.config.username
            portText = String(app.config.port)
            autoStart = app.config.autoStartServer
            trashDays = app.config.trashRetentionDays
            webdavEnabled = app.config.webdavEnabled
            webdavReadOnly = app.config.webdavReadOnly
        }
    }

    private var accountCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                SectionTitle(text: "账号与密码",
                             subtitle: "修改后所有网页登录状态会失效，需要用新密码重新登录")
                MaterialField(title: "账号", systemImage: "person.fill", text: $username)
                MaterialField(title: "新密码", systemImage: "lock.fill", text: $password, isSecure: true, prompt: "至少 4 位")
                MaterialField(title: "确认新密码", systemImage: "lock.rotation", text: $confirmPassword, isSecure: true)
                HStack {
                    Button("保存账号密码") { saveCredentials() }
                        .buttonStyle(PrimaryButtonStyle())
                    if let message {
                        Text(message)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(messageIsError ? Palette.danger : Palette.success)
                    }
                }
            }
        }
    }

    private var portCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                SectionTitle(text: "网站端口",
                             subtitle: "端口只在这里修改；保存后网站会用新端口重新开放")
                HStack(alignment: .bottom, spacing: 12) {
                    MaterialField(title: "端口", systemImage: "network", text: $portText)
                        .frame(width: 180)
                    if let port = UInt16(portText), port >= 1024 {
                        if NetworkInfo.isPortAvailable(port) {
                            StatusPill(text: "端口可用", color: Palette.success)
                        } else if port == app.config.port {
                            StatusPill(text: "当前正在使用", color: Palette.accent)
                        } else {
                            StatusPill(text: "端口被占用", color: Palette.danger)
                        }
                    } else {
                        StatusPill(text: "1024 以上", color: Palette.warning)
                    }
                    Button("保存并重新开放") { savePort() }
                        .buttonStyle(PrimaryButtonStyle())
                }
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(app.accessAddresses, id: \.self) { address in
                        Text(address)
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                    }
                }
            }
        }
    }

    // MARK: - 开发者 API

    private var apiCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                SectionTitle(text: "开发者 API",
                             subtitle: "给外部程序用的 HTTP 接口：列目录、下载、搜索、上传、改名、移动、删除")

                Text("文档见仓库的 docs/API.md，或介绍站的「开发者 API」页面。接口前缀 /api/v1，用下面的 key 鉴权（Bearer）。删除操作只进回收站，第三方无法彻底删除或清空回收站。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                // 已有 key 列表
                if app.apiKeysList.isEmpty {
                    Text("还没有生成过 API Key。")
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(app.apiKeysList, id: \.id) { key in
                            HStack(spacing: 10) {
                                Image(systemName: key.canWrite ? "key.fill" : "key")
                                    .font(.system(size: 11))
                                    .foregroundStyle(key.enabled && !key.isExpired ? Palette.accent : Palette.warning)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(key.name).font(.system(size: 12, weight: .medium))
                                    Text(keyDetailText(key))
                                        .font(.system(size: 10.5, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                Button("撤销") { app.revokeAPIKey(id: key.id) }
                                    .buttonStyle(SecondaryButtonStyle())
                            }
                        }
                    }
                }

                Divider().opacity(0.4)

                // 新建
                HStack(spacing: 10) {
                    TextField("应用名字，例如：我的备份脚本", text: $newKeyName)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12))
                    Toggle("读写权限", isOn: $newKeyWrite)
                        .toggleStyle(.switch)
                        .font(.system(size: 11.5))
                        .help("关掉表示只读：只能列目录、下载、搜索、看预览")
                    HStack(spacing: 4) {
                        Text("有效").font(.system(size: 11.5)).foregroundStyle(.secondary)
                        TextField("0", value: $newKeyDays, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 46)
                            .font(.system(size: 11.5))
                        Text("天").font(.system(size: 11.5)).foregroundStyle(.secondary)
                    }
                    Button("生成 Key") {
                        let scopes = newKeyWrite ? ["read", "write"] : ["read"]
                        if let created = app.createAPIKey(name: newKeyName,
                                                          scopes: scopes,
                                                          expiresInDays: newKeyDays > 0 ? newKeyDays : nil) {
                            freshKeyPlaintext = created.plaintext
                            newKeyName = ""
                        }
                    }
                    .buttonStyle(PrimaryButtonStyle())
                }

                if let freshKeyPlaintext {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("这把 key 只显示这一次，请立刻复制走：")
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(Palette.warning)
                        HStack(spacing: 8) {
                            Text(freshKeyPlaintext)
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Button("复制") {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(freshKeyPlaintext, forType: .string)
                                app.toast = "API Key 已复制"
                            }
                            .buttonStyle(SecondaryButtonStyle())
                            Button("知道了") { self.freshKeyPlaintext = nil }
                                .buttonStyle(SecondaryButtonStyle())
                        }
                        .padding(10)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Palette.warning.opacity(0.1)))
                    }
                }

                Divider().opacity(0.4)

                // 跨域白名单
                VStack(alignment: .leading, spacing: 6) {
                    Text("允许跨域调用 API 的来源（可选）")
                        .font(.system(size: 12, weight: .medium))
                    Text("默认不开 CORS：API Key 落到浏览器页面里等于把钥匙交给那个网页。只有你信任的网页才填进来，多个用逗号分隔，例如 http://localhost:5173")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 8) {
                        TextField("留空表示不开放跨域", text: $corsField)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11.5))
                        Button("保存") {
                            let origins = corsField
                                .split(separator: ",")
                                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                                .filter { !$0.isEmpty }
                            app.setAPICORSOrigins(origins)
                            corsSaved = true
                            app.toast = origins.isEmpty ? "已关闭跨域访问" : "已允许 \(origins.count) 个来源跨域访问"
                        }
                        .buttonStyle(SecondaryButtonStyle())
                    }
                    if corsSaved {
                        Text(app.config.apiCorsOrigins.isEmpty
                             ? "当前：不开放跨域"
                             : "当前允许：" + app.config.apiCorsOrigins.joined(separator: "、"))
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .onAppear {
            corsField = app.config.apiCorsOrigins.joined(separator: ", ")
        }
    }

    private func keyDetailText(_ key: APIKeyRecord) -> String {
        var parts = [key.prefix, key.canWrite ? "读写" : "只读"]
        if key.isExpired {
            parts.append("已过期")
        } else if let expiresAt = key.expiresAt {
            let formatter = DateFormatter()
            formatter.dateFormat = "MM-dd"
            parts.append("至 " + formatter.string(from: expiresAt))
        }
        parts.append("调用 \(key.requestCount) 次")
        if let last = key.lastUsedAt {
            let formatter = DateFormatter()
            formatter.dateFormat = "MM-dd HH:mm"
            parts.append("最后 " + formatter.string(from: last))
        } else {
            parts.append("还没用过")
        }
        return parts.joined(separator: " · ")
    }

    private var fastWriteCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                SectionTitle(text: "写入性能（格式 v2 追加日志）",
                             subtitle: "启用后，日常改动只追加一小段日志，不再每次重写整份索引")

                Text("实测：5,000 个文件时，旧写法每存一条要重写整份索引（约 75ms/条，总共 173 秒）；启用追加日志后是 5.6ms/条（14 秒）。文件越多差距越大。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(app.config.volumes) { volume in
                        HStack(spacing: 10) {
                            Image(systemName: app.usesJournal(volumeId: volume.id) ? "bolt.fill" : "tortoise")
                                .font(.system(size: 11))
                                .foregroundStyle(app.usesJournal(volumeId: volume.id) ? Palette.success : Palette.warning)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(volume.name).font(.system(size: 12, weight: .medium))
                                Text(app.usesJournal(volumeId: volume.id) ? "已启用追加日志（格式 v2）" : "仍是旧格式 v1：每次改动都会重写整份索引")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if app.usesJournal(volumeId: volume.id) {
                                Button("整理索引") { app.compactIndex(volumeId: volume.id) }
                                    .buttonStyle(SecondaryButtonStyle())
                            } else {
                                Button("启用快速写入") { app.enableFastWrites(volumeId: volume.id) }
                                    .buttonStyle(SecondaryButtonStyle())
                            }
                        }
                    }
                }

                Text("注意：启用后这个目录会被标记为格式 v2，**旧版 MacNas 只能只读打开它**（不会破坏数据，但不能再写入）。目录结构本身完全不变，只是 info/ 里多一个 index.log。")
                    .font(.system(size: 11))
                    .foregroundStyle(Palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var mirrorCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                SectionTitle(text: "镜像导出（给 SMB / Time Machine 用）",
                             subtitle: "把逻辑目录铺成一份真实文件夹，同一磁盘上用硬链接，几乎不占额外空间")

                Text("MacNas 的逻辑目录只存在于索引里，macOS 自带的「文件共享」和 Time Machine 认不出它。导出之后：在「系统设置 → 通用 → 共享 → 文件共享」里共享导出目录，其它设备就能通过 SMB 访问；Time Machine 也能备份它。")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Toggle("优先使用硬链接（同一磁盘推荐；跨磁盘会自动改成复制）", isOn: $mirrorHardlink)
                    .toggleStyle(.switch)
                    .font(.system(size: 12))

                VStack(alignment: .leading, spacing: 8) {
                    ForEach(app.config.volumes) { volume in
                        HStack(spacing: 10) {
                            Image(systemName: "externaldrive")
                                .font(.system(size: 11))
                                .foregroundStyle(Palette.accent)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(volume.name).font(.system(size: 12, weight: .medium))
                                Text(volume.path)
                                    .font(.system(size: 10.5, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            Spacer()
                            Button("导出镜像…") { chooseMirrorTarget(for: volume) }
                                .buttonStyle(SecondaryButtonStyle())
                                .disabled(mirrorBusy)
                        }
                    }
                }

                if mirrorBusy {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("正在导出…").font(.system(size: 11.5))
                    }
                }
                if let mirrorReport {
                    Text(mirrorReport)
                        .font(.system(size: 11))
                        .foregroundStyle(mirrorError ? Palette.danger : Palette.success)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text("提示：镜像是「给别人看的视图」，不是真相来源。在 MacNas 里改名/删除之后重新导出一次即可，已是最新的文件会被跳过。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func chooseMirrorTarget(for volume: Volume) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "导出到这个文件夹"
        panel.message = "选择一个用于存放镜像的文件夹（建议放在同一块磁盘上，这样硬链接不占额外空间）"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        mirrorBusy = true
        mirrorReport = nil
        app.exportMirror(volumeId: volume.id, target: url, preferHardlink: mirrorHardlink) { result in
            mirrorBusy = false
            switch result {
            case .success(let report):
                mirrorError = report.failures.isEmpty ? false : true
                mirrorReport = "已导出到 \(report.target)\n" + report.summary +
                    (report.failures.isEmpty ? "" : "\n有 \(report.failures.count) 个文件失败：\(report.failures.prefix(3).joined(separator: "；"))")
            case .failure(let error):
                mirrorError = true
                mirrorReport = "导出失败：\(error.localizedDescription)"
            }
        }
    }

    private var trashCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                SectionTitle(text: "回收站",
                             subtitle: "删除的文件会先放进回收站，可以随时还原；超过保留期自动清理")

                HStack(spacing: 12) {
                    Text("保留天数")
                        .font(.system(size: 12))
                    TextField("", value: $trashDays, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 80)
                    Text(trashDays > 0 ? "天后自动清理" : "不自动清理")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("保存") {
                        app.setTrashRetention(days: max(0, trashDays))
                        trashDays = app.config.trashRetentionDays
                        message = "回收站保留期已保存"
                        messageIsError = false
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }

                Text("提示：彻底删除才会回收磁盘空间。若同一份内容还被别处的文件（或历史版本）引用，那一份不会被删。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var webdavCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                SectionTitle(text: "WebDAV 共享",
                             subtitle: "在 Finder 里像网络磁盘一样挂载，读写都会走进同一套去重存储")

                Toggle("启用 WebDAV 共享", isOn: $webdavEnabled)
                    .toggleStyle(.switch)
                    .font(.system(size: 12))
                    .onChange(of: webdavEnabled) { _, _ in applyWebDAV() }

                Toggle("只读模式（禁止上传、改名、删除）", isOn: $webdavReadOnly)
                    .toggleStyle(.switch)
                    .font(.system(size: 12))
                    .disabled(!webdavEnabled)
                    .onChange(of: webdavReadOnly) { _, _ in applyWebDAV() }

                VStack(alignment: .leading, spacing: 8) {
                    HStack(alignment: .center, spacing: 10) {
                        Text(app.webdavAddressText)
                            .font(.system(size: 12, design: .monospaced))
                            .textSelection(.enabled)
                        Button("复制地址") { app.copyToPasteboard(app.webdavAddressText) }
                            .buttonStyle(SecondaryButtonStyle())
                        Button("自检") {
                            webdavTestResult = "正在自检…"
                            app.testWebDAV { ok, message in
                                webdavTestOK = ok
                                webdavTestResult = message
                            }
                        }
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(!webdavEnabled)
                    }
                    if let webdavTestResult {
                        Text(webdavTestResult)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(webdavTestOK ? Palette.success : Palette.danger)
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))

                VStack(alignment: .leading, spacing: 6) {
                    Text("怎么挂载：Finder 里按 ⌘K → 输入上面的地址 → 用这里的账号密码登录。")
                    Text("挂载后看到的目录结构与网页端完全一致（不是磁盘上的哈希文件名）。")
                    Text("提醒：WebDAV 用的是 HTTP Basic 认证，密码在局域网内是明文传输；只在可信网络里开启，或自行加一层 HTTPS 反向代理。")
                        .foregroundStyle(Palette.warning)
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
        }
    }

    private func applyWebDAV() {
        app.setWebDAV(enabled: webdavEnabled, readOnly: webdavReadOnly)
        message = webdavEnabled ? "WebDAV 已更新" : "WebDAV 已关闭"
        messageIsError = false
    }

    private var generalCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(text: "常规")
                Toggle("打开软件时自动开放网站", isOn: $autoStart)
                    .toggleStyle(.switch)
                    .font(.system(size: 12))
                    .onChange(of: autoStart) { _, newValue in
                        app.setAutoStart(newValue)
                    }
                HStack(spacing: 10) {
                    Button("打开配置目录") {
                        NSWorkspace.shared.activateFileViewerSelecting([AppPaths.supportDirectory])
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    Button("打开日志目录") {
                        NSWorkspace.shared.activateFileViewerSelecting([AppPaths.currentLogURL])
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }
            }
        }
    }

    private var aboutCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(text: "关于与重置")
                KeyValueRow(label: "版本", value: "MacNas \(MacNasInfo.version)")
                KeyValueRow(label: "配置文件", value: AppPaths.configURL.path, monospaced: true)
                Text("重置只会清除本机配置（账号、密码、端口、目录列表），磁盘上的 document 与 info 不会被删除；重置后可以用「打开已有目录」把原来的目录读回来。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Button("清除配置并重新初始化") { showResetConfirm = true }
                    .buttonStyle(SecondaryButtonStyle())
            }
        }
        .alert("清除本机配置？", isPresented: $showResetConfirm) {
            Button("取消", role: .cancel) { }
            Button("清除并重新初始化", role: .destructive) { app.resetConfiguration() }
        } message: {
            Text("账号、密码、端口与目录列表会被清除，网站会停止。磁盘上的文件不受影响。")
        }
    }

    private func saveCredentials() {
        guard password == confirmPassword else {
            message = "两次输入的密码不一致"
            messageIsError = true
            return
        }
        if let error = app.updateCredentials(username: username, password: password) {
            message = error
            messageIsError = true
        } else {
            password = ""
            confirmPassword = ""
            message = "已保存"
            messageIsError = false
            app.toast = "账号密码已更新"
        }
    }

    private func savePort() {
        guard let port = UInt16(portText) else {
            message = "端口必须是数字"
            messageIsError = true
            return
        }
        if let error = app.updatePort(port) {
            message = error
            messageIsError = true
        } else {
            message = "已保存"
            messageIsError = false
            app.toast = "端口已更新为 \(port)"
        }
    }
}
