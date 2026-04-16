//
//  AirPlayViewModel.swift
//  AirScreen
//
//  核心协调器：将所有模块（Bonjour、RTSP、RTP、解码、渲染）串联起来
//  遵循 ObservableObject 以便 SwiftUI 视图响应状态变化
//

import Foundation
import SwiftUI
import MetalKit
import CoreMedia
import AppKit

@MainActor
final class AirPlayViewModel: ObservableObject {

    // MARK: - 状态（驱动 UI）

    @Published var connectionState: ConnectionState = .idle
    @Published var deviceName:      String = "等待连接..."
    @Published var resolution:      String = ""
    @Published var fps:             Int    = 0
    @Published var isAudioEnabled:  Bool   = true
    @Published var portConflict: PortConflict?
    @Published var pinCode: String?
    @Published var isAlwaysOnTop: Bool = false

    enum ConnectionState: Equatable {
        case idle          // 等待连接
        case connected     // 已连接，正在接收
        case error(String) // 错误
    }

    struct PortConflict: Identifiable, Equatable {
        let id = UUID()
        let ports: AirPlayServicePorts
    }

    // MARK: - 子模块

    private let rtspServer     = RTSPServer()
    private let raopServer     = RAOPServer()
    private var videoRTPReceiver: RTPReceiver?
    private var audioRTPReceiver: RTPReceiver?
    private var videoDecoder   = VideoToolboxDecoder()
    private var h264Depacketizer = H264Depacketizer()
    private var hevcDepacketizer = HEVCDepacketizer()
    private var audioPlayer    = AudioPlayer()
    private var isHEVC         = false

    // Metal 渲染（通过 AirPlayMetalView 注入）
    private weak var renderer:  MetalRenderer?
    private weak var metalView: MTKView?

    // MARK: - 统计

    private var frameCount      = 0
    private var lastFPSUpdate   = Date()
    private var servicePorts    = AirPlayServicePorts.standard
    private var isStartingServices = false

    // MARK: - 视频尺寸跟踪
    private var currentVideoWidth  = 0
    private var currentVideoHeight = 0
    private var audioConfigured    = false

    // MARK: - 初始化与启动

    init() {
        // 设置设备名称（取自 Mac 名）
        let hostName = Host.current().localizedName ?? "AirScreen"
        _ = hostName  // 广播时使用
    }

    /// 启动所有服务（应用启动后调用）
    func startServices() {
        startServices(using: .standard, triggeredByUserRetry: false)
    }

    func retryWithDynamicPorts() {
        let ports = AirPlayServicePorts(
            airPlay: nextDynamicPort(excluding: []),
            raop: nextDynamicPort(excluding: [servicePorts.airPlay])
        )
        startServices(using: ports, triggeredByUserRetry: true)
    }

    func dismissPortConflict() {
        portConflict = nil
        if case .error = connectionState {
            return
        }
        connectionState = .idle
    }

    func toggleAlwaysOnTop() {
        isAlwaysOnTop.toggle()
        guard let window = NSApplication.shared.windows.first(where: { $0.isVisible }) else { return }
        window.level = isAlwaysOnTop ? .floating : .normal
        print("[ViewModel] 窗口置顶: \(isAlwaysOnTop)")
    }

    private func startServices(using ports: AirPlayServicePorts, triggeredByUserRetry: Bool) {
        guard !isStartingServices else { return }
        isStartingServices = true
        portConflict = nil
        connectionState = .idle
        deviceName = "等待连接..."

        stopServicesForRestart()

        rtspServer.delegate = self
        servicePorts = ports

        // AirPlay 2 (RAOP) 回调
        raopServer.onMirrorStreamReady = { [weak self] dataPort in
            DispatchQueue.main.async {
                guard let self else { return }
                print("[ViewModel] AirPlay 2 镜像流就绪，dataPort=\(dataPort)")
                self.connectionState = .connected
                self.deviceName = "已连接 (AirPlay 2)"
            }
        }
        raopServer.onStreamTeardown = { [weak self] in
            DispatchQueue.main.async {
                guard let self else { return }
                self.connectionState = .idle
                self.deviceName = "等待连接..."
                self.resolution = ""
                self.fps = 0
                self.currentVideoWidth = 0
                self.currentVideoHeight = 0
                self.mirrorDecoderReady = false
                self.audioConfigured = false
                self.audioPlayer.stop()
                print("[ViewModel] AirPlay 2 镜像断开")
            }
        }

        raopServer.onMirrorData = { [weak self] header, payload in
            guard let self else { return }
            self.handleMirrorFrame(header: header, payload: payload)
        }

        // TODO: 暂时屏蔽音频解码，提高视频帧率
        raopServer.onAudioData = { _, _ in }

        do {
            try rtspServer.start(on: ports.airPlay, allowRestartOnFailure: false)
        } catch {
            handleStartupError(error, requestedPorts: ports, triggeredByUserRetry: triggeredByUserRetry)
        }

        isStartingServices = false
    }

    /// 停止所有服务（应用退出前调用）
    func stopServices() {
        stopServicesForRestart()
    }

    // MARK: - MetalView 注入

    private func stopServicesForRestart() {
        BonjourAdvertiser.shared.stopAdvertising()
        rtspServer.stop()
        raopServer.stop()
        videoRTPReceiver?.stop()
        audioRTPReceiver?.stop()
        videoRTPReceiver = nil
        audioRTPReceiver = nil
        audioPlayer.stop()
        videoDecoder.invalidate()
    }

    private func handleStartupError(_ error: Error, requestedPorts: AirPlayServicePorts, triggeredByUserRetry: Bool) {
        if isAddressInUse(error), requestedPorts == .standard {
            portConflict = PortConflict(ports: requestedPorts)
            connectionState = .idle
            print("[ViewModel] 标准端口被占用，等待用户确认切换动态端口")
            return
        }

        let prefix = triggeredByUserRetry ? "动态端口启动失败" : "RTSP 服务器启动失败"
        connectionState = .error("\(prefix): \(error.localizedDescription)")
    }

    private func isAddressInUse(_ error: Error) -> Bool {
        if let posix = error as? POSIXError, posix.code == .EADDRINUSE {
            return true
        }
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain, nsError.code == POSIXErrorCode.EADDRINUSE.rawValue {
            return true
        }
        return error.localizedDescription.localizedCaseInsensitiveContains("Address already in use")
    }

    private func nextDynamicPort(excluding: [UInt16]) -> UInt16 {
        var candidate = UInt16.random(in: 12000 ... 24000)
        while excluding.contains(candidate) {
            candidate = candidate == 24000 ? 12000 : candidate + 1
        }
        return candidate
    }

    func setRenderer(_ renderer: MetalRenderer, metalView: MTKView) {
        self.renderer  = renderer
        self.metalView = metalView

        // 解码完成 → 渲染
        videoDecoder.onFrameDecoded = { [weak self] pixelBuffer, pts in
            guard let self, let renderer = self.renderer, let view = self.metalView else { return }
            renderer.enqueue(pixelBuffer: pixelBuffer, presentationTime: pts)

            let w = CVPixelBufferGetWidth(pixelBuffer)
            let h = CVPixelBufferGetHeight(pixelBuffer)

            DispatchQueue.main.async {
                renderer.requestRender(in: view)
                self.updateFPS()

                // 检测到新分辨率时调整窗口
                if w > 0, h > 0, (w != self.currentVideoWidth || h != self.currentVideoHeight) {
                    self.currentVideoWidth  = w
                    self.currentVideoHeight = h
                    self.resolution = "\(w)×\(h)"
                    self.resizeWindowToFitVideo(videoWidth: CGFloat(w), videoHeight: CGFloat(h))
                }
            }
        }
    }

    // MARK: - AirPlay 2 Mirror 帧处理

    private var mirrorDecoderReady = false

    /// 处理 AirPlay 2 镜像帧（从 RAOPServer.onMirrorData 回调）
    /// 帧头 128 字节，payload 为视频数据
    private nonisolated func handleMirrorFrame(header: Data, payload: Data) {
        guard header.count >= 128, !payload.isEmpty else { return }

        let payloadType = header[4]  // UInt8: 0=video(P), 1=codec config, 5=keyframe(IDR)

        switch payloadType {
        case 1:
            handleMirrorCodecConfig(payload: payload)
        case 0:
            handleMirrorVideoFrame(payload: payload, header: header)
        case 5:
            // type=5 是统计/心跳帧（binary plist），不是视频数据
            handleMirrorStatistics(payload: payload)
        default:
            print("[ViewModel] Mirror 未知帧类型: \(payloadType)")
        }
    }

    /// 解析编解码器配置，初始化解码器
    private nonisolated func handleMirrorCodecConfig(payload: Data) {
        print("[ViewModel] Mirror 编解码器配置: \(payload.count) bytes")
        let hex = payload.prefix(64).map { String(format: "%02x", $0) }.joined(separator: " ")
        print("[ViewModel]   hex: \(hex)")

        var sps: Data?
        var pps: Data?
        var vps: Data?

        // 尝试 AVCC DecoderConfigurationRecord 格式
        // 格式: [version=1][profile][compat][level][0xFF][0xE0|numSPS][spsLen(2B BE)][sps]...[numPPS][ppsLen(2B BE)][pps]...
        if payload.count >= 7, payload[0] == 0x01 {
            print("[ViewModel]   检测到 AVCC DecoderConfigurationRecord 格式")
            var offset = 5
            let numSPS = Int(payload[offset]) & 0x1F
            offset += 1
            for i in 0..<numSPS {
                guard offset + 2 <= payload.count else { break }
                let spsLen = Int(payload[offset]) << 8 | Int(payload[offset + 1])
                offset += 2
                guard spsLen > 0, offset + spsLen <= payload.count else { break }
                let spsData = Data(payload[offset..<(offset + spsLen)])
                print("[ViewModel]   SPS[\(i)]: \(spsLen) bytes, naluType=\(spsData[0] & 0x1F)")
                sps = spsData
                offset += spsLen
            }
            if offset < payload.count {
                let numPPS = Int(payload[offset])
                offset += 1
                for i in 0..<numPPS {
                    guard offset + 2 <= payload.count else { break }
                    let ppsLen = Int(payload[offset]) << 8 | Int(payload[offset + 1])
                    offset += 2
                    guard ppsLen > 0, offset + ppsLen <= payload.count else { break }
                    let ppsData = Data(payload[offset..<(offset + ppsLen)])
                    print("[ViewModel]   PPS[\(i)]: \(ppsLen) bytes, naluType=\(ppsData[0] & 0x1F)")
                    pps = ppsData
                    offset += ppsLen
                }
            }
        } else {
            // 回退: 尝试 Annex B 或 AVCC NALU 格式
            let nalus = extractNALUs(from: payload)
            print("[ViewModel]   提取到 \(nalus.count) 个 NALU")
            for nalu in nalus {
                guard !nalu.isEmpty else { continue }
                let naluType = nalu[0] & 0x1F
                let hevcType = (nalu[0] >> 1) & 0x3F
                if naluType == 7 { sps = nalu }
                else if naluType == 8 { pps = nalu }
                else if hevcType == 32 { vps = nalu }
                else if hevcType == 33 { sps = nalu }
                else if hevcType == 34 { pps = nalu }
            }
        }

        Task { @MainActor in
            if let vps, let sps, let pps {
                print("[ViewModel] Mirror HEVC 解码器初始化: VPS=\(vps.count)B SPS=\(sps.count)B PPS=\(pps.count)B")
                isHEVC = true
                videoDecoder.setupHEVC(vps: vps, sps: sps, pps: pps)
                mirrorDecoderReady = true
            } else if let sps, let pps {
                print("[ViewModel] Mirror H264 解码器初始化: SPS=\(sps.count)B PPS=\(pps.count)B")
                isHEVC = false
                videoDecoder.setupH264(sps: sps, pps: pps)
                mirrorDecoderReady = true
            } else {
                print("[ViewModel] Mirror 编解码器配置: 未找到完整的 SPS/PPS")
            }
        }
    }

    /// 解析视频帧，提取 NALU 并送解码器
    private nonisolated func handleMirrorVideoFrame(payload: Data, header: Data) {
        // 从 header 提取 NTP timestamp 用于 PTS
        let timestamp: UInt64 = {
            var ts: UInt64 = 0
            for i in 8..<16 {
                ts = ts << 8 | UInt64(header[i])
            }
            return ts
        }()
        let pts = CMTime(value: CMTimeValue(timestamp >> 16), timescale: 1_000_000)

        let nalus = extractVideoNALUs(from: payload)

        if nalus.isEmpty {
            let prefixHex = payload.prefix(32).map { String(format: "%02x", $0) }.joined(separator: " ")
            print("[ViewModel] Mirror 视频帧未提取到 NALU: payload=\(payload.count)B prefix=\(prefixHex)")
        }

        Task { @MainActor in
            videoDecoder.decodeAccessUnit(nalus: nalus, pts: pts)
        }
    }

    /// 解析 type=5 统计/心跳帧（binary plist）
    private nonisolated func handleMirrorStatistics(payload: Data) {
        guard payload.starts(with: Data("bplist00".utf8)),
              let plist = try? PropertyListSerialization.propertyList(from: payload, format: nil) else {
            return
        }
        if let dict = plist as? [String: Any] {
            print("[ViewModel] Mirror 统计帧: \(dict.keys.sorted().joined(separator: ", "))")
        }
    }

    private nonisolated func extractVideoNALUs(from payload: Data) -> [Data] {
        if payload.starts(with: Data("bplist00".utf8)) {
            if let plist = try? PropertyListSerialization.propertyList(from: payload, format: nil) {
                let embeddedData = collectBinaryData(from: plist)
                print("[ViewModel] Mirror 视频帧检测到 binary plist，提取到 \(embeddedData.count) 个 Data 字段")
                return embeddedData.flatMap { extractNALUs(from: $0) }
            }

            print("[ViewModel] Mirror 视频帧 binary plist 解析失败")
            return []
        }

        return extractNALUs(from: payload)
    }

    private nonisolated func collectBinaryData(from value: Any) -> [Data] {
        if let data = value as? Data {
            return [data]
        }

        if let array = value as? [Any] {
            return array.flatMap { collectBinaryData(from: $0) }
        }

        if let dict = value as? [String: Any] {
            return dict.values.flatMap { collectBinaryData(from: $0) }
        }

        return []
    }

    /// 从 payload 中提取 NALU（支持 AVCC 4字节长度前缀 和 Annex B 起始码两种格式）
    private nonisolated func extractNALUs(from data: Data) -> [Data] {
        guard data.count >= 4 else { return [] }

        // Annex B: 仅检测 4 字节起始码 00 00 00 01
        // 注意：3 字节 00 00 01 与 AVCC 长度 256-511 (0x000001XX) 冲突，
        // AirPlay mirror 流使用 AVCC 格式，不能用 3 字节起始码来判断
        if data[0] == 0x00, data[1] == 0x00, data[2] == 0x00, data[3] == 0x01 {
            return extractAnnexBNALUs(from: data)
        }

        // AVCC 格式: [4 byte BE length][NALU data]...
        return extractAVCCNALUs(from: data)
    }

    /// AVCC 格式 NALU 提取 (4字节大端长度前缀)
    private nonisolated func extractAVCCNALUs(from data: Data) -> [Data] {
        var nalus: [Data] = []
        var offset = 0

        while offset + 4 <= data.count {
            let length = Int(data[offset]) << 24 | Int(data[offset + 1]) << 16 |
                         Int(data[offset + 2]) << 8  | Int(data[offset + 3])
            offset += 4

            guard length > 0, offset + length <= data.count else {
                let prefixHex = data.prefix(32).map { String(format: "%02x", $0) }.joined(separator: " ")
                print("[ViewModel] Mirror AVCC NALU 长度异常: length=\(length) offset=\(offset) data=\(data.count)B prefix=\(prefixHex)")
                break
            }
            nalus.append(Data(data[offset..<(offset + length)]))
            offset += length
        }

        return nalus
    }

    /// Annex B 格式 NALU 提取 (00 00 00 01 或 00 00 01 分隔)
    private nonisolated func extractAnnexBNALUs(from data: Data) -> [Data] {
        var nalus: [Data] = []
        var i = 0
        var naluStart = -1

        while i < data.count - 3 {
            // 查找 00 00 00 01 或 00 00 01
            let is4ByteStart = data[i] == 0x00 && data[i + 1] == 0x00 && data[i + 2] == 0x00 && i + 3 < data.count && data[i + 3] == 0x01
            let is3ByteStart = data[i] == 0x00 && data[i + 1] == 0x00 && data[i + 2] == 0x01

            if is4ByteStart || is3ByteStart {
                if naluStart >= 0 {
                    nalus.append(Data(data[naluStart..<i]))
                }
                let startCodeLen = is4ByteStart ? 4 : 3
                naluStart = i + startCodeLen
                i += startCodeLen
            } else {
                i += 1
            }
        }

        // 最后一个 NALU
        if naluStart >= 0, naluStart < data.count {
            nalus.append(Data(data[naluStart...]))
        }

        return nalus
    }

    // MARK: - NALU → Decoder 管线配置

    private func setupVideoDecoderPipeline() {
        let decoder = videoDecoder  // capture

        if isHEVC {
            hevcDepacketizer.onNALU = { naluData, timestamp in
                let pts = CMTime(value: CMTimeValue(timestamp), timescale: 90000)
                decoder.decode(nalu: naluData, pts: pts)
            }
        } else {
            h264Depacketizer.onNALU = { naluData, timestamp in
                let pts = CMTime(value: CMTimeValue(timestamp), timescale: 90000)
                decoder.decode(nalu: naluData, pts: pts)
            }
        }
    }

    // MARK: - 窗口自适应

    private func resizeWindowToFitVideo(videoWidth: CGFloat, videoHeight: CGFloat) {
        guard let window = NSApplication.shared.windows.first(where: { $0.isVisible }),
              let screen = window.screen ?? NSScreen.main else { return }

        let aspectRatio = videoWidth / videoHeight
        let screenFrame = screen.visibleFrame

        // 标题栏高度 = 窗口总高度 - 内容区高度
        let titleBarHeight = window.frame.height - window.contentLayoutRect.height

        // 在屏幕可见区域 90% 范围内，尽量填满，保持宽高比
        let maxWidth = screenFrame.width * 0.9
        let maxContentHeight = screenFrame.height * 0.9 - titleBarHeight

        // 计算内容区尺寸（视频区域，不含标题栏）
        var contentWidth = maxWidth
        var contentHeight = contentWidth / aspectRatio

        if contentHeight > maxContentHeight {
            contentHeight = maxContentHeight
            contentWidth = contentHeight * aspectRatio
        }

        // 窗口总高度 = 内容区 + 标题栏
        let windowWidth = contentWidth
        let windowHeight = contentHeight + titleBarHeight

        let newFrame = NSRect(
            x: screenFrame.midX - windowWidth / 2,
            y: screenFrame.midY - windowHeight / 2,
            width: windowWidth,
            height: windowHeight
        )

        window.setFrame(newFrame, display: true, animate: true)
        window.contentAspectRatio = NSSize(width: videoWidth, height: videoHeight)

        print("[ViewModel] 窗口已调整: \(Int(windowWidth))x\(Int(windowHeight)) 内容区: \(Int(contentWidth))x\(Int(contentHeight)) (视频 \(Int(videoWidth))x\(Int(videoHeight)))")
    }

    // MARK: - FPS 统计

    private func updateFPS() {
        frameCount += 1
        let now = Date()
        let elapsed = now.timeIntervalSince(lastFPSUpdate)
        if elapsed >= 1.0 {
            fps = Int(Double(frameCount) / elapsed)
            frameCount   = 0
            lastFPSUpdate = now
        }
    }
}

// MARK: - RTSPServerDelegate

extension AirPlayViewModel: RTSPServerDelegate {

    nonisolated func rtspServer(_ server: RTSPServer, didReceiveSDP sdp: SDPSession) {
        Task { @MainActor in
            // 解析视频参数
            if let video = sdp.videoTrack {
                let codec = video.codec.uppercased()
                isHEVC    = codec.contains("265") || codec.contains("HEVC")
                resolution = "\(video.width)×\(video.height)"

                if isHEVC {
                    // HEVC：VPS/SPS/PPS 通常内联在 fmtp 中或通过 NALU 下发
                    // 此处留给实际流的第一帧 NALU 初始化解码器
                    print("[ViewModel] 视频编码: HEVC \(resolution)")
                } else {
                    // H.264：从 SDP sprop-parameter-sets 获取 SPS/PPS
                    if let sps = video.sps, let pps = video.pps {
                        videoDecoder.setupH264(sps: sps, pps: pps)
                        print("[ViewModel] H264 解码器已初始化（SPS:\(sps.count)B PPS:\(pps.count)B）")
                    }
                }

                setupVideoDecoderPipeline()
            }

            // 解析音频参数
            if let audio = sdp.audioTrack {
                audioPlayer.configure(track: audio)
            }

            connectionState = .connected
            portConflict = nil
            deviceName      = "已连接"
        }
    }

    nonisolated func rtspServer(_ server: RTSPServer, videoRTPPort port: UInt16) {
        Task { @MainActor in
            print("[ViewModel] 视频 RTP 端口: \(port)")
            startVideoRTPReceiver(port: port)
        }
    }

    nonisolated func rtspServer(_ server: RTSPServer, audioRTPPort port: UInt16) {
        Task { @MainActor in
            print("[ViewModel] 音频 RTP 端口: \(port)")
            startAudioRTPReceiver(port: port)
        }
    }

    nonisolated func rtspServerDidTeardown(_ server: RTSPServer) {
        Task { @MainActor in
            connectionState = .idle
            portConflict = nil
            deviceName      = "等待连接..."
            resolution      = ""
            fps             = 0
            videoRTPReceiver?.stop()
            audioRTPReceiver?.stop()
            videoRTPReceiver = nil
            audioRTPReceiver = nil
            print("[ViewModel] 连接已断开")
        }
    }

    nonisolated func rtspServerDidStartListening(_ server: RTSPServer, port: UInt16) {
        Task { @MainActor in
            let name = Host.current().localizedName ?? "AirScreen"
            try? self.raopServer.start(on: self.servicePorts.raop)
            BonjourAdvertiser.shared.startAdvertising(deviceName: name, ports: self.servicePorts)
            print("[ViewModel] 服务已启动，设备名: \(name) airplay=\(self.servicePorts.airPlay) raop=\(self.servicePorts.raop)")
        }
    }

    nonisolated func rtspServer(_ server: RTSPServer, didFailToStart error: Error, requestedPort: UInt16) {
        Task { @MainActor in
            let requestedPorts = AirPlayServicePorts(airPlay: requestedPort, raop: servicePorts.raop)
            handleStartupError(error, requestedPorts: requestedPorts, triggeredByUserRetry: requestedPorts != .standard)
        }
    }

    // MARK: - RTP 接收器启动

    private func startVideoRTPReceiver(port: UInt16) {
        videoRTPReceiver?.stop()
        let receiver = RTPReceiver(port: port, label: "video")

        // RTP包 → 解封装器
        if isHEVC {
            let depack = hevcDepacketizer
            receiver.onPacketReceived = { packet in
                depack.process(packet: packet)
            }
        } else {
            let depack = h264Depacketizer
            receiver.onPacketReceived = { packet in
                depack.process(packet: packet)
            }
        }

        do {
            try receiver.start()
            videoRTPReceiver = receiver
        } catch {
            print("[ViewModel] 视频 RTP 接收器启动失败: \(error)")
        }
    }

    private func startAudioRTPReceiver(port: UInt16) {
        audioRTPReceiver?.stop()
        let receiver = RTPReceiver(port: port, label: "audio")
        let player   = audioPlayer

        receiver.onPacketReceived = { packet in
            guard !packet.payload.isEmpty else { return }
            player.enqueue(rtpPayload: packet.payload, timestamp: packet.timestamp)
        }

        do {
            try receiver.start()
            audioRTPReceiver = receiver
        } catch {
            print("[ViewModel] 音频 RTP 接收器启动失败: \(error)")
        }
    }
}
