//
//  RootView.swift
//  MacNas
//

import SwiftUI

struct RootView: View {
    @Environment(AppState.self) private var app

    var body: some View {
        ZStack {
            BackgroundDecor()
            switch app.phase {
            case .loading:
                VStack(spacing: 14) {
                    ProgressView()
                    Text("正在启动 MacNas…")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
            case .onboarding:
                OnboardingView()
            case .ready:
                MainView()
            }
        }
        .overlay(alignment: .bottom) {
            if let toast = app.toast {
                ToastView(text: toast)
                    .padding(.bottom, 24)
                    .transition(.opacity)
                    .task(id: toast) {
                        try? await Task.sleep(nanoseconds: 2_600_000_000)
                        app.toast = nil
                    }
            }
        }
        .alert("提示", isPresented: errorBinding) {
            Button("知道了", role: .cancel) { app.lastError = nil }
        } message: {
            Text(app.lastError ?? "")
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { app.lastError != nil },
                set: { if !$0 { app.lastError = nil } })
    }
}
