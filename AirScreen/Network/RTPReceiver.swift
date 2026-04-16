//
//  RTPReceiver.swift
//  AirScreen
//
//  UDP 套接字接收 RTP 视频/音频数据包
//  解析 RTP 头部，按序号排序，交给解封装器处理
//
//  RTP 头部格式（RFC 3550）：
//   0               1               2               3
//   0 1 2 3 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 4 5 6 7 0 1 2 3 4 5 6 7
//  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
//  |V=2|P|X| CC  |M|     PT      |       sequence number         |
//  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
//  |                           timestamp                           |
//  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
//  |                              SSRC                             |
//  +-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+-+
//

import Foundation
import Network

// MARK: - RTP 包结构

struct RTPPacket {
    let version:        UInt8
    let padding:        Bool
    let hasExtension:   Bool
    let csrcCount:      UInt8
    let marker:         Bool      // 帧结束标记（对视频很重要）
    let payloadType:    UInt8
    let sequenceNumber: UInt16
    let timestamp:      UInt32
    let ssrc:           UInt32
    let payload:        Data      // 去掉 RTP 头后的负载

    /// 从原始 UDP 数据解析 RTP 包
    static func parse(from data: Data) -> RTPPacket? {
        guard data.count >= 12 else { return nil }

        let version    = (data[0] >> 6) & 0x03
        guard version == 2 else { return nil }  // RTP version 必须是 2

        let padding     = (data[0] & 0x20) != 0
        let hasExt      = (data[0] & 0x10) != 0
        let csrcCount   = data[0] & 0x0F
        let marker      = (data[1] & 0x80) != 0
        let payloadType = data[1] & 0x7F

        let seqNum    = UInt16(data[2]) << 8 | UInt16(data[3])
        let timestamp = UInt32(data[4]) << 24 | UInt32(data[5]) << 16
                      | UInt32(data[6]) << 8  | UInt32(data[7])
        let ssrc      = UInt32(data[8]) << 24 | UInt32(data[9]) << 16
                      | UInt32(data[10]) << 8 | UInt32(data[11])

        // 计算负载起始偏移（12字节固定头 + 4*CSRC + 扩展头）
        var offset = 12 + Int(csrcCount) * 4

        if hasExt && data.count >= offset + 4 {
            // 跳过 RTP 扩展头
            let extLength = Int(UInt16(data[offset + 2]) << 8 | UInt16(data[offset + 3]))
            offset += 4 + extLength * 4
        }

        guard offset <= data.count else { return nil }

        var payloadEnd = data.count
        if padding && data.count > 0 {
            payloadEnd -= Int(data[data.count - 1])
        }

        guard payloadEnd >= offset else { return nil }
        let payload = data[offset ..< payloadEnd]

        return RTPPacket(
            version:        version,
            padding:        padding,
            hasExtension:   hasExt,
            csrcCount:      csrcCount,
            marker:         marker,
            payloadType:    payloadType,
            sequenceNumber: seqNum,
            timestamp:      timestamp,
            ssrc:           ssrc,
            payload:        payload
        )
    }
}

// MARK: - RTP 接收器

final class RTPReceiver {

    // MARK: 回调

    /// 每收到一个有效的 RTP 包时触发
    var onPacketReceived: ((RTPPacket) -> Void)?

    // MARK: 私有

    private var listener:   NWListener?
    private let queue:      DispatchQueue
    private let listenPort: UInt16

    // 简单抖动缓冲区（按序号排序，防止少量乱序包）
    private var jitterBuffer  = [UInt16: RTPPacket]()
    private var expectedSeq:    UInt16 = 0
    private var initialized     = false
    private let jitterMaxSize   = 8   // 最多缓存 8 个包

    init(port: UInt16, label: String = "rtp") {
        self.listenPort = port
        self.queue = DispatchQueue(label: "com.airscreen.\(label)", qos: .userInteractive)
    }

    // MARK: - 启动/停止

    func start() throws {
        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true

        listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: listenPort)!)
        listener?.stateUpdateHandler = { state in
            switch state {
            case .ready:   print("[RTP:\(self.listenPort)] 开始接收")
            case .failed(let e): print("[RTP:\(self.listenPort)] 失败: \(e)")
            default: break
            }
        }

        listener?.newConnectionHandler = { [weak self] connection in
            self?.accept(connection: connection)
        }

        listener?.start(queue: queue)
    }

    func stop() {
        listener?.cancel()
        listener = nil
        jitterBuffer.removeAll()
        initialized = false
        print("[RTP:\(listenPort)] 已停止")
    }

    // MARK: - 接受连接并持续读取

    private func accept(connection: NWConnection) {
        connection.start(queue: queue)
        readDatagram(from: connection)
    }

    private func readDatagram(from connection: NWConnection) {
        // UDP 每次 receive 得到一个完整数据报
        connection.receiveMessage { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let data, !data.isEmpty {
                self.handleDatagram(data)
            }

            if let error {
                print("[RTP:\(self.listenPort)] 接收错误: \(error)")
                return
            }

            // 继续读取下一个包
            self.readDatagram(from: connection)
        }
    }

    // MARK: - 包处理

    private func handleDatagram(_ data: Data) {
        guard let packet = RTPPacket.parse(from: data) else {
            print("[RTP:\(listenPort)] 解析 RTP 包失败，长度: \(data.count)")
            return
        }

        deliverOrBuffer(packet)
    }

    // MARK: - 抖动缓冲

    private func deliverOrBuffer(_ packet: RTPPacket) {
        if !initialized {
            // 以第一个包的序号为基准
            expectedSeq = packet.sequenceNumber
            initialized = true
        }

        // 将包放入缓冲
        jitterBuffer[packet.sequenceNumber] = packet

        // 按序输出
        while let p = jitterBuffer[expectedSeq] {
            jitterBuffer.removeValue(forKey: expectedSeq)
            deliver(p)
            expectedSeq &+= 1   // 溢出安全递增（UInt16 自动回绕）
        }

        // 缓冲区过满，强制清空（防止丢包导致永久阻塞）
        if jitterBuffer.count > jitterMaxSize {
            let sorted = jitterBuffer.keys.sorted()
            for seq in sorted {
                if let p = jitterBuffer.removeValue(forKey: seq) {
                    deliver(p)
                }
            }
            if let next = jitterBuffer.keys.min() {
                expectedSeq = next
            }
        }
    }

    private func deliver(_ packet: RTPPacket) {
        onPacketReceived?(packet)
    }
}
