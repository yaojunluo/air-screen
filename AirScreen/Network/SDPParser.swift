//
//  SDPParser.swift
//  AirScreen
//
//  解析 RTSP ANNOUNCE 消息中的 SDP（Session Description Protocol）
//  从中提取视频/音频的编解码参数、分辨率、SPS/PPS 等关键信息
//

import Foundation

/// SDP 解析结果 - 视频轨道参数
struct SDPVideoTrack {
    var payloadType: Int       = 96
    var codec: String          = "H264"    // H264 | H265
    var width: Int             = 1920
    var height: Int            = 1080
    var clockRate: Int         = 90000
    var profileLevelID: String = ""
    var sps: Data?             // H.264 Sequence Parameter Set（原始，不含起始码）
    var pps: Data?             // H.264 Picture Parameter Set（原始，不含起始码）
}

/// SDP 解析结果 - 音频轨道参数
struct SDPAudioTrack {
    var payloadType: Int  = 96
    var codec: String     = "mpeg4-generic"  // mpeg4-generic(AAC) | AppleLossless
    var sampleRate: Int   = 44100
    var channels: Int     = 2
    var clockRate: Int    = 44100
}

/// SDP 完整解析结果
struct SDPSession {
    var videoTrack: SDPVideoTrack?
    var audioTrack: SDPAudioTrack?
    var sessionName: String = ""
}

// MARK: -

final class SDPParser {

    /// 解析 SDP 文本，返回结构化结果
    static func parse(_ sdpText: String) -> SDPSession {
        var session   = SDPSession()
        var curVideo: SDPVideoTrack?
        var curAudio: SDPAudioTrack?
        var inVideo   = false
        var inAudio   = false

        for rawLine in sdpText.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.count >= 2, line[line.startIndex] != "#" else { continue }

            let typeChar = line[line.startIndex]
            let value    = String(line.dropFirst(2))  // 跳过 "X=" 前缀

            switch typeChar {

            case "s":
                session.sessionName = value

            case "m":
                // m=<media> <port> <proto> <fmt>
                // e.g.: m=video 0 RTP/AVP 96
                let parts = value.components(separatedBy: " ")
                guard parts.count >= 4 else { continue }
                let mediaType  = parts[0]
                let payloadType = Int(parts.last ?? "96") ?? 96

                if mediaType == "video" {
                    inVideo = true; inAudio = false
                    curVideo = SDPVideoTrack()
                    curVideo?.payloadType = payloadType
                } else if mediaType == "audio" {
                    inAudio = true; inVideo = false
                    curAudio = SDPAudioTrack()
                    curAudio?.payloadType = payloadType
                } else {
                    inVideo = false; inAudio = false
                }

            case "a":
                // a=<attribute>:<value>
                let colonIdx = value.firstIndex(of: ":") ?? value.endIndex
                let attrName = String(value[..<colonIdx])
                let attrVal  = colonIdx < value.endIndex
                    ? String(value[value.index(after: colonIdx)...])
                    : ""

                if inVideo {
                    parseVideoAttribute(name: attrName, value: attrVal, track: &curVideo)
                } else if inAudio {
                    parseAudioAttribute(name: attrName, value: attrVal, track: &curAudio)
                }

            default:
                break
            }
        }

        session.videoTrack = curVideo
        session.audioTrack = curAudio
        return session
    }

    // MARK: - 视频属性解析

    private static func parseVideoAttribute(name: String, value: String, track: inout SDPVideoTrack?) {
        guard track != nil else { return }

        switch name.lowercased() {

        case "rtpmap":
            // a=rtpmap:96 H264/90000
            // a=rtpmap:96 H265/90000
            let parts = value.components(separatedBy: " ")
            if parts.count >= 2 {
                let codecParts = parts[1].components(separatedBy: "/")
                track?.codec     = codecParts[0].uppercased()
                track?.clockRate = Int(codecParts.last ?? "90000") ?? 90000
            }

        case "fmtp":
            // a=fmtp:96 profile-level-id=640028;sprop-parameter-sets=Z2QAK....,aNkAmA==
            // a=fmtp:96 packetization-mode=1;profile-level-id=42e028;sprop-parameter-sets=...
            let paramStr = value.components(separatedBy: " ").dropFirst().joined(separator: " ")
            let params   = parseParams(paramStr, separator: ";")

            if let pli = params["profile-level-id"] {
                track?.profileLevelID = pli
            }

            if let spropStr = params["sprop-parameter-sets"] {
                // sprop-parameter-sets=<SPS base64>,<PPS base64>
                let sets = spropStr.components(separatedBy: ",")
                if sets.count >= 1, let spsData = Data(base64Encoded: sets[0], options: .ignoreUnknownCharacters) {
                    track?.sps = spsData
                }
                if sets.count >= 2, let ppsData = Data(base64Encoded: sets[1], options: .ignoreUnknownCharacters) {
                    track?.pps = ppsData
                }
            }

        case "framesize":
            // a=frameSize:96 1920-1080
            let parts = value.components(separatedBy: " ")
            if parts.count >= 2 {
                let dims = parts[1].components(separatedBy: "-")
                track?.width  = Int(dims[0]) ?? 1920
                track?.height = dims.count >= 2 ? (Int(dims[1]) ?? 1080) : 1080
            }

        default:
            break
        }
    }

    // MARK: - 音频属性解析

    private static func parseAudioAttribute(name: String, value: String, track: inout SDPAudioTrack?) {
        guard track != nil else { return }

        switch name.lowercased() {

        case "rtpmap":
            // a=rtpmap:96 mpeg4-generic/44100/2
            let parts = value.components(separatedBy: " ")
            if parts.count >= 2 {
                let codecParts = parts[1].components(separatedBy: "/")
                track?.codec = codecParts[0]
                let clockRate = Int(codecParts.dropFirst().first ?? "44100") ?? 44100
                track?.clockRate = clockRate
                track?.sampleRate = clockRate
                track?.channels = Int(codecParts.last ?? "2") ?? 2
            }

        default:
            break
        }
    }

    // MARK: - 工具方法

    /// 解析 key=value;key2=value2 格式的参数字符串
    private static func parseParams(_ str: String, separator: Character) -> [String: String] {
        var dict = [String: String]()
        for part in str.components(separatedBy: String(separator)) {
            let kv = part.trimmingCharacters(in: .whitespaces).components(separatedBy: "=")
            guard kv.count >= 2 else { continue }
            let key = kv[0].trimmingCharacters(in: .whitespaces).lowercased()
            let val = kv[1...].joined(separator: "=").trimmingCharacters(in: .whitespaces)
            dict[key] = val
        }
        return dict
    }
}
