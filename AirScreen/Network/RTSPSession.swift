//
//  RTSPSession.swift
//  AirScreen
//
//  管理单条 iOS ↔ Mac AirPlay RTSP 控制连接
//  处理：OPTIONS / ANNOUNCE / SETUP / RECORD / TEARDOWN 等 RTSP 方法
//
//  RTSP 协议格式类似 HTTP/1.1，消息结构：
//    请求行: METHOD uri RTSP/1.0\r\n
//    头部:   Header: Value\r\n
//    空行:   \r\n
//    正文:   (可选，Content-Length 指定长度)
//

import Foundation
import Network

// MARK: - 数据模型

struct RTSPRequest {
    var method:     String
    var uri:        String
    var headers:    [String: String]
    var body:       Data
    var cseq:       Int { Int(headers["cseq"] ?? "0") ?? 0 }
    var contentType: String { headers["content-type"] ?? "" }
    var contentLength: Int { Int(headers["content-length"] ?? "0") ?? 0 }
}

struct RTSPResponse {
    var statusCode: Int    = 200
    var statusText: String = "OK"
    var headers:    [String: String] = [:]
    var body:       Data = Data()

    func encode() -> Data {
        var lines = "RTSP/1.0 \(statusCode) \(statusText)\r\n"
        for (key, val) in headers {
            lines += "\(key): \(val)\r\n"
        }
        if !body.isEmpty {
            lines += "Content-Length: \(body.count)\r\n"
        }
        lines += "\r\n"
        var data = lines.data(using: .utf8)!
        data.append(body)
        return data
    }
}

// MARK: - 会话状态

enum RTSPSessionState {
    case idle, paired, setup, streaming, teardown
}

// MARK: - RTSPSession

/// 负责协议状态机和 RTSP 消息的收发
final class RTSPSession {

    // MARK: 回调

    /// 解析到 SDP 后触发，传递视频/音频参数
    var onSDPReceived: ((SDPSession) -> Void)?
    /// 视频 RTP 端口协商完成后触发
    var onVideoPortNegotiated: ((UInt16) -> Void)?
    /// 音频 RTP 端口协商完成后触发
    var onAudioPortNegotiated: ((UInt16) -> Void)?
    /// 连接断开后触发
    var onTeardown: (() -> Void)?

    // MARK: 私有状态

    private let connection: NWConnection
    private let queue: DispatchQueue
    private var state: RTSPSessionState = .idle
    private var receiveBuffer = Data()

    // 协商好的 RTP 端口（接收端监听）
    private var videoRTPPort: UInt16 = 7010
    private var audioRTPPort: UInt16 = 6000

    private let sessionID: String

    init(connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        self.queue      = queue
        self.sessionID  = UUID().uuidString.prefix(8).lowercased()
    }

    // MARK: - 启动

    func start() {
        connection.start(queue: queue)
        receiveNext()
        print("[RTSP:\(sessionID)] 新连接已建立，endpoint=\(connection.endpoint)")
    }

    // MARK: - 接收循环

    private func receiveNext() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let error {
                print("[RTSP:\(self.sessionID)] 接收错误: \(error)")
                self.onTeardown?()
                return
            }

            if let data, !data.isEmpty {
                self.receiveBuffer.append(data)
                self.processBuffer()
            }

            if isComplete {
                print("[RTSP:\(self.sessionID)] 连接关闭")
                self.onTeardown?()
                return
            }

            self.receiveNext()
        }
    }

    // MARK: - 消息解析（缓冲区处理）

    private func processBuffer() {
        // RTSP 消息以 \r\n\r\n 分隔头部和正文
        while true {
            guard let request = tryParseRequest() else { break }
            handle(request: request)
        }
    }

    private func tryParseRequest() -> RTSPRequest? {
        guard let bufStr = String(data: receiveBuffer, encoding: .utf8) else { return nil }

        // 找到头部结束标记
        guard let headerEnd = bufStr.range(of: "\r\n\r\n") else { return nil }

        let headerSection = String(bufStr[..<headerEnd.lowerBound])
        let bodyStart     = receiveBuffer.count - bufStr[headerEnd.upperBound...].utf8.count

        var lines  = headerSection.components(separatedBy: "\r\n")
        guard !lines.isEmpty else { return nil }

        // 解析请求行
        let requestLine = lines.removeFirst().components(separatedBy: " ")
        guard requestLine.count >= 3 else { return nil }
        let method = requestLine[0]
        let uri    = requestLine[1]

        // 解析头部
        var headers = [String: String]()
        for line in lines {
            let parts = line.components(separatedBy: ": ")
            if parts.count >= 2 {
                headers[parts[0].lowercased()] = parts[1...].joined(separator: ": ")
            }
        }

        // 读取正文
        let contentLength = Int(headers["content-length"] ?? "0") ?? 0
        let available     = receiveBuffer.count - bodyStart

        guard available >= contentLength else { return nil }  // 等待完整正文

        let body = contentLength > 0
            ? receiveBuffer[bodyStart ..< (bodyStart + contentLength)]
            : Data()

        // 消费已解析的字节
        receiveBuffer = Data(receiveBuffer[(bodyStart + contentLength)...])

        return RTSPRequest(method: method, uri: uri, headers: headers, body: body)
    }

    // MARK: - 请求分发

    private func handle(request: RTSPRequest) {
        print("[RTSP:\(sessionID)] → \(request.method) \(request.uri) cseq=\(request.cseq)")

        switch request.method.uppercased() {
        case "OPTIONS":   handleOptions(request)
        case "ANNOUNCE":  handleAnnounce(request)
        case "SETUP":     handleSetup(request)
        case "RECORD":    handleRecord(request)
        case "SET_PARAMETER": handleSetParameter(request)
        case "GET_PARAMETER": handleGetParameter(request)
        case "TEARDOWN":  handleTeardown(request)
        default:
            send(response: makeResponse(request: request, status: 405, statusText: "Method Not Allowed"))
        }
    }

    // MARK: - 各方法处理

    private func handleOptions(_ req: RTSPRequest) {
        var resp = makeResponse(request: req)
        resp.headers["Public"] = "ANNOUNCE, SETUP, RECORD, PAUSE, FLUSH, TEARDOWN, OPTIONS, GET_PARAMETER, SET_PARAMETER"
        send(response: resp)
    }

    private func handleAnnounce(_ req: RTSPRequest) {
        // 正文为 SDP 描述
        guard let sdpText = String(data: req.body, encoding: .utf8) else {
            send(response: makeResponse(request: req, status: 400, statusText: "Bad Request"))
            return
        }
        print("[RTSP:\(sessionID)] SDP:\n\(sdpText)")

        let sdp = SDPParser.parse(sdpText)
        let videoCodec = sdp.videoTrack?.codec ?? "none"
        let audioCodec = sdp.audioTrack?.codec ?? "none"
        print("[RTSP:\(sessionID)] SDP 摘要: video=\(videoCodec) audio=\(audioCodec)")
        onSDPReceived?(sdp)

        send(response: makeResponse(request: req))
    }

    private func handleSetup(_ req: RTSPRequest) {
        // Transport: RTP/AVP;unicast;client_port=7010-7011
        let transport = req.headers["transport"] ?? ""
        let isVideo   = req.uri.contains("video") || req.uri.contains("stream=0")

        // 解析客户端端口（iOS 端 RTP 接收端口，此处我们不向 iOS 发 RTP，可忽略）
        // 服务端端口（Mac 监听端口）由我们指定
        let serverPort = isVideo ? videoRTPPort : audioRTPPort
        print("[RTSP:\(sessionID)] SETUP transport=\(transport) isVideo=\(isVideo) serverPort=\(serverPort)")

        var resp = makeResponse(request: req)
        // 告知 iOS 我们监听的端口
        resp.headers["Transport"] = "RTP/AVP/UDP;unicast;server_port=\(serverPort)-\(serverPort + 1)"
        resp.headers["Session"]   = sessionID

        send(response: resp)
        print("[RTSP:\(sessionID)] SETUP 响应 transport=\(resp.headers["Transport"] ?? "") session=\(sessionID)")

        // 通知外部开始监听 RTP
        if isVideo {
            onVideoPortNegotiated?(serverPort)
        } else {
            onAudioPortNegotiated?(serverPort)
        }
    }

    private func handleRecord(_ req: RTSPRequest) {
        state = .streaming
        var resp = makeResponse(request: req)
        resp.headers["Session"] = sessionID
        resp.headers["Range"]   = "npt=0-"
        send(response: resp)
        print("[RTSP:\(sessionID)] 🎬 开始接收视频流，state=\(state)")
    }

    private func handleSetParameter(_ req: RTSPRequest) {
        // iOS 会发送音量等控制参数，简单返回 OK
        send(response: makeResponse(request: req))
    }

    private func handleGetParameter(_ req: RTSPRequest) {
        send(response: makeResponse(request: req))
    }

    private func handleTeardown(_ req: RTSPRequest) {
        state = .teardown
        send(response: makeResponse(request: req))
        connection.cancel()
        onTeardown?()
        print("[RTSP:\(sessionID)] 连接断开（TEARDOWN） cseq=\(req.cseq)")
    }

    // MARK: - 工具

    private func makeResponse(
        request: RTSPRequest,
        status: Int = 200,
        statusText: String = "OK"
    ) -> RTSPResponse {
        var resp = RTSPResponse(statusCode: status, statusText: statusText)
        resp.headers["CSeq"]         = "\(request.cseq)"
        resp.headers["Date"]         = RFC1123DateFormatter.string(from: Date())
        resp.headers["Server"]       = "AirScreen/1.0"
        return resp
    }

    private func send(response: RTSPResponse) {
        let data = response.encode()
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            if let error {
                print("[RTSP:\(self?.sessionID ?? "")] 发送失败: \(error)")
            }
        })
    }
}

// MARK: - 辅助：HTTP Date 格式

private enum RFC1123DateFormatter {
    static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale     = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        f.timeZone   = TimeZone(abbreviation: "GMT")
        return f
    }()

    static func string(from date: Date) -> String {
        formatter.string(from: date)
    }
}
