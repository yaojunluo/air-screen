//
//  AirScreenApp.swift
//  AirScreen
//
//  应用入口：配置窗口和生命周期
//

import SwiftUI

@main
struct AirScreenApp: App {

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .windowStyle(.titleBar)
        .windowToolbarStyle(.unified)
        .defaultSize(width: 360, height: 360)
        .commands {
            // 移除不相关的菜单项
            CommandGroup(replacing: .newItem) {}
        }
    }
}
