//
//  MainView.swift
//  MacNas
//
//  主界面：左侧目录 + 服务，右侧概览 / 目录详情。
//

import SwiftUI

enum SidebarItem: Hashable {
    case overview
    case logs
    case settings
    case volume(String)
}

struct MainView: View {
    @Environment(AppState.self) private var app
    @State private var selection: SidebarItem? = .overview

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("MacNas")
    }

    // MARK: - 侧栏

    private var sidebar: some View {
        List(selection: $selection) {
            Section("存储目录") {
                ForEach(app.config.volumes) { volume in
                    HStack(spacing: 9) {
                        Image(systemName: sidebarIcon(for: volume))
                            .foregroundStyle(volume.isPrepared ? Palette.accent : Palette.warning)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(volume.name)
                                .font(.system(size: 12, weight: .medium))
                            Text(volume.path)
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                        }
                    }
                    .tag(SidebarItem.volume(volume.id))
                }

                Menu {
                    Button("新建 MacNas 目录…") { addDirectory(mode: .createNew) }
                    Button("打开已有 MacNas 目录…") { addDirectory(mode: .openExisting) }
                } label: {
                    Label("添加目录", systemImage: "plus.circle")
                        .font(.system(size: 12))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
            }

            Section("服务") {
                Label("概览", systemImage: "rectangle.grid.1x2").tag(SidebarItem.overview)
                Label("日志", systemImage: "text.alignleft").tag(SidebarItem.logs)
                Label("设置", systemImage: "gearshape").tag(SidebarItem.settings)
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 240)
    }

    @ViewBuilder
    private var detail: some View {
        switch selection ?? .overview {
        case .overview:
            OverviewView()
        case .logs:
            LogsView()
        case .settings:
            SettingsView()
        case .volume(let id):
            VolumeDetailView(volumeId: id)
        }
    }

    private func sidebarIcon(for volume: Volume) -> String {
        if !volume.isPrepared { return "externaldrive.badge.xmark" }
        if app.isReadOnly(volumeId: volume.id) { return "lock.circle" }
        return "externaldrive.fill"
    }

    private func addDirectory(mode: AppState.VolumeAddMode) {
        let prompt = mode == .createNew ? "创建 NAS 目录" : "打开已有目录"
        let message = mode == .createNew
            ? "选择位置，将自动创建 document 与 info 两个子文件夹"
            : "请选择之前创建过 document 与 info 的文件夹"
        guard let url = app.chooseDirectory(prompt: prompt, message: message) else { return }
        if let error = app.addVolume(root: url, name: url.lastPathComponent, mode: mode) {
            app.lastError = error
        } else {
            app.toast = mode == .createNew ? "已创建新目录并等待就绪" : "已打开已有目录"
        }
    }
}

// MARK: - 概览

struct OverviewView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                statusCard
                statsGrid
                volumesCard
                recentLogsCard
            }
            .padding(22)
        }
    }

    private var statusCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("网站服务")
                            .font(.system(size: 15, weight: .semibold))
                        statusPill
                    }
                    Spacer()
                    HStack(spacing: 10) {
                        Button(app.serverState.isRunning ? "停止" : "启动") {
                            app.toggleServer()
                        }
                        .buttonStyle(SecondaryButtonStyle())

                        Button("在浏览器中打开") { app.openInBrowser() }
                            .buttonStyle(PrimaryButtonStyle())
                            .disabled(!app.serverState.isRunning)
                            .opacity(app.serverState.isRunning ? 1 : 0.5)
                    }
                }

                VStack(alignment: .leading, spacing: 8) {
                    Text("局域网访问地址")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                    ForEach(app.accessAddresses, id: \.self) { address in
                        HStack(spacing: 10) {
                            Image(systemName: "link")
                                .font(.system(size: 11))
                                .foregroundStyle(Palette.accent)
                            Text(address)
                                .font(.system(size: 12, weight: .medium, design: .monospaced))
                                .textSelection(.enabled)
                            Spacer()
                            Button {
                                app.copyToPasteboard(address)
                            } label: {
                                Image(systemName: "doc.on.doc")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 7)
                        .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.04)))
                    }
                }

                if app.config.webdavEnabled {
                    HStack(spacing: 10) {
                        Image(systemName: "externaldrive.connected.to.line.below")
                            .font(.system(size: 11))
                            .foregroundStyle(Palette.accent)
                        Text("WebDAV：\(app.webdavAddressText)")
                            .font(.system(size: 12, weight: .medium, design: .monospaced))
                            .textSelection(.enabled)
                        Spacer()
                        Button {
                            app.copyToPasteboard(app.webdavAddressText)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.04)))
                }

                if case .failed(let message) = app.serverState {
                    Text(message)
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.danger)
                }
            }
        }
    }

    private var statusPill: some View {
        Group {
            switch app.serverState {
            case .running:
                StatusPill(text: app.serverState.displayText, color: Palette.success)
            case .starting:
                StatusPill(text: app.serverState.displayText, color: Palette.warning)
            case .failed:
                StatusPill(text: "启动失败", color: Palette.danger)
            case .stopped:
                StatusPill(text: "已停止", color: Palette.neutral)
            }
        }
    }

    private var statsGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 5), spacing: 12) {
            StatTile(title: "文件记录", value: "\(app.stats.fileCount)", caption: "\(app.stats.volumeCount) 个目录",
                     systemImage: "doc.on.doc")
            StatTile(title: "独立文件", value: "\(app.stats.uniqueBlobCount)", caption: "按哈希只存一份",
                     systemImage: "shippingbox", tint: Palette.success)
            StatTile(title: "已节省", value: ByteFormatter.string(app.stats.savedBytes),
                     caption: String(format: "去重率 %.0f%%", app.stats.savedRatio * 100),
                     systemImage: "arrow.down.circle", tint: Palette.success)
            StatTile(title: "实际占用", value: ByteFormatter.string(app.stats.physicalBytes),
                     caption: "逻辑大小 \(ByteFormatter.string(app.stats.logicalBytes))",
                     systemImage: "internaldrive", tint: Palette.accent)
            StatTile(title: "分享链接", value: "\(app.shareCount)", caption: "在网页「分享管理」里查看",
                     systemImage: "link", tint: Palette.accent)
        }
    }

    private var volumesCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    SectionTitle(text: "存储目录", subtitle: "每个目录都包含 document 与 info 两个子文件夹")
                    Spacer()
                    Button("刷新统计") { app.refreshStats() }
                        .buttonStyle(SecondaryButtonStyle())
                }

                if app.config.volumes.isEmpty {
                    Text("还没有目录")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(app.config.volumes) { volume in
                        HStack(alignment: .top, spacing: 12) {
                            Image(systemName: volume.isPrepared ? "externaldrive.fill" : "externaldrive.badge.xmark")
                                .foregroundStyle(volume.isPrepared ? Palette.accent : Palette.warning)
                            VStack(alignment: .leading, spacing: 4) {
                                HStack(spacing: 6) {
                                    Text(volume.name)
                                        .font(.system(size: 12, weight: .semibold))
                                    if app.isReadOnly(volumeId: volume.id) {
                                        StatusPill(text: "只读", color: Palette.danger)
                                    }
                                    if app.isRebuilt(volumeId: volume.id) {
                                        StatusPill(text: "已重建", color: Palette.warning)
                                    }
                                }
                                Text(volume.path)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                HStack(spacing: 10) {
                                    Text("document/")
                                    Text("info/")
                                }
                                .font(.system(size: 10, design: .monospaced))
                                .foregroundStyle(Palette.accent)
                            }
                            Spacer()
                            Button("在 Finder 中显示") {
                                app.revealInFinder(volume.path)
                            }
                            .buttonStyle(SecondaryButtonStyle())
                        }
                        .padding(12)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.035)))
                    }
                }
            }
        }
    }

    private var recentLogsCard: some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 10) {
                SectionTitle(text: "最近日志", subtitle: "完整日志见左侧「日志」")
                let recent = Array(app.logs.suffix(6))
                if recent.isEmpty {
                    Text("暂无日志")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(recent) { entry in
                        LogRow(entry: entry)
                    }
                }
            }
        }
    }
}

// MARK: - 单个目录详情

struct VolumeDetailView: View {
    @Environment(AppState.self) private var app
    let volumeId: String

    @State private var renameText = ""
    @State private var showRemoveConfirm = false

    private var volume: Volume? { app.config.volumes.first(where: { $0.id == volumeId }) }
    private var stats: VolumeStats? { app.stats.volumeStats.first(where: { $0.volumeId == volumeId }) }

    var body: some View {
        ScrollView {
            if let volume {
                VStack(spacing: 16) {
                    header(volume)
                    pathsCard(volume)
                    statsCard(volume)
                    maintenanceCard(volume)
                }
                .padding(22)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "externaldrive.badge.xmark")
                        .font(.system(size: 30))
                        .foregroundStyle(.secondary)
                    Text("这个目录已从软件中移除")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(60)
            }
        }
        .onAppear { renameText = volume?.name ?? "" }
    }

    private func header(_ volume: Volume) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(volume.name)
                            .font(.system(size: 18, weight: .semibold))
                        Text(volume.path)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Spacer()
                    HStack(spacing: 8) {
                        if app.isReadOnly(volumeId: volume.id) {
                            StatusPill(text: "只读 · 需要更新版本", color: Palette.danger)
                        }
                        if app.isRebuilt(volumeId: volume.id) {
                            StatusPill(text: "索引已按哈希重建", color: Palette.warning)
                        }
                        StatusPill(text: volume.isPrepared ? "已就绪" : "不可用",
                                   color: volume.isPrepared ? Palette.success : Palette.warning)
                    }
                }

                if app.isReadOnly(volumeId: volume.id) {
                    Text("这个目录的格式版本比当前软件新，因此只以只读方式打开：可以浏览和下载，但不会改写任何内容。升级 MacNas 之后即可正常读写。")
                        .font(.system(size: 11))
                        .foregroundStyle(Palette.danger)
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Palette.danger.opacity(0.10)))
                }

                HStack(spacing: 10) {
                    Button("在 Finder 中显示") { app.revealInFinder(volume.path) }
                        .buttonStyle(SecondaryButtonStyle())
                    Button("重新读取记录") { app.reloadVolumes() }
                        .buttonStyle(SecondaryButtonStyle())
                }
            }
        }
    }

    private func pathsCard(_ volume: Volume) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(text: "目录位置", subtitle: "document 放内容，info 放记录")
                KeyValueRow(label: "document", value: volume.documentURL.path, monospaced: true,
                            trailing: AnyView(Button("打开") { app.revealInFinder(volume.documentURL.path) }
                                .buttonStyle(SecondaryButtonStyle())))
                KeyValueRow(label: "info", value: volume.infoURL.path, monospaced: true,
                            trailing: AnyView(Button("打开") { app.revealInFinder(volume.infoURL.path) }
                                .buttonStyle(SecondaryButtonStyle())))
                KeyValueRow(label: "索引文件", value: volume.indexURL.path, monospaced: true,
                            trailing: AnyView(Button("打开") { app.revealInFinder(volume.indexURL.path) }
                                .buttonStyle(SecondaryButtonStyle())))
                KeyValueRow(label: "索引备份", value: volume.indexBackupURL.path, monospaced: true,
                            trailing: AnyView(Button("打开") { app.revealInFinder(volume.indexBackupURL.path) }
                                .buttonStyle(SecondaryButtonStyle())))
                KeyValueRow(label: "磁盘格式", value: "v\(DiskSchema.currentVersion)（结构已冻结，升级不改动）")
            }
        }
    }

    private func statsCard(_ volume: Volume) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 12) {
                SectionTitle(text: "使用情况")
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
                    StatTile(title: "文件记录", value: "\(stats?.fileCount ?? 0)", systemImage: "doc.on.doc")
                    StatTile(title: "实际占用", value: ByteFormatter.string(stats?.physicalBytes ?? 0),
                             caption: "本目录 physical", systemImage: "internaldrive", tint: Palette.success)
                    StatTile(title: "逻辑大小", value: ByteFormatter.string(stats?.logicalBytes ?? 0),
                             caption: "含去重引用", systemImage: "doc.text", tint: Palette.neutral)
                }
                if let missing = stats?.missingBlobs, missing > 0 {
                    Text("有 \(missing) 条记录的内容找不到（可能是外部磁盘未挂载）")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Palette.warning)
                }
            }
        }
    }

    private func maintenanceCard(_ volume: Volume) -> some View {
        GlassCard {
            VStack(alignment: .leading, spacing: 14) {
                SectionTitle(text: "维护")

                HStack(spacing: 10) {
                    MaterialField(title: "目录名称", systemImage: "pencil", text: $renameText)
                    Button("保存名称") {
                        app.renameVolume(id: volume.id, name: renameText)
                        app.toast = "目录名称已更新"
                    }
                    .buttonStyle(SecondaryButtonStyle())
                    .disabled(app.isReadOnly(volumeId: volume.id))
                }

                Divider().opacity(0.4)

                HStack(spacing: 10) {
                    Button("清理孤立文件") { app.pruneOrphans(volumeId: volume.id) }
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(app.isReadOnly(volumeId: volume.id))
                    Text("删除 document/blobs 里没有任何记录引用的文件")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                HStack(spacing: 10) {
                    Button("按哈希重建索引") { app.rebuildIndex(volumeId: volume.id) }
                        .buttonStyle(SecondaryButtonStyle())
                        .disabled(app.isReadOnly(volumeId: volume.id))
                    Text("info 丢失或损坏时的救援手段：文件名就是内容哈希，可据此把记录重建出来")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }

                Divider().opacity(0.4)

                HStack(spacing: 10) {
                    Button("从软件中移除该目录") { showRemoveConfirm = true }
                        .buttonStyle(SecondaryButtonStyle())
                    Text("只移除记录，磁盘上的 document 与 info 不会被删除")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .alert("移除目录？", isPresented: $showRemoveConfirm) {
            Button("取消", role: .cancel) { }
            Button("移除", role: .destructive) {
                app.removeVolume(id: volume.id)
            }
        } message: {
            Text("将把「\(volume.name)」从软件中移除。document 与 info 文件夹以及里面的文件都会保留在磁盘上。")
        }
    }
}
