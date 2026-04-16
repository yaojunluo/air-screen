//
//  VideoToolboxDecoder.swift
//  AirScreen
//
//  使用 VideoToolbox 框架进行 H.264 / HEVC 硬件加速解码
//  输入：NAL Unit（不含起始码）
//  输出：CVPixelBuffer（NV12 格式，Metal 友好）
//

import VideoToolbox
import CoreMedia
import Foundation

// MARK: - 解码输出回调

typealias FrameOutputHandler = (_ pixelBuffer: CVPixelBuffer, _ presentationTime: CMTime) -> Void

// MARK: -

final class VideoToolboxDecoder {

    // MARK: 公开属性

    var onFrameDecoded: FrameOutputHandler?

    // MARK: 私有

    private var decompressionSession: VTDecompressionSession?
    private var formatDescription:    CMVideoFormatDescription?
    private var codec: VideoCodec     = .h264
    var decodedFrameCount: Int        = 0

    // SPS / PPS / VPS 缓存（建立解码器用）
    private var sps: Data?
    private var pps: Data?
    private var vps: Data?   // HEVC only

    enum VideoCodec { case h264, hevc }

    // MARK: - 公开接口

    /// 用 SPS/PPS 初始化 H.264 解码器（从 SDP 的 sprop-parameter-sets 提取）
    func setupH264(sps: Data, pps: Data) {
        codec = .h264
        _ = reconfigureH264IfPossible(sps: sps, pps: pps)
    }

    /// 用 VPS/SPS/PPS 初始化 HEVC 解码器
    func setupHEVC(vps: Data, sps: Data, pps: Data) {
        self.codec = .hevc
        self.vps   = vps
        self.sps   = sps
        self.pps   = pps
        createHEVCFormatDescription(vps: vps, sps: sps, pps: pps)
        createDecompressionSession()
    }

    /// 解码一个 NALU（不含 4 字节起始码）
    /// - Parameter nalu: 裸 NALU 数据
    /// - Parameter pts:  显示时间戳（从 RTP timestamp 转换而来）
    func decode(nalu: Data, pts: CMTime = .invalid) {
        if codec == .h264 {
            let naluType = nalu.first.map { $0 & 0x1F } ?? 0xFF
            if naluType == 7 {
                let newSPS = nalu
                if newSPS != sps {
                    if let pps {
                        _ = reconfigureH264IfPossible(sps: newSPS, pps: pps)
                    }
                }
                return
            } else if naluType == 8 {
                let newPPS = nalu
                if newPPS != pps {
                    if let sps {
                        _ = reconfigureH264IfPossible(sps: sps, pps: newPPS)
                    }
                }
                return
            }
        }

        guard let session = decompressionSession,
              let formatDesc = formatDescription else {
            print("[VTDecoder] 跳过解码：session/formatDescription 未就绪，naluSize=\(nalu.count)")
            return
        }

        // 将 NALU 包装为 AVCC 格式（4 字节大端长度前缀）
        guard let blockBuffer = makeBlockBuffer(from: nalu) else { return }

        // 创建 CMSampleBuffer
        var sampleBuffer: CMSampleBuffer?
        var naluSize  = nalu.count + 4
        var timingInfo = CMSampleTimingInfo(
            duration:               .invalid,
            presentationTimeStamp:  pts,
            decodeTimeStamp:        .invalid
        )

        let status = CMSampleBufferCreate(
            allocator:               kCFAllocatorDefault,
            dataBuffer:              blockBuffer,
            dataReady:               true,
            makeDataReadyCallback:   nil,
            refcon:                  nil,
            formatDescription:       formatDesc,
            sampleCount:             1,
            sampleTimingEntryCount:  1,
            sampleTimingArray:       &timingInfo,
            sampleSizeEntryCount:    1,
            sampleSizeArray:         &naluSize,
            sampleBufferOut:         &sampleBuffer
        )

        guard status == noErr, let sampleBuffer else {
            print("[VTDecoder] 创建 CMSampleBuffer 失败: \(status)")
            return
        }

        // 提交解码（异步，解码完成后在回调中输出）
        var flagsOut = VTDecodeInfoFlags()
        let decodeStatus = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer:   sampleBuffer,
            flags:          [._EnableAsynchronousDecompression],
            frameRefcon:    nil,
            infoFlagsOut:   &flagsOut
        )

        if decodeStatus != noErr {
            let naluType = nalu.first.map { $0 & 0x1F } ?? 0xFF
            print("[VTDecoder] 提交解码失败: status=\(decodeStatus) naluType=\(naluType) naluSize=\(nalu.count) flagsOut=\(flagsOut.rawValue)")
        }
    }

    func decodeAccessUnit(nalus: [Data], pts: CMTime = .invalid) {
        guard !nalus.isEmpty else { return }

        if codec == .h264 {
            var nextSPS = sps
            var nextPPS = pps
            var payloadNALUs: [Data] = []

            for nalu in nalus {
                guard let firstByte = nalu.first else { continue }
                let naluType = firstByte & 0x1F
                if naluType == 7 {
                    nextSPS = nalu
                } else if naluType == 8 {
                    nextPPS = nalu
                } else {
                    payloadNALUs.append(nalu)
                }
            }

            if let nextSPS, let nextPPS,
               (nextSPS != sps || nextPPS != pps) {
                _ = reconfigureH264IfPossible(sps: nextSPS, pps: nextPPS)
            }

            guard !payloadNALUs.isEmpty else { return }
            decodeAVCCSample(nalus: payloadNALUs, pts: pts)
            return
        }

        let payloadNALUs = nalus.filter { nalu in
            guard let firstByte = nalu.first else { return false }
            let hevcType = (firstByte >> 1) & 0x3F
            return hevcType != 32 && hevcType != 33 && hevcType != 34
        }

        guard !payloadNALUs.isEmpty else { return }
        decodeAVCCSample(nalus: payloadNALUs, pts: pts)
    }

    /// 销毁解码器
    func invalidate() {
        if let session = decompressionSession {
            VTDecompressionSessionWaitForAsynchronousFrames(session)
            VTDecompressionSessionInvalidate(session)
        }
        decompressionSession = nil
        formatDescription    = nil
    }

    private func reconfigureH264IfPossible(sps: Data, pps: Data) -> Bool {
        guard let newFormatDescription = makeH264FormatDescription(sps: sps, pps: pps) else {
            return false
        }

        guard let newSession = makeDecompressionSession(formatDescription: newFormatDescription) else {
            return false
        }

        if let oldSession = decompressionSession {
            VTDecompressionSessionWaitForAsynchronousFrames(oldSession)
            VTDecompressionSessionInvalidate(oldSession)
        }

        self.sps = sps
        self.pps = pps
        formatDescription = newFormatDescription
        decompressionSession = newSession
        return true
    }

    private var decodeFrameCount = 0

    private func decodeAVCCSample(nalus: [Data], pts: CMTime) {
        guard let session = decompressionSession,
              let formatDesc = formatDescription else {
            let totalSize = nalus.reduce(0) { $0 + $1.count }
            print("[VTDecoder] 跳过解码：session/formatDescription 未就绪，naluSize=\(totalSize)")
            return
        }

        decodeFrameCount += 1
        if decodeFrameCount <= 10 {
            for (i, nalu) in nalus.enumerated() {
                let naluType = (nalu.first ?? 0) & 0x1F
                let prefix = nalu.prefix(8).map { String(format: "%02x", $0) }.joined(separator: " ")
                print("[VTDecoder] 解码帧#\(decodeFrameCount) NALU[\(i)]: type=\(naluType) size=\(nalu.count) prefix=\(prefix)")
            }
        }

        guard let blockBuffer = makeBlockBuffer(from: nalus) else { return }

        var sampleBuffer: CMSampleBuffer?
        var sampleSize = nalus.reduce(0) { $0 + $1.count + 4 }
        var timingInfo = CMSampleTimingInfo(
            duration:               .invalid,
            presentationTimeStamp:  pts,
            decodeTimeStamp:        .invalid
        )

        let status = CMSampleBufferCreate(
            allocator:               kCFAllocatorDefault,
            dataBuffer:              blockBuffer,
            dataReady:               true,
            makeDataReadyCallback:   nil,
            refcon:                  nil,
            formatDescription:       formatDesc,
            sampleCount:             1,
            sampleTimingEntryCount:  1,
            sampleTimingArray:       &timingInfo,
            sampleSizeEntryCount:    1,
            sampleSizeArray:         &sampleSize,
            sampleBufferOut:         &sampleBuffer
        )

        guard status == noErr, let sampleBuffer else {
            print("[VTDecoder] 创建 CMSampleBuffer 失败: \(status)")
            return
        }

        var flagsOut = VTDecodeInfoFlags()
        let decodeStatus = VTDecompressionSessionDecodeFrame(
            session,
            sampleBuffer:   sampleBuffer,
            flags:          [._EnableAsynchronousDecompression],
            frameRefcon:    nil,
            infoFlagsOut:   &flagsOut
        )

        if decodeStatus != noErr {
            let firstType = nalus.first?.first.map { $0 & 0x1F } ?? 0xFF
            let totalSize = nalus.reduce(0) { $0 + $1.count }
            print("[VTDecoder] 提交解码失败: status=\(decodeStatus) naluType=\(firstType) naluSize=\(totalSize) flagsOut=\(flagsOut.rawValue)")
        }
    }

    // MARK: - 格式描述创建

    private func createH264FormatDescription(sps: Data, pps: Data) {
        formatDescription = makeH264FormatDescription(sps: sps, pps: pps)

        if formatDescription == nil {
            print("[VTDecoder] 创建 H264 FormatDescription 失败")
        } else {
            print("[VTDecoder] H264 FormatDescription 创建成功")
        }
    }

    private func makeH264FormatDescription(sps: Data, pps: Data) -> CMVideoFormatDescription? {
        var formatDescription: CMVideoFormatDescription?
        let result = sps.withUnsafeBytes { spsBuf in
            pps.withUnsafeBytes { ppsBuf in
                let paramSets: [UnsafePointer<UInt8>] = [
                    spsBuf.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    ppsBuf.baseAddress!.assumingMemoryBound(to: UInt8.self),
                ]
                let sizes: [Int] = [sps.count, pps.count]
                let err = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator:            kCFAllocatorDefault,
                    parameterSetCount:    2,
                    parameterSetPointers: paramSets,
                    parameterSetSizes:    sizes,
                    nalUnitHeaderLength:  4,
                    formatDescriptionOut: &formatDescription
                )
                return err
            }
        }

        if result != noErr {
            print("[VTDecoder] 创建 H264 FormatDescription 失败: \(result)")
        }

        return formatDescription
    }

    private func createHEVCFormatDescription(vps: Data, sps: Data, pps: Data) {
        formatDescription = nil

        let result = vps.withUnsafeBytes { vpsBuf in
            sps.withUnsafeBytes { spsBuf in
                pps.withUnsafeBytes { ppsBuf in
                    let paramSets: [UnsafePointer<UInt8>] = [
                        vpsBuf.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        spsBuf.baseAddress!.assumingMemoryBound(to: UInt8.self),
                        ppsBuf.baseAddress!.assumingMemoryBound(to: UInt8.self),
                    ]
                    let sizes = [vps.count, sps.count, pps.count]
                    var desc: CMVideoFormatDescription?
                    let err = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                        allocator:            kCFAllocatorDefault,
                        parameterSetCount:    3,
                        parameterSetPointers: paramSets,
                        parameterSetSizes:    sizes,
                        nalUnitHeaderLength:  4,
                        extensions:           nil,
                        formatDescriptionOut: &desc
                    )
                    if err == noErr { formatDescription = desc }
                    return err
                }
            }
        }

        if result != noErr {
            print("[VTDecoder] 创建 HEVC FormatDescription 失败: \(result)")
        }
    }

    // MARK: - 解码会话创建

    private func createDecompressionSession() {
        guard let formatDesc = formatDescription else { return }
        if let old = decompressionSession {
            VTDecompressionSessionInvalidate(old)
            decompressionSession = nil
        }
        decompressionSession = makeDecompressionSession(formatDescription: formatDesc)
    }

    private func makeDecompressionSession(formatDescription formatDesc: CMVideoFormatDescription) -> VTDecompressionSession? {
        let outputAttributes: CFDictionary = [
            kCVPixelBufferPixelFormatTypeKey:   kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferMetalCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
        ] as CFDictionary

        var callback = VTDecompressionOutputCallbackRecord(
            decompressionOutputCallback: { userData, _, status, _, imageBuffer, presentationTime, _ in
                guard let userData else { return }

                if status != noErr {
                    print("[VTDecoder] 解码输出回调失败: status=\(status)")
                    return
                }

                guard let imageBuffer else {
                    print("[VTDecoder] 解码输出回调失败: imageBuffer 为空")
                    return
                }

                let decoder = Unmanaged<VideoToolboxDecoder>
                    .fromOpaque(userData)
                    .takeUnretainedValue()

                let w = CVPixelBufferGetWidth(imageBuffer)
                let h = CVPixelBufferGetHeight(imageBuffer)
                decoder.decodedFrameCount += 1
                if decoder.decodedFrameCount <= 5 {
                    print("[VTDecoder] 解码成功 #\(decoder.decodedFrameCount): \(w)x\(h)")
                }

                decoder.onFrameDecoded?(imageBuffer, presentationTime)
            },
            decompressionOutputRefCon: Unmanaged.passUnretained(self).toOpaque()
        )

        let decoderSpec: CFDictionary = [
            kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder: true,
        ] as CFDictionary

        var session: VTDecompressionSession?
        let err = VTDecompressionSessionCreate(
            allocator:              kCFAllocatorDefault,
            formatDescription:      formatDesc,
            decoderSpecification:   decoderSpec,
            imageBufferAttributes:  outputAttributes,
            outputCallback:         &callback,
            decompressionSessionOut: &session
        )

        if err == noErr {
            print("[VTDecoder] 解码会话创建成功（硬件加速）")
        } else {
            print("[VTDecoder] 解码会话创建失败: \(err)")
        }

        return session
    }

    // MARK: - CMBlockBuffer 辅助

    /// 将裸 NALU 包装为 AVCC 格式的 CMBlockBuffer
    /// AVCC = [4字节大端长度][NALU数据]
    private func makeBlockBuffer(from nalu: Data) -> CMBlockBuffer? {
        var length = UInt32(nalu.count).bigEndian
        let headerData = Data(bytes: &length, count: 4)
        let combined = headerData + nalu
        let combinedCount = combined.count

        var blockBuffer: CMBlockBuffer?
        let createStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator:        kCFAllocatorDefault,
            memoryBlock:      nil,
            blockLength:      combinedCount,
            blockAllocator:   kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData:     0,
            dataLength:       combinedCount,
            flags:            0,
            blockBufferOut:   &blockBuffer
        )
        guard createStatus == kCMBlockBufferNoErr, let blockBuffer else { return nil }

        let copyStatus = combined.withUnsafeBytes { src in
            CMBlockBufferReplaceDataBytes(
                with: src.baseAddress!,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: combinedCount
            )
        }
        guard copyStatus == kCMBlockBufferNoErr else { return nil }

        return blockBuffer
    }

    private func makeBlockBuffer(from nalus: [Data]) -> CMBlockBuffer? {
        let combined = nalus.reduce(into: Data()) { partialResult, nalu in
            var length = UInt32(nalu.count).bigEndian
            partialResult.append(Data(bytes: &length, count: 4))
            partialResult.append(nalu)
        }
        let combinedCount = combined.count

        var blockBuffer: CMBlockBuffer?
        let createStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator:        kCFAllocatorDefault,
            memoryBlock:      nil,
            blockLength:      combinedCount,
            blockAllocator:   kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData:     0,
            dataLength:       combinedCount,
            flags:            0,
            blockBufferOut:   &blockBuffer
        )
        guard createStatus == kCMBlockBufferNoErr, let blockBuffer else { return nil }

        let copyStatus = combined.withUnsafeBytes { src in
            CMBlockBufferReplaceDataBytes(
                with: src.baseAddress!,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: combinedCount
            )
        }
        guard copyStatus == kCMBlockBufferNoErr else { return nil }

        return blockBuffer
    }
}
