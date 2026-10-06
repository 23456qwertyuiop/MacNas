//
//  LogsView.swift
//  MacNas
//

import SwiftUI
import AppKit

struct LogRow: View {
    let entry: LogEntry

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text(DateFormatterCache.short.string(from: entry.date))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
            Text(entry.level.label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(color)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Capsule().fill(color.opacity(0.14)))
            Text(entry.message)
                .font(.system(size: 11))
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
    }

    private var color: Color {
        switch entry.level {
        case .debug: return Palette.neutral
        case .info: return Palette.accent
        case .warn: return Palette.warning
        case .error: return Palette.danger
        }
    }
}

struct LogsView: View {
    @Environment(AppState.self) private var app

    @State private var levelFilter: LogEntry.Level? = nil
    @State private var keyword = ""
    @State private var autoScroll = true

    private var filtered: [LogEntry] {
        app.logs.filter { entry in
            if let levelFilter, entry.level != levelFilter { return false }
            if keyword.isEmpty { return true }
            return entry.message.localizedCaseInsensitiveContains(keyword)
        }
    }

    var body: some View {
        VStack(spacing: 14) {
            toolbar
            logList
        }
        .padding(22)
    }

    private var toolbar: some View {
        GlassCard(padding: 14) {
            HStack(spacing: 12) {
                Picker("级别", selection: $levelFilter) {
                    Text("全部").tag(LogEntry.Level?.none)
                    ForEach(LogEntry.Level.allCases, id: \.self) { level in
                        Text(level.label).tag(LogEntry.Level?.some(level))
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 320)

                MaterialField(title: "", systemImage: "magnifyingglass", text: $keyword, prompt: "搜索日志")
                    .frame(width: 240)

                Spacer()

                Toggle("自动滚动", isOn: $autoScroll)
                    .toggleStyle(.switch)
                    .font(.system(size: 11))

                Button("清空") { LogCenter.shared.clear() }
                    .buttonStyle(SecondaryButtonStyle())
                Button("打开日志文件") {
                    NSWorkspace.shared.activateFileViewerSelecting([AppPaths.currentLogURL])
                }
                .buttonStyle(SecondaryButtonStyle())
            }
        }
    }

    private var logList: some View {
        GlassCard(padding: 14) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 3) {
                        ForEach(filtered) { entry in
                            LogRow(entry: entry)
                                .id(entry.id)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: filtered.count) {
                    guard autoScroll, let last = filtered.last else { return }
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .frame(minHeight: 320)
        }
    }
}
