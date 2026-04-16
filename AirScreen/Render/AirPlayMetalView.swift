//
//  AirPlayMetalView.swift
//  AirScreen
//
//  SwiftUI 包装层：将 MTKView 嵌入 SwiftUI 视图树
//  并作为 MetalRenderer 和 VideoToolboxDecoder 的协调点
//

import SwiftUI
import MetalKit
import CoreVideo
import CoreMedia

// MARK: - NSViewRepresentable 包装

struct AirPlayMetalView: NSViewRepresentable {

    @ObservedObject var viewModel: AirPlayViewModel

    func makeNSView(context: Context) -> MTKView {
        let mtkView = MTKView()
        mtkView.wantsLayer = true
        mtkView.layer?.backgroundColor = .black

        // 创建渲染器并绑定到 ViewModel
        if let renderer = MetalRenderer(metalView: mtkView) {
            context.coordinator.renderer = renderer
            viewModel.setRenderer(renderer, metalView: mtkView)
        }

        return mtkView
    }

    func updateNSView(_ nsView: MTKView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    // Coordinator 持有 renderer 避免提前释放
    final class Coordinator {
        var renderer: MetalRenderer?
    }
}

// MARK: - 空状态覆盖层（等待连接时显示）

struct WaitingOverlay: View {
    var body: some View {
        ZStack {
            Color.black

            VStack(spacing: 20) {
                Image(systemName: "airplayvideo")
                    .font(.system(size: 64))
                    .foregroundColor(.white.opacity(0.6))

                Text("等待 AirPlay 连接")
                    .font(.title2)
                    .foregroundColor(.white.opacity(0.8))

                Text("在 iPhone 或 iPad 上打开\n控制中心 → 屏幕镜像 → AirScreen")
                    .font(.body)
                    .foregroundColor(.white.opacity(0.5))
                    .multilineTextAlignment(.center)
            }
        }
    }
}
