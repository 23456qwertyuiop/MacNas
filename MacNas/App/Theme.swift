//
//  Theme.swift
//  MacNas
//
//  配色与视觉规范：蓝色为主、平面纯色（不使用渐变）、大圆角与毛玻璃。
//

import SwiftUI

enum Palette {
    /// Google Blue 700 —— 主色
    static let accent = Color(red: 0.043, green: 0.341, blue: 0.816)
    /// 浅蓝（深色模式下的主色）
    static let accentLight = Color(red: 0.659, green: 0.780, blue: 0.980)
    /// 蓝色容器色
    static let accentContainer = Color(red: 0.827, green: 0.890, blue: 0.992)
    static let canvas = Color(red: 0.949, green: 0.965, blue: 0.984)
    static let success = Color(red: 0.086, green: 0.612, blue: 0.361)
    static let warning = Color(red: 0.902, green: 0.596, blue: 0.043)
    static let danger = Color(red: 0.780, green: 0.157, blue: 0.157)
    static let neutral = Color(red: 0.451, green: 0.475, blue: 0.510)
}

struct BackgroundDecor: View {
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Palette.canvas.opacity(0.55)
                Circle()
                    .fill(Palette.accent.opacity(0.16))
                    .frame(width: proxy.size.width * 0.55)
                    .blur(radius: 130)
                    .offset(x: -proxy.size.width * 0.28, y: -proxy.size.height * 0.32)
                Circle()
                    .fill(Color(red: 0.36, green: 0.62, blue: 0.94).opacity(0.18))
                    .frame(width: proxy.size.width * 0.5)
                    .blur(radius: 140)
                    .offset(x: proxy.size.width * 0.34, y: proxy.size.height * 0.34)
                Circle()
                    .fill(Palette.accentContainer.opacity(0.30))
                    .frame(width: proxy.size.width * 0.42)
                    .blur(radius: 120)
                    .offset(x: proxy.size.width * 0.32, y: -proxy.size.height * 0.30)
            }
            .ignoresSafeArea()
        }
    }
}
