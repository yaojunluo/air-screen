//
//  AudioPlayer.swift
//  AirScreen
//
//  接收音频 RTP 包并使用 AVAudioEngine 播放
//  支持 AAC-LC（AirPlay 屏幕镜像默认音频编解码器）
//

import Foundation
import AVFoundation
import CoreMedia
import AudioToolbox

// AudioConverter 回调上下文（必须在类外定义以便 C 回调访问）
private struct AACInputContext {
    var dataPtr: UnsafeMutableRawPointer
    var dataSize: UInt32
    var descPtr: UnsafeMutablePointer<AudioStreamPacketDescription>
    var consumed: Bool
}

final class AudioPlayer {

    // MARK: - 私有属性

    private let engine        = AVAudioEngine()
    private let playerNode    = AVAudioPlayerNode()
    private var converter:     AVAudioConverter?

    // AAC 解码器
    private var audioConverter: AudioConverterRef?
    private var inputFormat:    AudioStreamBasicDescription?
    private var outputFormat    = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 2)!

    private var isRunning  = false
    private var currentCodecType: Int = 0  // 1=AAC-LC, 2=AAC-ELD, 4=ALAC, 8=AAC-ELD(mirror)
    private var framesPerPacket: UInt32 = 1024
    private var decodeErrorCount = 0
    private let audioQueue = DispatchQueue(label: "com.airscreen.audio", qos: .userInteractive)

    // MARK: - 初始化

    init() {
        setupEngine()
    }

    // MARK: - 公开接口

    private var audioPacketCount = 0

    /// 配置音频参数（从 SDP 解析的 SDPAudioTrack）
    func configure(track: SDPAudioTrack) {
        audioQueue.async { [weak self] in
            guard let self else { return }
            self.setupAudioDecoder(sampleRate: Double(track.sampleRate),
                                   channels:   UInt32(track.channels),
                                   formatID:   kAudioFormatMPEG4AAC,
                                   framesPerPacket: 1024)
        }
    }

    /// 配置音频参数（AirPlay 2 镜像，直接传入参数）
    /// codecType: 1=AAC-LC, 2=AAC-ELD, 4=ALAC, 8=AAC-ELD(mirror)
    func configureForMirror(sampleRate: Int, channels: Int, codecType: Int, samplesPerFrame: Int = 0) {
        audioQueue.async { [weak self] in
            guard let self else { return }
            self.audioPacketCount = 0
            self.currentCodecType = codecType

            switch codecType {
            case 8, 4:
                // ct=8 在屏幕镜像中实际是 AAC-ELD（spf=480，压缩音频）
                let spf = samplesPerFrame > 0 ? samplesPerFrame : 480
                self.setupAudioDecoder(sampleRate: Double(sampleRate),
                                       channels: UInt32(channels),
                                       formatID: kAudioFormatMPEG4AAC_ELD,
                                       framesPerPacket: UInt32(spf))
            default:
                // ct=1,2 等: AAC-LC
                let spf = samplesPerFrame > 0 ? samplesPerFrame : 1024
                self.setupAudioDecoder(sampleRate: Double(sampleRate),
                                       channels: UInt32(channels),
                                       formatID: kAudioFormatMPEG4AAC,
                                       framesPerPacket: UInt32(spf))
            }
            print("[Audio] 镜像音频配置: sr=\(sampleRate) ch=\(channels) ct=\(codecType) spf=\(samplesPerFrame)")
        }
    }

    /// 输入音频 RTP 负载（已去掉 RTP 头）
    func enqueue(rtpPayload: Data, timestamp: UInt32) {
        audioQueue.async { [weak self] in
            guard let self else { return }
            self.audioPacketCount += 1
            if self.audioPacketCount <= 5 {
                let hex = rtpPayload.prefix(16).map { String(format: "%02x", $0) }.joined(separator: " ")
                print("[Audio] 收到音频包 #\(self.audioPacketCount): \(rtpPayload.count)B hex=\(hex)")
            }
            self.decodeAndPlay(payload: rtpPayload)
        }
    }

    /// 停止播放
    func stop() {
        audioQueue.async { [weak self] in
            guard let self, self.isRunning else { return }
            self.playerNode.stop()
            self.engine.stop()
            self.isRunning = false
            if let conv = self.audioConverter {
                AudioConverterDispose(conv)
                self.audioConverter = nil
            }
            print("[Audio] 已停止")
        }
    }

    // MARK: - 引擎配置

    private func setupEngine() {
        engine.attach(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: outputFormat)

        do {
            try engine.start()
            playerNode.play()
            isRunning = true
            print("[Audio] AVAudioEngine 启动成功")
        } catch {
            print("[Audio] AVAudioEngine 启动失败: \(error)")
        }
    }

    // MARK: - 音频解码器（AAC-LC / AAC-ELD）

    private func setupAudioDecoder(sampleRate: Double, channels: UInt32,
                                   formatID: AudioFormatID, framesPerPacket: UInt32) {
        if let old = audioConverter {
            AudioConverterDispose(old)
            audioConverter = nil
        }

        self.framesPerPacket = framesPerPacket
        self.decodeErrorCount = 0

        // 输出格式：PCM Float32 non-interleaved（AVAudioEngine 要求）
        var outASBD = AudioStreamBasicDescription(
            mSampleRate:       sampleRate,
            mFormatID:         kAudioFormatLinearPCM,
            mFormatFlags:      kAudioFormatFlagIsFloat | kAudioFormatFlagIsNonInterleaved | kAudioFormatFlagIsPacked,
            mBytesPerPacket:   4,
            mFramesPerPacket:  1,
            mBytesPerFrame:    4,
            mChannelsPerFrame: channels,
            mBitsPerChannel:   32,
            mReserved:         0
        )

        // 尝试多种格式：优先用指定的，失败则回退
        let formatsToTry: [(AudioFormatID, String)] = {
            if formatID == kAudioFormatMPEG4AAC_ELD {
                return [
                    (kAudioFormatMPEG4AAC_ELD, "AAC-ELD"),
                    (kAudioFormatMPEG4AAC_ELD_SBR, "AAC-ELD-SBR"),
                    (kAudioFormatMPEG4AAC_ELD_V2, "AAC-ELD-V2"),
                    (kAudioFormatMPEG4AAC, "AAC-LC"),
                ]
            } else {
                return [(formatID, "AAC-LC")]
            }
        }()

        var succeeded = false
        for (fmtID, fmtName) in formatsToTry {
            var inASBD = AudioStreamBasicDescription(
                mSampleRate:       sampleRate,
                mFormatID:         fmtID,
                mFormatFlags:      0,
                mBytesPerPacket:   0,
                mFramesPerPacket:  framesPerPacket,
                mBytesPerFrame:    0,
                mChannelsPerFrame: channels,
                mBitsPerChannel:   0,
                mReserved:         0
            )

            let status = AudioConverterNew(&inASBD, &outASBD, &audioConverter)
            if status == noErr {
                inputFormat = inASBD
                print("[Audio] 解码器创建成功: \(fmtName) (\(Int(sampleRate))Hz \(channels)ch spf=\(framesPerPacket))")
                succeeded = true
                break
            } else {
                print("[Audio] 尝试 \(fmtName) 失败: status=\(status)")
            }
        }

        guard succeeded else {
            print("[Audio] 所有解码格式均失败，无法播放音频")
            return
        }

        // AVAudioEngine 标准格式：Float32 non-interleaved
        outputFormat = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)!

        // 必须先停止引擎再重连，否则格式冲突会崩溃
        playerNode.stop()
        engine.stop()
        engine.disconnectNodeOutput(playerNode)
        engine.connect(playerNode, to: engine.mainMixerNode, format: outputFormat)

        do {
            try engine.start()
            playerNode.play()
            isRunning = true
            print("[Audio] 引擎已启动，等待音频数据")
        } catch {
            print("[Audio] 引擎重启失败: \(error)")
        }
    }

    // MARK: - AAC 解码并播放

    private func decodeAndPlay(payload: Data) {
        guard let converter = audioConverter else {
            if audioPacketCount <= 3 {
                print("[Audio] 解码器未初始化，跳过")
            }
            return
        }
        guard !payload.isEmpty else { return }

        let outputFrameCount = AVAudioFrameCount(framesPerPacket)
        guard let pcmBuffer = AVAudioPCMBuffer(pcmFormat: outputFormat,
                                               frameCapacity: outputFrameCount) else { return }

        // 堆分配输入缓冲区（指针在回调期间保持有效）
        let inputSize = payload.count
        let inputPtr = UnsafeMutableRawPointer.allocate(byteCount: inputSize, alignment: 1)
        payload.copyBytes(to: inputPtr.assumingMemoryBound(to: UInt8.self), count: inputSize)

        // 堆分配包描述（VBR 格式必须提供）
        let descPtr = UnsafeMutablePointer<AudioStreamPacketDescription>.allocate(capacity: 1)
        descPtr.pointee = AudioStreamPacketDescription(
            mStartOffset: 0,
            mVariableFramesInPacket: 0,
            mDataByteSize: UInt32(inputSize)
        )

        defer {
            inputPtr.deallocate()
            descPtr.deallocate()
        }

        var ctx = AACInputContext(
            dataPtr: inputPtr,
            dataSize: UInt32(inputSize),
            descPtr: descPtr,
            consumed: false
        )

        var ioOutputDataPacketSize = outputFrameCount

        let status = AudioConverterFillComplexBuffer(
            converter,
            { (_, ioNumberDataPackets, ioData, outDataPacketDescription, userData) -> OSStatus in
                guard let userData else { return kAudioConverterErr_UnspecifiedError }
                let ctx = userData.assumingMemoryBound(to: AACInputContext.self)

                guard !ctx.pointee.consumed else {
                    ioNumberDataPackets.pointee = 0
                    return -1
                }

                ioData.pointee.mNumberBuffers = 1
                ioData.pointee.mBuffers.mData = ctx.pointee.dataPtr
                ioData.pointee.mBuffers.mDataByteSize = ctx.pointee.dataSize
                ioData.pointee.mBuffers.mNumberChannels = 0
                ioNumberDataPackets.pointee = 1
                ctx.pointee.consumed = true

                // 提供包描述（AAC 等 VBR 格式解码必须）
                if let outDataPacketDescription {
                    outDataPacketDescription.pointee = ctx.pointee.descPtr
                }

                return noErr
            },
            &ctx,
            &ioOutputDataPacketSize,
            pcmBuffer.mutableAudioBufferList,
            nil
        )

        if audioPacketCount <= 10 || (decodeErrorCount > 0 && decodeErrorCount <= 5) {
            print("[Audio] decode #\(audioPacketCount): status=\(status) inputSize=\(inputSize) outputFrames=\(ioOutputDataPacketSize)")
        }

        if status == noErr || status == -1 {
            pcmBuffer.frameLength = ioOutputDataPacketSize
            if pcmBuffer.frameLength > 0 {
                playerNode.scheduleBuffer(pcmBuffer)
            }
        } else {
            decodeErrorCount += 1
            if decodeErrorCount <= 10 {
                print("[Audio] 解码失败 #\(decodeErrorCount): status=\(status) inputSize=\(inputSize)")
            }
            AudioConverterReset(converter)
        }
    }
}
