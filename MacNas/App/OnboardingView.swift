//
//  OnboardingView.swift
//  MacNas
//
//  首次启动的初始化流程：选择第一个目录 → 设置账号密码 → 选择端口 → 开启网站。
//

import SwiftUI

struct OnboardingView: View {
    @Environment(AppState.self) private var app

    @State private var step = 0
    @State private var username = "admin"
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var portText = String(AppConfig.defaultPort)
    @State private var errorMessage: String?

    private let stepTitles = ["选择目录", "账号密码", "访问端口"]

    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                header
                stepIndicator

                Group {
                    switch step {
                    case 0: directoryStep
                    case 1: accountStep
                    default: portStep
                    }
                }
                .frame(maxWidth: 660)

                if let errorMessage {
                    Text(errorMessage)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(Palette.danger)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Palette.danger.opacity(0.10)))
                }

                footer
            }
            .padding(.horizontal, 40)
            .padding(.vertical, 34)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: - 头部

    private var header: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "externaldrive.badge.icloud")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Palette.accent)
                Text("MacNas")
                    .font(.system(size: 26, weight: .bold))
            }
            Text("把你的 Mac 变成一台私有 NAS：文件按内容去重存储，通过网页随时上传下载。")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.bottom, 4)
    }

    private var stepIndicator: some View {
        HStack(spacing: 12) {
            ForEach(Array(stepTitles.enumerated()), id: \.offset) { index, title in
                HStack(spacing: 8) {
                    ZStack {
                        Circle()
                            .fill(index <= step ? Palette.accent : Color.primary.opacity(0.12))
                            .frame(width: 22, height: 22)
                        if index < step {
                            Image(systemName: "checkmark")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                        } else {
                            Text("\(index + 1)")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(index <= step ? .white : Color.secondary)
                        }
                    }
                    Text(title)
                        .font(.system(size: 12, weight: index == step ? .semibold : .regular))
                        .foregroundStyle(index <= step ? .primary : .secondary)
                }
                if index < stepTitles.count - 1 {
                    Rectangle()
                        .fill(index < step ? Palette.accent : Color.primary.opacity(0.12))
                        .frame(width: 34, height: 2)
                }
            }
        }
        .padding(.bottom, 6)
    }

    // MARK: - 第一步：目录

    private var directoryStep: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 16) {
                SectionTitle(text: "选择第一个存放目录",
                             subtitle: "将会在该文件夹下自动创建 document 与 info 两个子文件夹")

                VStack(alignment: .leading, spacing: 10) {
                    Label("document", systemImage: "folder.fill")
                        .font(.system(size: 12, weight: .semibold))
                    Text("真正存放文件内容。相同内容的文件全局只保留一份，按 SHA-256 哈希命名保存。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Label("info", systemImage: "doc.text.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .padding(.top, 2)
                    Text("记录每个文件的哈希、实际存储位置与它在你界面上的存放目录。重启软件后自动读回。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))

                HStack(spacing: 10) {
                    Button {
                        chooseNewDirectory()
                    } label: {
                        Label("新建 MacNas 目录…", systemImage: "plus.circle.fill")
                    }
                    .buttonStyle(PrimaryButtonStyle())

                    Button {
                        openExistingDirectory()
                    } label: {
                        Label("打开已有目录…", systemImage: "folder.badge.gearshape")
                    }
                    .buttonStyle(SecondaryButtonStyle())
                }

                if app.pendingVolumes.isEmpty {
                    Text("还没有选择目录")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                } else {
                    VStack(spacing: 8) {
                        ForEach(app.pendingVolumes) { volume in
                            HStack(spacing: 10) {
                                Image(systemName: "externaldrive.fill")
                                    .foregroundStyle(Palette.accent)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(volume.name)
                                        .font(.system(size: 12, weight: .semibold))
                                    Text(volume.path)
                                        .font(.system(size: 11, design: .monospaced))
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .truncationMode(.middle)
                                }
                                Spacer()
                                Button {
                                    app.removeVolume(id: volume.id)
                                } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.plain)
                                .foregroundStyle(.secondary)
                            }
                            .padding(10)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Palette.accent.opacity(0.06)))
                        }
                    }
                }
            }
        }
    }

    // MARK: - 第二步：账号密码

    private var accountStep: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 16) {
                SectionTitle(text: "设置网页登录账号",
                             subtitle: "网页端只能登录，账号密码只能在软件里修改")

                MaterialField(title: "账号", systemImage: "person.fill", text: $username, prompt: "例如 admin")
                MaterialField(title: "密码", systemImage: "lock.fill", text: $password, isSecure: true, prompt: "至少 4 位")
                MaterialField(title: "确认密码", systemImage: "lock.rotation", text: $confirmPassword, isSecure: true, prompt: "再输入一次")

                Text("请把账号密码记牢：忘记后可在软件里直接重设（重置后所有网页登录状态会失效）。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 第三步：端口

    private var portStep: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 16) {
                SectionTitle(text: "选择网站访问端口",
                             subtitle: "同一局域网内的设备用 http://本机IP:端口 访问")

                HStack(alignment: .bottom, spacing: 12) {
                    MaterialField(title: "端口", systemImage: "network", text: $portText, prompt: "8080")
                        .frame(width: 200)
                    portStatusView
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("访问地址（初始化完成后生效）")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    ForEach(previewAddresses, id: \.self) { address in
                        HStack(spacing: 8) {
                            Image(systemName: "link")
                                .font(.system(size: 11))
                                .foregroundStyle(Palette.accent)
                            Text(address)
                                .font(.system(size: 12, design: .monospaced))
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))

                Text("如果这个端口被别的软件占用，换一个 1024–65535 之间的端口即可。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var portStatusView: some View {
        if let port = UInt16(portText), port >= 1024 {
            if NetworkInfo.isPortAvailable(port) {
                StatusPill(text: "端口可用", color: Palette.success)
            } else {
                StatusPill(text: "端口被占用", color: Palette.danger)
            }
        } else {
            StatusPill(text: "请输入 1024 以上端口", color: Palette.warning)
        }
    }

    private var previewAddresses: [String] {
        let port = UInt16(portText) ?? AppConfig.defaultPort
        var addresses = NetworkInfo.localIPv4Addresses().map { "http://\($0):\(port)" }
        addresses.append("http://127.0.0.1:\(port)")
        return addresses
    }

    // MARK: - 底部按钮

    private var footer: some View {
        HStack(spacing: 12) {
            if step > 0 {
                Button("上一步") {
                    errorMessage = nil
                    step -= 1
                }
                .buttonStyle(SecondaryButtonStyle())
            }
            Spacer()
            if step < 2 {
                Button("下一步") { advance() }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(!canAdvance)
                    .opacity(canAdvance ? 1 : 0.5)
            } else {
                Button("完成并开启网站") { finish() }
                    .buttonStyle(PrimaryButtonStyle(fullWidth: false))
            }
        }
        .frame(maxWidth: 660)
    }

    private var canAdvance: Bool {
        switch step {
        case 0: return !app.pendingVolumes.isEmpty
        case 1: return !username.trimmingCharacters(in: .whitespaces).isEmpty && password.count >= 4 && password == confirmPassword
        default: return true
        }
    }

    private func advance() {
        errorMessage = nil
        switch step {
        case 0:
            guard !app.pendingVolumes.isEmpty else {
                errorMessage = "请先选择至少一个目录"
                return
            }
        case 1:
            guard !username.trimmingCharacters(in: .whitespaces).isEmpty else {
                errorMessage = "请填写账号"
                return
            }
            guard password.count >= 4 else {
                errorMessage = "密码至少 4 位"
                return
            }
            guard password == confirmPassword else {
                errorMessage = "两次输入的密码不一致"
                return
            }
        default:
            break
        }
        step += 1
    }

    private func finish() {
        errorMessage = nil
        guard let port = UInt16(portText) else {
            errorMessage = "端口必须是数字"
            return
        }
        if let message = app.finishOnboarding(username: username, password: password, port: port) {
            errorMessage = message
        }
    }

    private func chooseNewDirectory() {
        guard let url = app.chooseDirectory(prompt: "创建 NAS 目录",
                                           message: "选择用于存放 document 与 info 的位置") else { return }
        let name = url.lastPathComponent
        if let message = app.addVolume(root: url, name: name, mode: .createNew) {
            errorMessage = message
        } else {
            errorMessage = nil
        }
    }

    private func openExistingDirectory() {
        guard let url = app.chooseDirectory(prompt: "打开已有目录",
                                           message: "请选择之前创建过 document 与 info 的文件夹") else { return }
        if let message = app.addVolume(root: url, name: url.lastPathComponent, mode: .openExisting) {
            errorMessage = message
        } else {
            errorMessage = nil
            app.toast = "已打开该目录，记录已自动读取"
        }
    }
}
