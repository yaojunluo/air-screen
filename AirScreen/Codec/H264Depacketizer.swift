//
//  H264Depacketizer.swift
//  AirScreen
//
//  将 RTP 包的 H.264 负载重组为完整的 NAL Unit（NALU）
//
//  支持 RFC 6184 定义的三种打包模式：
//    - 单 NAL Unit（类型 1-23）：直接作为一个 NALU
//    - STAP-A（类型 24）：    单时间戳聚合，多个小 NALU 合并在一个 RTP 包
//    - FU-A（类型 28）：      分片单元，一个大 NALU 分散在多个 RTP 包
//

import Foundation

// MARK: - NALU 回调

/// 每当重组出完整的 NALU 时触发
typealias NALUHandler = (_ naluData: Data, _ timestamp: UInt32) -> Void

// MARK: -

final class H264Depacketizer {

    var onNALU: NALUHandler?

    // FU-A 分片重组缓冲区
    private var fuBuffer       = Data()
    private var fuTimestamp:     UInt32 = 0
    private var fuExpectedSeq:   UInt16 = 0
    private var fuInProgress     = false

    // MARK: - 公开接口

    /// 输入一个 RTP 包，内部解析并在需要时触发 onNALU
    func process(packet: RTPPacket) {
        guard !packet.payload.isEmpty else { return }

        let firstByte = packet.payload[0]
        let nalType   = firstByte & 0x1F   // 低 5 位为 NAL Unit type

        switch nalType {

        case 1...23:
            // ── 单 NAL Unit ────────────────────────────────────────────────
            emit(nalu: packet.payload, timestamp: packet.timestamp)

        case 24:
            // ── STAP-A：同一个 RTP 包携带多个 NAL Unit ─────────────────────
            depackSTAPA(payload: packet.payload, timestamp: packet.timestamp)

        case 28:
            // ── FU-A：大 NAL Unit 被分散到多个 RTP 包 ──────────────────────
            depackFUA(payload: packet.payload, packet: packet)

        default:
            print("[H264] 未知 NAL 类型: \(nalType)，已跳过")
        }
    }

    // MARK: - STAP-A 解封装

    private func depackSTAPA(payload: Data, timestamp: UInt32) {
        // 格式：[STAP-A header(1B)] [size(2B)] [NALU] [size(2B)] [NALU] ...
        var offset = 1  // 跳过 STAP-A header byte

        while offset + 2 <= payload.count {
            let naluSize = Int(payload[offset]) << 8 | Int(payload[offset + 1])
            offset += 2

            guard offset + naluSize <= payload.count else {
                print("[H264] STAP-A 数据不完整")
                break
            }

            let nalu = payload[offset ..< (offset + naluSize)]
            emit(nalu: nalu, timestamp: timestamp)
            offset += naluSize
        }
    }

    // MARK: - FU-A 解封装

    private func depackFUA(payload: Data, packet: RTPPacket) {
        // FU-A 格式：[FU indicator(1B)] [FU header(1B)] [payload...]
        //   FU indicator: F | NRI | 28 (type)
        //   FU header:    S(start) | E(end) | R | NAL type
        guard payload.count >= 2 else { return }

        let fuIndicator = payload[0]
        let fuHeader    = payload[1]

        let isStart  = (fuHeader & 0x80) != 0
        let isEnd    = (fuHeader & 0x40) != 0
        let nalType  = fuHeader & 0x1F

        if isStart {
            // 新分片序列开始，重置缓冲区
            fuBuffer    = Data()
            fuTimestamp = packet.timestamp
            fuInProgress = true

            // 重建 NALU ��字节：用 FU indicator 的 F+NRI 位 + 实际 NAL type
            let naluHeader = (fuIndicator & 0xE0) | nalType
            fuBuffer.append(naluHeader)
        }

        guard fuInProgress else {
            // 收到非 start 分片但没有开头（包丢失），丢弃
            return
        }

        // 追加 FU payload（跳过前两个 header 字节）
        if payload.count > 2 {
            fuBuffer.append(contentsOf: payload[2...])
        }

        if isEnd {
            // 分片完成，输出完整 NALU
            emit(nalu: fuBuffer, timestamp: fuTimestamp)
            fuBuffer     = Data()
            fuInProgress = false
        }
    }

    // MARK: - 私有工具

    private func emit(nalu: Data, timestamp: UInt32) {
        // 过滤空 NALU
        guard !nalu.isEmpty else { return }
        onNALU?(nalu, timestamp)
    }
}

// MARK: - HEVC（H.265）解封装（AP 格式，RFC 7798）

final class HEVCDepacketizer {

    var onNALU: NALUHandler?

    private var fuBuffer    = Data()
    private var fuTimestamp: UInt32 = 0
    private var fuInProgress = false

    func process(packet: RTPPacket) {
        guard packet.payload.count >= 2 else { return }

        // HEVC RTP header：2 字节
        // [F | Type(6b) | LayerID_high(1b)] [LayerID_low(5b) | TID(3b)]
        let nalType = (packet.payload[0] >> 1) & 0x3F

        switch nalType {
        case 0...47:
            // 单 NAL Unit
            emit(nalu: packet.payload, timestamp: packet.timestamp)

        case 48:
            // AP（Aggregation Packet）
            depackAP(payload: packet.payload, timestamp: packet.timestamp)

        case 49:
            // FU（Fragmentation Unit）
            depackFU(payload: packet.payload, packet: packet)

        default:
            break
        }
    }

    private func depackAP(payload: Data, timestamp: UInt32) {
        var offset = 2  // 跳过 HEVC RTP 头
        while offset + 2 <= payload.count {
            let size = Int(payload[offset]) << 8 | Int(payload[offset + 1])
            offset += 2
            guard offset + size <= payload.count else { break }
            emit(nalu: payload[offset ..< offset + size], timestamp: timestamp)
            offset += size
        }
    }

    private func depackFU(payload: Data, packet: RTPPacket) {
        guard payload.count >= 3 else { return }
        // FU header（第3字节）: S | E | nalUnitType(6b)
        let fuHeader = payload[2]
        let isStart  = (fuHeader & 0x80) != 0
        let isEnd    = (fuHeader & 0x40) != 0
        let nalType  = fuHeader & 0x3F

        if isStart {
            fuBuffer = Data()
            fuTimestamp = packet.timestamp
            fuInProgress = true
            // 重建 HEVC NAL header
            let header0 = (payload[0] & 0x81) | (nalType << 1)
            let header1 = payload[1]
            fuBuffer.append(contentsOf: [header0, header1])
        }

        guard fuInProgress, payload.count > 3 else { return }
        fuBuffer.append(contentsOf: payload[3...])

        if isEnd {
            emit(nalu: fuBuffer, timestamp: fuTimestamp)
            fuBuffer = Data()
            fuInProgress = false
        }
    }

    private func emit(nalu: Data, timestamp: UInt32) {
        guard !nalu.isEmpty else { return }
        onNALU?(nalu, timestamp)
    }
}
