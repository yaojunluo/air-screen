//
//  MetalRenderer.swift
//  AirScreen
//
//  MTKViewDelegate 实现：
//    将 VideoToolbox 解码输出的 CVPixelBuffer（NV12格式）
//    通过 CVMetalTextureCache 零拷贝转换为 MTLTexture，
//    再用 Metal 管线渲染到屏幕
//

import Metal
import MetalKit
import CoreVideo
import CoreMedia

final class MetalRenderer: NSObject, MTKViewDelegate {

    // MARK: - Metal 核心对象

    private let device:        MTLDevice
    private let commandQueue:  MTLCommandQueue
    private var pipelineState: MTLRenderPipelineState?

    // MARK: - 纹理缓存（CVPixelBuffer → MTLTexture 零拷贝）

    private var textureCache: CVMetalTextureCache?

    // MARK: - 当前帧数据（线程安全写入）

    private var currentPixelBuffer: CVPixelBuffer?
    private let bufferLock = NSLock()

    // MARK: - 初始化

    init?(metalView: MTKView) {
        guard let dev = MTLCreateSystemDefaultDevice() else {
            print("[Metal] 当前设备不支持 Metal")
            return nil
        }
        guard let queue = dev.makeCommandQueue() else { return nil }

        device       = dev
        commandQueue = queue
        super.init()

        // 配置 MTKView
        metalView.device             = device
        metalView.delegate           = self
        metalView.framebufferOnly    = true
        metalView.colorPixelFormat   = .bgra8Unorm
        metalView.clearColor         = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        metalView.isPaused           = true   // 由我们主动触发重绘（有新帧时）
        metalView.enableSetNeedsDisplay = false

        // 创建纹理缓存
        let cacheResult = CVMetalTextureCacheCreate(
            kCFAllocatorDefault, nil, device, nil, &textureCache
        )
        guard cacheResult == kCVReturnSuccess else {
            print("[Metal] 创建纹理缓存失败: \(cacheResult)")
            return nil
        }

        // 创建渲染管线
        buildPipeline(metalView: metalView)

        print("[Metal] 初始化成功，设备: \(device.name)")
    }

    // MARK: - 接收新帧

    /// 由 VideoToolboxDecoder 解码回调调用
    /// 线程安全：可从任意线程调用
    func enqueue(pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        bufferLock.lock()
        currentPixelBuffer = pixelBuffer
        bufferLock.unlock()
    }

    /// 触发 MTKView 渲染（必须在 enqueue 后调用，且在主线程）
    func requestRender(in view: MTKView) {
        view.draw()
    }

    // MARK: - MTKViewDelegate

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        print("[Metal] 视图尺寸变更: \(size)")
    }

    func draw(in view: MTKView) {
        // 取出当前帧
        bufferLock.lock()
        let pixelBuffer = currentPixelBuffer
        bufferLock.unlock()

        guard let pixelBuffer,
              let cache = textureCache,
              let pipeline = pipelineState,
              let drawable = view.currentDrawable,
              let renderPassDesc = view.currentRenderPassDescriptor,
              let cmdBuffer = commandQueue.makeCommandBuffer(),
              let encoder = cmdBuffer.makeRenderCommandEncoder(descriptor: renderPassDesc)
        else { return }

        // ── CVPixelBuffer → MTLTexture（Y 平面）────────────────────────────
        let width  = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        var lumaRef:   CVMetalTexture?
        var chromaRef: CVMetalTexture?

        // 平面 0：Y（亮度），格式 R8Unorm
        CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, pixelBuffer, nil,
            .r8Unorm, width, height, 0, &lumaRef
        )
        // 平面 1：UV（色度），格式 RG8Unorm
        CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, pixelBuffer, nil,
            .rg8Unorm, width / 2, height / 2, 1, &chromaRef
        )

        guard let lumaRef, let chromaRef,
              let lumaTexture   = CVMetalTextureGetTexture(lumaRef),
              let chromaTexture = CVMetalTextureGetTexture(chromaRef)
        else {
            encoder.endEncoding()
            cmdBuffer.commit()
            return
        }

        // ── 渲染指令 ────────────────────────────────────────────────────────
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(lumaTexture,   index: 0)
        encoder.setFragmentTexture(chromaTexture, index: 1)

        // 绘制 2 个三角形（triangle strip，4 个顶点覆盖全屏）
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()

        cmdBuffer.present(drawable)
        cmdBuffer.commit()

        // 清空纹理缓存（防止纹理引用积压）
        CVMetalTextureCacheFlush(cache, 0)
    }

    // MARK: - 渲染管线构建

    private func buildPipeline(metalView: MTKView) {
        // 从 default.metallib 加载着色器（Xcode 自动编译 .metal 文件）
        guard let library = device.makeDefaultLibrary() else {
            print("[Metal] 无法加载 Metal shader 库")
            return
        }

        guard let vertexFn   = library.makeFunction(name: "vertexShader"),
              let fragmentFn = library.makeFunction(name: "fragmentShaderNV12") else {
            print("[Metal] 找不到 shader 函数")
            return
        }

        let desc = MTLRenderPipelineDescriptor()
        desc.vertexFunction                     = vertexFn
        desc.fragmentFunction                   = fragmentFn
        desc.colorAttachments[0].pixelFormat    = metalView.colorPixelFormat

        do {
            pipelineState = try device.makeRenderPipelineState(descriptor: desc)
            print("[Metal] 渲染管线创建成功")
        } catch {
            print("[Metal] 渲染管线创建失败: \(error)")
        }
    }
}
