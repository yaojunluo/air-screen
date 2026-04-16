//
//  RTSPServer.swift
//  AirScreen
//
//  在 TCP 7000 端口监听，接受 iOS 设备的 AirPlay 控制连接
//  每个连接创建一个独立的 RTSPSession 处理协议状态机
//

import Foundation
import Network

// MARK: - 事件回调协议

protocol RTSPServerDelegate: AnyObject {
    /// SDP 解析完成，收到视频/音频参数
    func rtspServer(_ server: RTSPServer, didReceiveSDP sdp: SDPSession)
    /// 视频 RTP 端口已协商
    func rtspServer(_ server: RTSPServer, videoRTPPort port: UInt16)
    /// 音频 RTP 端口已协商
    func rtspServer(_ server: RTSPServer, audioRTPPort port: UInt16)
    /// 某个会话断开
    func rtspServerDidTeardown(_ server: RTSPServer)
    /// RTSP 监听启动失败
    func rtspServer(_ server: RTSPServer, didFailToStart error: Error, requestedPort: UInt16)
    /// RTSP 监听已就绪
    func rtspServerDidStartListening(_ server: RTSPServer, port: UInt16)
}

// MARK: -

final class RTSPServer {

    weak var delegate: RTSPServerDelegate?

    private var listener: NWListener?
    private var activeSessions: [RTSPSession] = []
    private let queue = DispatchQueue(label: "com.airscreen.rtsp", qos: .userInteractive)
    private(set) var listenPort: UInt16?
    private(set) var restartEnabled = true

    /// 启动监听（端口 7000）
    func start(on port: UInt16 = AirPlayServicePorts.standard.airPlay, allowRestartOnFailure: Bool = true) throws {
        stop()
        restartEnabled = allowRestartOnFailure
        listenPort = port

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true

        print("[RTSPServer] 正在启动监听，端口 \(port)")
        listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        listener?.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                print("[RTSPServer] 监听就绪，端口 \(port)")
                self.delegate?.rtspServerDidStartListening(self, port: port)
            case .failed(let error):
                print("[RTSPServer] 监听失败，端口 \(port): \(error)")
                self.delegate?.rtspServer(self, didFailToStart: error, requestedPort: port)
                if self.restartEnabled {
                    self.restart(on: port)
                }
            default:
                break
            }
        }

        listener?.newConnectionHandler = { [weak self] connection in
            self?.handleNewConnection(connection)
        }

        listener?.start(queue: queue)
    }

    /// 停止监听
    func stop() {
        restartEnabled = false
        listener?.cancel()
        listener = nil
        listenPort = nil
        activeSessions.forEach { _ in }
        activeSessions.removeAll()
        print("[RTSPServer] 已停止")
    }

    // MARK: - 私有

    private func handleNewConnection(_ connection: NWConnection) {
        print("[RTSPServer] 接收到新连接: \(connection.endpoint)")
        let session = RTSPSession(connection: connection, queue: queue)

        session.onSDPReceived = { [weak self] sdp in
            guard let self else { return }
            DispatchQueue.main.async {
                self.delegate?.rtspServer(self, didReceiveSDP: sdp)
            }
        }

        session.onVideoPortNegotiated = { [weak self] port in
            guard let self else { return }
            DispatchQueue.main.async {
                self.delegate?.rtspServer(self, videoRTPPort: port)
            }
        }

        session.onAudioPortNegotiated = { [weak self] port in
            guard let self else { return }
            DispatchQueue.main.async {
                self.delegate?.rtspServer(self, audioRTPPort: port)
            }
        }

        session.onTeardown = { [weak self] in
            guard let self else { return }
            self.queue.async {
                self.activeSessions.removeAll { $0 === session }
            }
            DispatchQueue.main.async {
                self.delegate?.rtspServerDidTeardown(self)
            }
        }

        activeSessions.append(session)
        session.start()
    }

    private func restart(on port: UInt16) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            try? self?.start(on: port)
        }
    }
}
