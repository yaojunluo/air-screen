//
//  ContentView.swift
//  AirScreen
//
//  主视图：Metal 渲染区 + 状态覆盖层 + 状态栏
//

import SwiftUI
import MetalKit

struct ContentView: View {

    @StateObject private var viewModel = AirPlayViewModel()

    var body: some View {
        ZStack {
            // ── Metal 渲染层（始终存在，接收视频帧）──────────────────────────
            AirPlayMetalView(viewModel: viewModel)

            // ── 空状态覆盖层（未连接时显示）─────────────────────────────────
            if viewModel.connectionState == .idle {
                WaitingOverlay()
                    .transition(.opacity.animation(.easeInOut(duration: 0.3)))
            }

            // ── 错误提示 ────────────────────────────────────────────────────
            if case .error(let msg) = viewModel.connectionState {
                ErrorOverlay(message: msg)
                    .transition(.opacity)
            }

            // ── PIN 验证码覆盖层（配对时显示）────────────────────────────────
            if let pin = viewModel.pinCode {
                PinOverlay(pin: pin)
                    .transition(.opacity.animation(.easeInOut(duration: 0.3)))
            }

            // ── 连接状态条（底部，悬浮显示）─────────────────────────────────
            if viewModel.connectionState == .connected {
                VStack {
                    Spacer()
                    StatusBar(viewModel: viewModel)
                        .padding(.bottom, 12)
                }
            }
        }
        .alert(
            "标准 AirPlay 端口已被占用",
            isPresented: Binding(
                get: { viewModel.portConflict != nil },
                set: { isPresented in
                    if !isPresented {
                        viewModel.dismissPortConflict()
                    }
                }
            ),
            presenting: viewModel.portConflict
        ) { _ in
            Button("尝试动态端口") {
                viewModel.retryWithDynamicPorts()
            }
            Button("取消", role: .cancel) {
                viewModel.dismissPortConflict()
            }
        } message: { conflict in
            Text("7000/7001 端口可能已被系统 AirPlay Receiver 或其他程序占用。是否改用动态端口并重新广播？\n当前标准端口：AirPlay \(conflict.ports.airPlay)，RAOP \(conflict.ports.raop)")
        }
        .background(Color.black)
        .frame(minWidth: 280, minHeight: 280)
        .onAppear {
            // 强制初始尺寸（覆盖 SwiftUI 窗口状态恢复）
            DispatchQueue.main.async {
                if let window = NSApplication.shared.windows.first(where: { $0.isVisible }) {
                    window.backgroundColor = .black

                    // 强制 360x360 正方形，居中屏幕
                    let size = NSSize(width: 360, height: 360)
                    if let screen = window.screen ?? NSScreen.main {
                        let origin = NSPoint(
                            x: screen.visibleFrame.midX - size.width / 2,
                            y: screen.visibleFrame.midY - size.height / 2
                        )
                        window.setFrame(NSRect(origin: origin, size: size), display: true)
                    } else {
                        window.setContentSize(size)
                    }
                }
            }
            viewModel.startServices()
        }
        .onDisappear {
            viewModel.stopServices()
        }
    }
}

// MARK: - 底部状态条

private struct StatusBar: View {
    @ObservedObject var viewModel: AirPlayViewModel

    var body: some View {
        HStack(spacing: 16) {
            // 连接指示灯
            Circle()
                .fill(Color.green)
                .frame(width: 8, height: 8)
                .shadow(color: .green, radius: 4)

            Text(viewModel.deviceName)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(.white)

            if !viewModel.resolution.isEmpty {
                Divider()
                    .frame(height: 14)
                    .background(Color.white.opacity(0.3))

                Text(viewModel.resolution)
                    .font(.system(size: 12))
                    .foregroundColor(.white.opacity(0.8))
            }

            if viewModel.fps > 0 {
                Text("\(viewModel.fps) FPS")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundColor(.white.opacity(0.7))
            }

            Divider()
                .frame(height: 14)
                .background(Color.white.opacity(0.3))

            // 置顶按钮
            Button(action: { viewModel.toggleAlwaysOnTop() }) {
                Image(systemName: viewModel.isAlwaysOnTop ? "pin.fill" : "pin")
                    .font(.system(size: 12))
                    .foregroundColor(viewModel.isAlwaysOnTop ? .yellow : .white.opacity(0.7))
                    .rotationEffect(.degrees(viewModel.isAlwaysOnTop ? 0 : 45))
            }
            .buttonStyle(.plain)
            .help(viewModel.isAlwaysOnTop ? "取消置顶" : "窗口置顶")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial.opacity(0.8))
        .clipShape(Capsule())
        .shadow(radius: 8)
    }
}

// MARK: - 错误覆盖层

private struct ErrorOverlay: View {
    let message: String

    var body: some View {
        ZStack {
            Color.black.opacity(0.85)

            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 48))
                    .foregroundColor(.orange)

                Text("AirPlay 服务启动失败")
                    .font(.title3)
                    .foregroundColor(.white)

                Text(message)
                    .font(.body)
                    .foregroundColor(.white.opacity(0.6))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }
        }
    }
}

// MARK: - PIN 验证码覆盖层

private struct PinOverlay: View {
    let pin: String

    var body: some View {
        ZStack {
            Color.black.opacity(0.85)

            VStack(spacing: 24) {
                Image(systemName: "airplayvideo")
                    .font(.system(size: 48))
                    .foregroundColor(.white)

                Text("隔空播放验证码")
                    .font(.title2.weight(.semibold))
                    .foregroundColor(.white)

                HStack(spacing: 16) {
                    ForEach(Array(pin), id: \.self) { char in
                        Text(String(char))
                            .font(.system(size: 48, weight: .bold, design: .monospaced))
                            .foregroundColor(.white)
                            .frame(width: 64, height: 80)
                            .background(Color.white.opacity(0.15))
                            .cornerRadius(12)
                    }
                }

                Text("在 iOS 设备上输入此验证码")
                    .font(.callout)
                    .foregroundColor(.white.opacity(0.6))
            }
        }
    }
}

#Preview {
    ContentView()
        .frame(width: 1280, height: 720)
}
