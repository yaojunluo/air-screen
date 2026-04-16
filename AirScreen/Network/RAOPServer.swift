//
//  RAOPServer.swift
//  AirScreen
//
//  监听 _raop._tcp 宣告的端口
//  处理 iOS 发来的最初的探测连接，比如 GET /info
//  处理 AirPlay 配对协议 (pair-setup, pair-verify)
//

import Foundation
import Network
import CryptoKit
import CommonCrypto

// MARK: - TLV8 类型定义 (HAP 风格)
enum TLVType: UInt8 {
    case method = 0x00
    case identifier = 0x01
    case salt = 0x02
    case publicKey = 0x03
    case proof = 0x04
    case encryptedData = 0x05
    case state = 0x06
    case error = 0x07
    case certificate = 0x09
    case signature = 0x0A
    case pairingMethod = 0x0B
}

enum TLVMethod: UInt8 {
    case pairSetup = 1
    case pairVerify = 2
    case addPairing = 3
    case removePairing = 4
    case listPairings = 5
}

enum TLVError: UInt8 {
    case unknown = 0x01
    case authentication = 0x02
    case backoff = 0x03
    case maxPeers = 0x04
    case maxTries = 0x05
    case unavailable = 0x06
    case busy = 0x07
}

enum TLVState: UInt8 {
    case m1 = 1
    case m2 = 2
    case m3 = 3
    case m4 = 4
    case m5 = 5
    case m6 = 6
}

// MARK: - TLV8 编解码辅助
struct TLV8 {
    static func encode(_ items: [(TLVType, Data)]) -> Data {
        var result = Data()
        for (type, value) in items {
            var offset = 0
            while offset < value.count {
                let chunkSize = min(255, value.count - offset)
                result.append(type.rawValue)
                result.append(UInt8(chunkSize))
                result.append(value[offset..<(offset + chunkSize)])
                offset += chunkSize
            }
        }
        return result
    }

    static func decode(_ data: Data) -> [TLVType: Data] {
        var result: [TLVType: Data] = [:]
        var offset = 0
        while offset + 1 < data.count {
            let typeRaw = data[offset]
            let length = Int(data[offset + 1])
            offset += 2
            guard offset + length <= data.count else { break }
            guard let type = TLVType(rawValue: typeRaw) else {
                // 跳过未知类型
                offset += length
                continue
            }
            let chunk = data[offset..<(offset + length)]
            if var existing = result[type] {
                existing.append(chunk)
                result[type] = existing
            } else {
                result[type] = Data(chunk)
            }
            offset += length
        }
        return result
    }
}

// MARK: - 配对状态管理
final class PairingState {
    var setupState: TLVState = .m1
    var verifyState: TLVState = .m1
    var iOSPublicKey: Data?
    var sharedSecret: Data?
    var sessionKey: Data?
    var peerPublicKey: Curve25519.KeyAgreement.PublicKey?
    var ourEphemeralPrivateKey: Curve25519.KeyAgreement.PrivateKey?
    var ourEphemeralPublicKey: Data?
    var peerEphemeralPublicKey: Data?
    var peerLongTermPublicKey: Data?
    var fairPlayKeyMessage: Data?
    var sessionID: String = UUID().uuidString.replacingOccurrences(of: "-", with: "").uppercased()

    func reset() {
        setupState = .m1
        verifyState = .m1
        iOSPublicKey = nil
        sharedSecret = nil
        sessionKey = nil
        peerPublicKey = nil
        ourEphemeralPrivateKey = nil
        ourEphemeralPublicKey = nil
        peerEphemeralPublicKey = nil
        peerLongTermPublicKey = nil
        fairPlayKeyMessage = nil
        sessionID = UUID().uuidString.replacingOccurrences(of: "-", with: "").uppercased()
    }
}

final class RAOPServer {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.airscreen.raop", qos: .userInteractive)

    // 我们保留对每个连接的强引用直到它结束，否则连接会提前断开
    private var activeConnections: [NWConnection] = []
    private var receiveBuffers: [ObjectIdentifier: Data] = [:]

    // 配对状态（按连接）
    private var pairingStates: [ObjectIdentifier: PairingState] = [:]

    // 存储已配对的设备
    private var pairedDevices: [String: Data] = [:] // identifier -> public key
    private let pairedDevicesKey = "airplay.pairedDevices"
    private let receiverInstanceKey = "airplay.receiverInstanceID"
    private let displayUUIDKey = "airplay.displayUUID"

    // MARK: - AirPlay 2 Streaming

    /// 镜像流数据端口就绪时触发
    var onMirrorStreamReady: ((_ dataPort: UInt16) -> Void)?
    /// 流断开时触发
    var onStreamTeardown: (() -> Void)?
    /// 镜像数据到达时触发（128字节头 + payload）
    var onMirrorData: ((_ header: Data, _ payload: Data) -> Void)?
    /// 音频 RTP 数据到达时触发（已去掉 RTP 头的 AAC payload）
    var onAudioData: ((_ payload: Data, _ timestamp: UInt32) -> Void)?
    /// 音频流格式信息（来自 SETUP）
    private(set) var audioFormat: (sampleRate: Int, channels: Int, codecType: Int, spf: Int)?

    private var mirrorDataPort: UInt16 = 7100
    private var eventPort: UInt16 = 7101
    private var audioDataPort: UInt16 = 7102
    private var audioControlPort: UInt16 = 7103
    private var timingPort: UInt16 = 7104
    private var mirrorDataListener: NWListener?
    private var eventListener: NWListener?
    private var audioDataListener: NWListener?
    private var audioControlListener: NWListener?
    private var timingListener: NWListener?
    private var mirrorConnections: [NWConnection] = []
    private var eventConnections: [NWConnection] = []
    private var audioConnections: [NWConnection] = []
    private var timingConnections: [NWConnection] = []
    private var mirrorReceiveBuffers: [ObjectIdentifier: Data] = [:]
    private var audioPacketCount = 0
    private let mirrorQueue = DispatchQueue(label: "com.airscreen.mirror", qos: .userInteractive)

    // 避免重复启动监听器
    private var isEventListenerActive = false
    private var isMirrorListenerActive = false
    private var isAudioListenerActive = false

    // 会话加密密钥（SETUP 第一阶段获取）
    private var streamEncryptionKey: Data?
    private var streamEncryptionIV: Data?
    private var streamEncryptionType: Int = 0  // 0=none, 1=AES-CTR, 3=FairPlay
    private var mirrorStreamConnectionID: UInt64?
    private var mirrorAESKey: Data?
    private var mirrorAESIV: Data?
    private var mirrorCryptor: CCCryptorRef?

    func start(on port: UInt16) throws {
        stop()
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        
        listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
        listener?.stateUpdateHandler = { state in
            switch state {
            case .ready:
                print("[RAOPServer] 监听就绪，端口 \(port)")
            case .failed(let error):
                print("[RAOPServer] 监听失败，端口 \(port): \(error)")
            default:
                break
            }
        }
        
        listener?.newConnectionHandler = { [weak self] connection in
            self?.handleNewConnection(connection)
        }
        
        listener?.start(queue: queue)
    }
    
    func stop() {
        listener?.cancel()
        listener = nil
        activeConnections.forEach { $0.cancel() }
        activeConnections.removeAll()
        receiveBuffers.removeAll()
        stopStreamListeners()
    }

    private func stopStreamListeners() {
        mirrorDataListener?.cancel()
        mirrorDataListener = nil
        eventListener?.cancel()
        eventListener = nil
        audioDataListener?.cancel()
        audioDataListener = nil
        audioControlListener?.cancel()
        audioControlListener = nil
        timingListener?.cancel()
        timingListener = nil
        mirrorConnections.forEach { $0.cancel() }
        mirrorConnections.removeAll()
        eventConnections.forEach { $0.cancel() }
        eventConnections.removeAll()
        audioConnections.forEach { $0.cancel() }
        audioConnections.removeAll()
        timingConnections.forEach { $0.cancel() }
        timingConnections.removeAll()
        mirrorReceiveBuffers.removeAll()
        isEventListenerActive = false
        isMirrorListenerActive = false
        isAudioListenerActive = false
        audioPacketCount = 0
        mirrorFrameCount = 0
        streamEncryptionKey = nil
        streamEncryptionIV = nil
        streamEncryptionType = 0
        mirrorStreamConnectionID = nil
        mirrorAESKey = nil
        mirrorAESIV = nil
        if let mirrorCryptor {
            CCCryptorRelease(mirrorCryptor)
            self.mirrorCryptor = nil
        }
    }
    
    private func handleNewConnection(_ connection: NWConnection) {
        print("[RAOPServer] 接收到新连接: \(connection.endpoint)")
        activeConnections.append(connection)
        receiveBuffers[ObjectIdentifier(connection)] = Data()
        pairingStates[ObjectIdentifier(connection)] = PairingState()

        connection.stateUpdateHandler = { [weak self, weak connection] state in
            switch state {
            case .failed(let error):
                print("[RAOPServer] 连接失败: \(error)")
                if let conn = connection {
                    self?.removeConnection(conn)
                }
            case .cancelled:
                if let conn = connection {
                    self?.removeConnection(conn)
                }
            default:
                break
            }
        }

        connection.start(queue: queue)
        receiveNext(on: connection)
    }
    
    private func receiveNext(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, context, isComplete, error in
            guard let self else { return }

            if let error {
                print("[RAOPServer] 接收错误: \(error)")
                self.removeConnection(connection)
                return
            }

            let connectionID = ObjectIdentifier(connection)
            if let data, !data.isEmpty {
                var buffer = self.receiveBuffers[connectionID] ?? Data()
                buffer.append(data)
                self.receiveBuffers[connectionID] = buffer
                self.processBuffer(for: connection)
            }

            if !isComplete {
                self.receiveNext(on: connection)
            } else {
                print("[RAOPServer] 连接关闭: \(connection.endpoint)")
                self.removeConnection(connection)
            }
        }
    }
    
    private func processBuffer(for connection: NWConnection) {
        let connectionID = ObjectIdentifier(connection)

        while true {
            guard let buffer = receiveBuffers[connectionID] else { return }
            guard let headerEndRange = buffer.range(of: Data("\r\n\r\n".utf8)) else { return }

            let headerData = buffer[..<headerEndRange.lowerBound]
            guard let headerString = String(data: headerData, encoding: .ascii) else {
                print("[RAOPServer] 无法解析请求头，丢弃连接")
                removeConnection(connection)
                connection.cancel()
                return
            }

            let contentLength = parseContentLength(from: headerString)
            let messageLength = headerEndRange.upperBound + contentLength
            guard buffer.count >= messageLength else { return }

            let body = contentLength > 0
                ? buffer[headerEndRange.upperBound..<messageLength]
                : Data()

            receiveBuffers[connectionID] = Data(buffer[messageLength...])
            handleRequest(header: headerString, body: Data(body), connection: connection)
        }
    }

    private func handleRequest(header: String, body: Data, connection: NWConnection) {
        let requestLine = header.components(separatedBy: "\r\n").first ?? ""
        print("[RAOPServer] 收到请求: \(requestLine) body=\(body.count)B")

        if requestLine.hasPrefix("GET /info") {
            print("[RAOPServer] 收到 GET /info，准备返回 binary plist")
            sendInfoResponse(connection: connection, requestHeader: header)
            return
        }

        // pair-pin-start / pair-setup-pin 必须在 pair-setup 之前匹配（前缀冲突）
        if requestLine.hasPrefix("POST /pair-pin-start") {
            let cseq = parseCSeq(from: header)
            print("[RAOPServer] pair-pin-start: PIN 配对已禁用，返回 200")
            sendBinaryResponse(connection: connection, cseq: cseq, body: Data(), logLabel: "pair-pin-start")
            return
        }

        if requestLine.hasPrefix("POST /pair-setup-pin") {
            let cseq = parseCSeq(from: header)
            print("[RAOPServer] pair-setup-pin: PIN 配对已禁用，返回 200")
            sendBinaryResponse(connection: connection, cseq: cseq, body: Data(), logLabel: "pair-setup-pin")
            return
        }

        if requestLine.hasPrefix("POST /pair-setup") {
            handlePairSetup(header: header, body: body, connection: connection)
            return
        }

        if requestLine.hasPrefix("POST /pair-verify") {
            handlePairVerify(header: header, body: body, connection: connection)
            return
        }

        // fp-setup: FairPlay 加密握手
        if requestLine.hasPrefix("POST /fp-setup") {
            handleFPSetup(header: header, body: body, connection: connection)
            return
        }

        // AirPlay 2 SETUP（binary plist，建立流媒体通道）
        if requestLine.hasPrefix("SETUP") {
            handleAirPlay2Setup(header: header, body: body, connection: connection)
            return
        }

        // GET_PARAMETER / SET_PARAMETER
        if requestLine.hasPrefix("GET_PARAMETER") {
            handleGetParameter(header: header, body: body, connection: connection)
            return
        }
        if requestLine.hasPrefix("SET_PARAMETER") {
            handleSetParameter(header: header, body: body, connection: connection)
            return
        }

        // RECORD（开始推流）
        if requestLine.hasPrefix("RECORD") {
            handleRecord(header: header, body: body, connection: connection)
            return
        }

        // TEARDOWN（结束会话）
        if requestLine.hasPrefix("TEARDOWN") {
            handleTeardown(header: header, body: body, connection: connection)
            return
        }

        // FLUSH（清空缓冲）
        if requestLine.hasPrefix("FLUSH") {
            let cseq = parseCSeq(from: header)
            print("[RAOPServer] FLUSH")
            sendBinaryResponse(connection: connection, cseq: cseq, body: Data(), logLabel: "FLUSH")
            return
        }

        // /feedback（iOS 心跳探测）
        if requestLine.contains("/feedback") {
            let cseq = parseCSeq(from: header)
            sendBinaryResponse(connection: connection, cseq: cseq, body: Data(), logLabel: "feedback")
            return
        }

        // OPTIONS 请求
        if requestLine.hasPrefix("OPTIONS") {
            let cseq = parseCSeq(from: header)
            let response = "RTSP/1.0 200 OK\r\nCSeq: \(cseq)\r\nPublic: ANNOUNCE, SETUP, RECORD, PAUSE, FLUSH, TEARDOWN, OPTIONS, GET_PARAMETER, SET_PARAMETER\r\nServer: AirTunes/220.68\r\n\r\n"
            connection.send(content: response.data(using: .utf8), completion: .contentProcessed { error in
                if let error {
                    print("[RAOPServer] 发送 OPTIONS 响应失败: \(error)")
                }
            })
            return
        }

        // 其他未处理的请求 — 返回 200 OK 避免 iOS 断开
        print("[RAOPServer] 未处理的请求: \(requestLine)")
        let cseq = parseCSeq(from: header)
        sendBinaryResponse(connection: connection, cseq: cseq, body: Data(), logLabel: "Unknown")
    }

    // MARK: - Pair-Setup 处理

    private func handlePairSetup(header: String, body: Data, connection: NWConnection) {
        let cseq = parseCSeq(from: header)

        print("[RAOPServer] Pair-Setup body 大小: \(body.count) bytes")
        print("[RAOPServer] Pair-Setup body hex: \(body.map { String(format: "%02x", $0) }.joined())")

        if body.count == 32 {
            // 32 字节原始公钥格式 - 这是 iOS 的长期公钥
            // iOS 期望我们返回我们的长期公钥 + 签名
            // 这是首次配对流程的一部分
            handlePairSetupRaw(connection: connection, cseq: cseq, iosPublicKey: body)
            return
        }

        // TLV8 格式的 pair-setup
        let tlv = TLV8.decode(body)
        let state = tlv[.state]?.first ?? 0

        print("[RAOPServer] Pair-Setup TLV 状态 M\(state)")

        switch state {
        case TLVState.m1.rawValue:
            handlePairSetupM1(connection: connection, cseq: cseq, tlv: tlv)

        case TLVState.m3.rawValue:
            handlePairSetupM3(connection: connection, cseq: cseq, tlv: tlv)

        case TLVState.m5.rawValue:
            handlePairSetupM5(connection: connection, cseq: cseq, tlv: tlv)

        default:
            print("[RAOPServer] 未知的 pair-setup 状态: \(state)")
            sendTLVError(connection: connection, cseq: cseq, error: .unknown)
        }
    }

    /// 处理 32 字节原始公钥格式的 pair-setup
    private func handlePairSetupRaw(connection: NWConnection, cseq: String, iosPublicKey: Data) {
        print("[RAOPServer] Pair-Setup Raw: 收到 iOS 长期公钥 (\(iosPublicKey.count) bytes)")

        let ourPublicKey = KeyPairManager.shared.publicKey.rawRepresentation
        print("[RAOPServer] Pair-Setup: 返回长期公钥 (\(ourPublicKey.count) bytes)")
        sendBinaryResponse(connection: connection, cseq: cseq, body: ourPublicKey, logLabel: "Pair-Setup")
    }

    /// 处理原始 32 字节公钥格式的请求（pair-verify M1）
    private func handlePairVerifyM1Raw(connection: NWConnection, cseq: String, iosPublicKey: Data) {
        print("[RAOPServer] Pair-Verify M1 Raw: 收到 iOS 公钥 (\(iosPublicKey.count) bytes)")

        // AirPlay 2 pair-verify 流程：
        // M1: iOS 发送其 Curve25519 公钥 (32 bytes)
        // M2: 我们返回我们的 Curve25519 公钥 + Ed25519 签名

        do {
            // 生成临时 ECDH 密钥对
            let ephemeralPrivateKey = Curve25519.KeyAgreement.PrivateKey()
            let ephemeralPublicKey = ephemeralPrivateKey.publicKey.rawRepresentation

            // 计算共享密钥
            let peerPublicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: iosPublicKey)
            let sharedSecret = try ephemeralPrivateKey.sharedSecretFromKeyAgreement(with: peerPublicKey)

            print("[RAOPServer] 计算出共享密钥")

            // 使用长期 Ed25519 密钥签名
            // 签名数据: iosPublicKey || ourEphemeralPublicKey
            var signatureData = iosPublicKey
            signatureData.append(ephemeralPublicKey)

            let longTermKey = KeyPairManager.shared.privateKey
            let signature = try longTermKey.signature(for: signatureData)

            // 返回格式: ourPublicKey (32 bytes) + signature (64 bytes) = 96 bytes
            var responseData = ephemeralPublicKey
            responseData.append(signature)

            print("[RAOPServer] Pair-Verify M2: 返回公钥+签名 (\(responseData.count) bytes): \(ephemeralPublicKey.prefix(8).map { String(format: "%02x", $0) }.joined())... + sig")

            var response = "RTSP/1.0 200 OK\r\n"
            response += "Content-Type: application/octet-stream\r\n"
            response += "Content-Length: \(responseData.count)\r\n"
            response += "Server: AirTunes/220.68\r\n"
            response += "CSeq: \(cseq)\r\n\r\n"

            var fullResponse = response.data(using: .utf8)!
            fullResponse.append(responseData)

            connection.send(content: fullResponse, completion: .contentProcessed { error in
                if let error {
                    print("[RAOPServer] 发送 Pair-Verify M2 响应失败: \(error)")
                } else {
                    print("[RAOPServer] 发送 Pair-Verify M2 响应成功")
                }
            })

        } catch {
            print("[RAOPServer] Pair-Verify M1 密钥交换失败: \(error)")
            sendTLVError(connection: connection, cseq: cseq, error: .authentication)
        }
    }

    private func handlePairSetupM1(connection: NWConnection, cseq: String, tlv: [TLVType: Data]) {
        // 检查方法是否为 pair-setup
        guard let method = tlv[.method], method.first == TLVMethod.pairSetup.rawValue else {
            print("[RAOPServer] Pair-Setup M1: 错误的方法")
            sendTLVError(connection: connection, cseq: cseq, error: .unknown)
            return
        }

        // 生成 ECDH 密钥对用于此次配对
        // AirPlay 2 使用 Curve25519 密钥交换
        let ephemeralKey = Curve25519.KeyAgreement.PrivateKey()
        let ephemeralPublicKey = ephemeralKey.publicKey.rawRepresentation

        // TODO: 存储 ephemeralKey 以便后续步骤使用
        // 当前简化实现不保存，后续需要持久化到连接状态中

        print("[RAOPServer] Pair-Setup M2: 返回公钥 (\(ephemeralPublicKey.count) bytes)")

        // 返回 M2 状态
        let responseData = TLV8.encode([
            (.state, Data([TLVState.m2.rawValue])),
            (.publicKey, ephemeralPublicKey)
        ])

        sendTLVResponse(connection: connection, cseq: cseq, data: responseData)
    }

    private func handlePairSetupM3(connection: NWConnection, cseq: String, tlv: [TLVType: Data]) {
        // iOS 发送其公钥
        guard let iosPublicKey = tlv[.publicKey] else {
            print("[RAOPServer] Pair-Setup M3: 缺少公钥")
            sendTLVError(connection: connection, cseq: cseq, error: .unknown)
            return
        }

        print("[RAOPServer] Pair-Setup M3: 收到 iOS 公钥 (\(iosPublicKey.count) bytes)")

        // 简化实现：直接返回成功
        // 实际应该验证证明并生成共享密钥

        // 返回 M4 状态
        let responseData = TLV8.encode([
            (.state, Data([TLVState.m4.rawValue]))
        ])

        sendTLVResponse(connection: connection, cseq: cseq, data: responseData)
    }

    private func handlePairSetupM5(connection: NWConnection, cseq: String, tlv: [TLVType: Data]) {
        // iOS 发送加密的配对信息（包含设备标识符）
        guard let encryptedData = tlv[.encryptedData] else {
            print("[RAOPServer] Pair-Setup M5: 缺少加密数据")
            sendTLVError(connection: connection, cseq: cseq, error: .authentication)
            return
        }

        print("[RAOPServer] Pair-Setup M5: 收到加密数据 (\(encryptedData.count) bytes)")

        // 解析设备标识符（简化：假设配对成功）
        // 实际需要解密并验证

        // 存储配对信息
        let deviceID = "iOS-\(UUID().uuidString.prefix(8))"
        print("[RAOPServer] Pair-Setup 完成，设备已配对: \(deviceID)")

        // 返回 M6 状态
        let responseData = TLV8.encode([
            (.state, Data([TLVState.m6.rawValue]))
        ])

        sendTLVResponse(connection: connection, cseq: cseq, data: responseData)
    }

    // MARK: - Pair-Verify 处理

    private func handlePairVerify(header: String, body: Data, connection: NWConnection) {
        let cseq = parseCSeq(from: header)

        print("[RAOPServer] Pair-Verify body 大小: \(body.count) bytes")
        print("[RAOPServer] Pair-Verify body hex: \(body.map { String(format: "%02x", $0) }.joined())")

        // AirPlay 2 使用自定义格式，不是标准 TLV8
        // 格式分析：
        // - 如果是 68 字节: 4 bytes header + 32 bytes key + 32 bytes signature
        // - 如果是 TLV8 格式，则按 TLV 解码

        if body.count == 68 {
            // AirPlay 2 pair-verify M3 格式
            // 4 bytes: 通常是 01000000
            // 32 bytes: iOS 公钥
            // 32 bytes: iOS 签名
            handlePairVerifyM3Custom(connection: connection, cseq: cseq, body: body)
            return
        }

        // 尝试 TLV8 解码
        let tlv = TLV8.decode(body)
        print("[RAOPServer] Pair-Verify TLV 解码结果: \(tlv.map { (type, data) in "\(type.rawValue):\(data.count)B" }.joined(separator: ", "))")

        let state = tlv[.state]?.first ?? 0
        print("[RAOPServer] Pair-Verify 状态 M\(state)")

        switch state {
        case TLVState.m1.rawValue:
            handlePairVerifyM1(connection: connection, cseq: cseq, tlv: tlv)

        case TLVState.m3.rawValue:
            handlePairVerifyM3(connection: connection, cseq: cseq, tlv: tlv)

        default:
            print("[RAOPServer] 未知的 pair-verify 状态: \(state)")
            // 尝试作为原始数据处理
            if let iosPublicKey = tlv[.publicKey] {
                handlePairVerifyM1Raw(connection: connection, cseq: cseq, iosPublicKey: iosPublicKey)
            } else {
                sendTLVError(connection: connection, cseq: cseq, error: .unknown)
            }
        }
    }

    /// 处理 AirPlay 2 自定义格式的 pair-verify（68字节）
    /// 这是 M1 请求，包含 iOS 的签名验证数据
    /// 我们需要返回 M2 响应（我们的公钥 + 签名）
    private func handlePairVerifyM3Custom(connection: NWConnection, cseq: String, body: Data) {
        let flag = body.first ?? 0xFF

        if flag == 0x01 {
            print("[RAOPServer] Pair-Verify 68 bytes 格式 (M1)")

            let iosEphemeralPublicKey = Data(body[4..<36])
            let iosLongTermPublicKey = Data(body[36..<68])

            print("[RAOPServer] iOS 临时公钥: \(iosEphemeralPublicKey.map { String(format: "%02x", $0) }.joined())")
            print("[RAOPServer] iOS 长期公钥: \(iosLongTermPublicKey.map { String(format: "%02x", $0) }.joined())")

            do {
                let ephemeralPrivateKey = Curve25519.KeyAgreement.PrivateKey()
                let ephemeralPublicKey = ephemeralPrivateKey.publicKey.rawRepresentation
                let peerPublicKey = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: iosEphemeralPublicKey)
                let sharedSecret = try ephemeralPrivateKey.sharedSecretFromKeyAgreement(with: peerPublicKey)
                let sharedSecretData = sharedSecret.withUnsafeBytes { Data($0) }

                let state = state(for: connection)
                state.reset()
                state.verifyState = .m2
                state.sharedSecret = sharedSecretData
                state.ourEphemeralPrivateKey = ephemeralPrivateKey
                state.ourEphemeralPublicKey = ephemeralPublicKey
                state.peerEphemeralPublicKey = iosEphemeralPublicKey
                state.peerLongTermPublicKey = iosLongTermPublicKey

                print("[RAOPServer] 计算出共享密钥: \(sharedSecretData.prefix(8).map { String(format: "%02x", $0) }.joined())...")

                var signaturePayload = Data()
                signaturePayload.append(ephemeralPublicKey)
                signaturePayload.append(iosEphemeralPublicKey)
                let signature = try KeyPairManager.shared.privateKey.signature(for: signaturePayload)
                let encryptedSignature = try aesCTRTransform(data: signature, sharedSecret: sharedSecretData)

                var responseData = ephemeralPublicKey
                responseData.append(encryptedSignature)

                print("[RAOPServer] Pair-Verify M2: 返回公钥+加密签名 (\(responseData.count) bytes)")
                sendBinaryResponse(connection: connection, cseq: cseq, body: responseData, logLabel: "Pair-Verify M2")
            } catch {
                print("[RAOPServer] Pair-Verify M1 失败: \(error)")
                sendTLVError(connection: connection, cseq: cseq, error: .authentication)
            }
            return
        }

        if flag == 0x00 {
            print("[RAOPServer] Pair-Verify 68 bytes 格式 (M3)")
            let encryptedSignature = Data(body[4..<68])
            let state = state(for: connection)

            guard let sharedSecret = state.sharedSecret,
                  let peerLongTermPublicKey = state.peerLongTermPublicKey,
                  let ourEphemeralPublicKey = state.ourEphemeralPublicKey,
                  let peerEphemeralPublicKey = state.peerEphemeralPublicKey else {
                print("[RAOPServer] Pair-Verify M3 缺少会话状态")
                sendTLVError(connection: connection, cseq: cseq, error: .authentication)
                return
            }

            do {
                let publicKey = try Curve25519.Signing.PublicKey(rawRepresentation: peerLongTermPublicKey)

                var verifyPayloadServerClient = Data()
                verifyPayloadServerClient.append(ourEphemeralPublicKey)
                verifyPayloadServerClient.append(peerEphemeralPublicKey)

                var verifyPayloadClientServer = Data()
                verifyPayloadClientServer.append(peerEphemeralPublicKey)
                verifyPayloadClientServer.append(ourEphemeralPublicKey)

                var matched = false

                // M2 加密消耗了 64 字节（4 个 AES block）的 CTR 密钥流，
                // M3 的密文是从 counter=4 开始加密的，因此解密时需要
                // 先跳过前 64 字节的密钥流，再解密实际数据。
                let ctrPadding = Data(count: 64)

                let fullOutputBE = try aesCTRTransform(data: ctrPadding + encryptedSignature, sharedSecret: sharedSecret, ctrBigEndian: true)
                let decryptedBE = Data(fullOutputBE.suffix(64))
                if publicKey.isValidSignature(decryptedBE, for: verifyPayloadServerClient) {
                    print("[RAOPServer] Pair-Verify M3 签名校验通过 (CTR=BE, 顺序: server+client)")
                    matched = true
                } else if publicKey.isValidSignature(decryptedBE, for: verifyPayloadClientServer) {
                    print("[RAOPServer] Pair-Verify M3 签名校验通过 (CTR=BE, 顺序: client+server)")
                    matched = true
                }

                if !matched {
                    let fullOutputLE = try aesCTRTransform(data: ctrPadding + encryptedSignature, sharedSecret: sharedSecret, ctrBigEndian: false)
                    let decryptedLE = Data(fullOutputLE.suffix(64))
                    if publicKey.isValidSignature(decryptedLE, for: verifyPayloadServerClient) {
                        print("[RAOPServer] Pair-Verify M3 签名校验通过 (CTR=LE, 顺序: server+client)")
                        matched = true
                    } else if publicKey.isValidSignature(decryptedLE, for: verifyPayloadClientServer) {
                        print("[RAOPServer] Pair-Verify M3 签名校验通过 (CTR=LE, 顺序: client+server)")
                        matched = true
                    }
                }

                guard matched else {
                    print("[RAOPServer] Pair-Verify M3 签名校验失败")
                    sendTLVError(connection: connection, cseq: cseq, error: .authentication)
                    return
                }

                print("[RAOPServer] Pair-Verify 完成，客户端签名校验通过")
                sendBinaryResponse(connection: connection, cseq: cseq, body: Data(), logLabel: "Pair-Verify M4")
            } catch {
                print("[RAOPServer] Pair-Verify M3 解密/校验失败: \(error)")
                sendTLVError(connection: connection, cseq: cseq, error: .authentication)
            }
            return
        }

        print("[RAOPServer] 未知的 Pair-Verify 标志: \(flag)")
        sendTLVError(connection: connection, cseq: cseq, error: .unknown)
    }

    private func handlePairVerifyM1(connection: NWConnection, cseq: String, tlv: [TLVType: Data]) {
        // iOS 发送其公钥，请求验证
        guard let iosPublicKey = tlv[.publicKey] else {
            print("[RAOPServer] Pair-Verify M1: 缺少公钥")
            sendTLVError(connection: connection, cseq: cseq, error: .unknown)
            return
        }

        print("[RAOPServer] Pair-Verify M1: 收到 iOS 公钥 (\(iosPublicKey.count) bytes)")

        do {
            // 生成临时密钥对
            let ephemeralKey = Curve25519.KeyAgreement.PrivateKey()
            let ephemeralPublicKey = ephemeralKey.publicKey.rawRepresentation

            // 使用长期密钥签名
            let longTermKey = KeyPairManager.shared.privateKey

            // 构造签名数据: iOS_public || our_ephemeral_public
            var signatureData = iosPublicKey
            signatureData.append(ephemeralPublicKey)

            let signature = try longTermKey.signature(for: signatureData)

            // 返回 M2：我们的公钥 + 签名 + 证书（这里用我们的公钥作为标识符）
            let identifier = KeyPairManager.shared.deviceID

            let responseData = TLV8.encode([
                (.state, Data([TLVState.m2.rawValue])),
                (.publicKey, ephemeralPublicKey),
                (.signature, signature),
                (.identifier, identifier.data(using: .utf8)!)
            ])

            sendTLVResponse(connection: connection, cseq: cseq, data: responseData)

        } catch {
            print("[RAOPServer] Pair-Verify M1 失败: \(error)")
            sendTLVError(connection: connection, cseq: cseq, error: .unknown)
        }
    }

    private func handlePairVerifyM3(connection: NWConnection, cseq: String, tlv: [TLVType: Data]) {
        // iOS 发送签名验证
        guard let signature = tlv[.signature], let identifier = tlv[.identifier] else {
            print("[RAOPServer] Pair-Verify M3: 缺少签名或标识符")
            sendTLVError(connection: connection, cseq: cseq, error: .authentication)
            return
        }

        let deviceID = String(data: identifier, encoding: .utf8) ?? "unknown"
        print("[RAOPServer] Pair-Verify M3: 收到签名 (\(signature.count) bytes) 来自 \(deviceID)")

        // 验证签名（简化：假设验证成功）
        // 实际需要使用存储的设备公钥验证

        print("[RAOPServer] Pair-Verify 完成")

        // 返回 M4：验证成功
        let responseData = TLV8.encode([
            (.state, Data([TLVState.m4.rawValue]))
        ])

        sendTLVResponse(connection: connection, cseq: cseq, data: responseData)
    }

    // MARK: - 辅助方法

    private func sendTLVResponse(connection: NWConnection, cseq: String, data: Data) {
        sendBinaryResponse(connection: connection, cseq: cseq, body: data, logLabel: "TLV")
    }

    private func sendTLVError(connection: NWConnection, cseq: String, error: TLVError) {
        let responseData = TLV8.encode([
            (.state, Data([TLVState.m2.rawValue])),
            (.error, Data([error.rawValue]))
        ])

        sendTLVResponse(connection: connection, cseq: cseq, data: responseData)
    }

    // MARK: - FairPlay Setup

    // FairPlay v3 Phase 1 预计算响应（每种 mode 142 字节，来源: RPiPlay/shairplay）
    private static let fpReplyMode0: [UInt8] = [
        0x46,0x50,0x4c,0x59,0x03,0x01,0x02,0x00,0x00,0x00,0x00,0x82,
        0x02,0x00,0x0f,0x9f,0x3f,0x9e,0x0a,0x25,0x21,0xdb,0xdf,0x31,
        0x2a,0xb2,0xbf,0xb2,0x9e,0x8d,0x23,0x2b,0x63,0x76,0xa8,0xc8,
        0x18,0x70,0x1d,0x22,0xae,0x93,0xd8,0x27,0x37,0xfe,0xaf,0x9d,
        0xb4,0xfd,0xf4,0x1c,0x2d,0xba,0x9d,0x1f,0x49,0xca,0xaa,0xbf,
        0x65,0x91,0xac,0x1f,0x7b,0xc6,0xf7,0xe0,0x66,0x3d,0x21,0xaf,
        0xe0,0x15,0x65,0x95,0x3e,0xab,0x81,0xf4,0x18,0xce,0xed,0x09,
        0x5a,0xdb,0x7c,0x3d,0x0e,0x25,0x49,0x09,0xa7,0x98,0x31,0xd4,
        0x9c,0x39,0x82,0x97,0x34,0x34,0xfa,0xcb,0x42,0xc6,0x3a,0x1c,
        0xd9,0x11,0xa6,0xfe,0x94,0x1a,0x8a,0x6d,0x4a,0x74,0x3b,0x46,
        0xc3,0xa7,0x64,0x9e,0x44,0xc7,0x89,0x55,0xe4,0x9d,0x81,0x55,
        0x00,0x95,0x49,0xc4,0xe2,0xf7,0xa3,0xf6,0xd5,0xba
    ]
    private static let fpReplyMode1: [UInt8] = [
        0x46,0x50,0x4c,0x59,0x03,0x01,0x02,0x00,0x00,0x00,0x00,0x82,
        0x02,0x01,0xcf,0x32,0xa2,0x57,0x14,0xb2,0x52,0x4f,0x8a,0xa0,
        0xad,0x7a,0xf1,0x64,0xe3,0x7b,0xcf,0x44,0x24,0xe2,0x00,0x04,
        0x7e,0xfc,0x0a,0xd6,0x7a,0xfc,0xd9,0x5d,0xed,0x1c,0x27,0x30,
        0xbb,0x59,0x1b,0x96,0x2e,0xd6,0x3a,0x9c,0x4d,0xed,0x88,0xba,
        0x8f,0xc7,0x8d,0xe6,0x4d,0x91,0xcc,0xfd,0x5c,0x7b,0x56,0xda,
        0x88,0xe3,0x1f,0x5c,0xce,0xaf,0xc7,0x43,0x19,0x95,0xa0,0x16,
        0x65,0xa5,0x4e,0x19,0x39,0xd2,0x5b,0x94,0xdb,0x64,0xb9,0xe4,
        0x5d,0x8d,0x06,0x3e,0x1e,0x6a,0xf0,0x7e,0x96,0x56,0x16,0x2b,
        0x0e,0xfa,0x40,0x42,0x75,0xea,0x5a,0x44,0xd9,0x59,0x1c,0x72,
        0x56,0xb9,0xfb,0xe6,0x51,0x38,0x98,0xb8,0x02,0x27,0x72,0x19,
        0x88,0x57,0x16,0x50,0x94,0x2a,0xd9,0x46,0x68,0x8a
    ]
    private static let fpReplyMode2: [UInt8] = [
        0x46,0x50,0x4c,0x59,0x03,0x01,0x02,0x00,0x00,0x00,0x00,0x82,
        0x02,0x02,0xc1,0x69,0xa3,0x52,0xee,0xed,0x35,0xb1,0x8c,0xdd,
        0x9c,0x58,0xd6,0x4f,0x16,0xc1,0x51,0x9a,0x89,0xeb,0x53,0x17,
        0xbd,0x0d,0x43,0x36,0xcd,0x68,0xf6,0x38,0xff,0x9d,0x01,0x6a,
        0x5b,0x52,0xb7,0xfa,0x92,0x16,0xb2,0xb6,0x54,0x82,0xc7,0x84,
        0x44,0x11,0x81,0x21,0xa2,0xc7,0xfe,0xd8,0x3d,0xb7,0x11,0x9e,
        0x91,0x82,0xaa,0xd7,0xd1,0x8c,0x70,0x63,0xe2,0xa4,0x57,0x55,
        0x59,0x10,0xaf,0x9e,0x0e,0xfc,0x76,0x34,0x7d,0x16,0x40,0x43,
        0x80,0x7f,0x58,0x1e,0xe4,0xfb,0xe4,0x2c,0xa9,0xde,0xdc,0x1b,
        0x5e,0xb2,0xa3,0xaa,0x3d,0x2e,0xcd,0x59,0xe7,0xee,0xe7,0x0b,
        0x36,0x29,0xf2,0x2a,0xfd,0x16,0x1d,0x87,0x73,0x53,0xdd,0xb9,
        0x9a,0xdc,0x8e,0x07,0x00,0x6e,0x56,0xf8,0x50,0xce
    ]
    private static let fpReplyMode3: [UInt8] = [
        0x46,0x50,0x4c,0x59,0x03,0x01,0x02,0x00,0x00,0x00,0x00,0x82,
        0x02,0x03,0x90,0x01,0xe1,0x72,0x7e,0x0f,0x57,0xf9,0xf5,0x88,
        0x0d,0xb1,0x04,0xa6,0x25,0x7a,0x23,0xf5,0xcf,0xff,0x1a,0xbb,
        0xe1,0xe9,0x30,0x45,0x25,0x1a,0xfb,0x97,0xeb,0x9f,0xc0,0x01,
        0x1e,0xbe,0x0f,0x3a,0x81,0xdf,0x5b,0x69,0x1d,0x76,0xac,0xb2,
        0xf7,0xa5,0xc7,0x08,0xe3,0xd3,0x28,0xf5,0x6b,0xb3,0x9d,0xbd,
        0xe5,0xf2,0x9c,0x8a,0x17,0xf4,0x81,0x48,0x7e,0x3a,0xe8,0x63,
        0xc6,0x78,0x32,0x54,0x22,0xe6,0xf7,0x8e,0x16,0x6d,0x18,0xaa,
        0x7f,0xd6,0x36,0x25,0x8b,0xce,0x28,0x72,0x6f,0x66,0x1f,0x73,
        0x88,0x93,0xce,0x44,0x31,0x1e,0x4b,0xe6,0xc0,0x53,0x51,0x93,
        0xe5,0xef,0x72,0xe8,0x68,0x62,0x33,0x72,0x9c,0x22,0x7d,0x82,
        0x0c,0x99,0x94,0x45,0xd8,0x92,0x46,0xc8,0xc3,0x59
    ]
    private static let fpReplyMessages: [[UInt8]] = [fpReplyMode0, fpReplyMode1, fpReplyMode2, fpReplyMode3]

    // FairPlay v3 Phase 2 响应头（12 字节）
    private static let fpPhase2Header: [UInt8] = [
        0x46, 0x50, 0x4c, 0x59, 0x03, 0x01, 0x04, 0x00, 0x00, 0x00, 0x00, 0x14
    ]

    private func handleFPSetup(header: String, body: Data, connection: NWConnection) {
        let cseq = parseCSeq(from: header)
        print("[RAOPServer] FP-Setup: 收到请求 body=\(body.count) bytes")
        print("[RAOPServer] FP-Setup body hex: \(body.prefix(32).map { String(format: "%02x", $0) }.joined())")

        // 校验 FPLY 魔数和版本
        guard body.count >= 16,
              body[0] == 0x46, body[1] == 0x50, body[2] == 0x4c, body[3] == 0x59,
              body[4] == 0x03 else {
            print("[RAOPServer] FP-Setup: 无效的 FPLY 请求")
            sendBinaryResponse(connection: connection, cseq: cseq, body: Data(), logLabel: "FP-Setup")
            return
        }

        let phase = body[6]

        switch phase {
        case 0x01:
            // Phase 1: 根据 mode 返回预计算的 142 字节响应
            let mode = Int(body[14])
            guard mode >= 0, mode < Self.fpReplyMessages.count else {
                print("[RAOPServer] FP-Setup Phase 1: 无效 mode=\(mode)")
                sendBinaryResponse(connection: connection, cseq: cseq, body: Data(), logLabel: "FP-Setup Phase1")
                return
            }
            let responseData = Data(Self.fpReplyMessages[mode])
            print("[RAOPServer] FP-Setup Phase 1: mode=\(mode), 返回 \(responseData.count) bytes")
            sendBinaryResponse(connection: connection, cseq: cseq, body: responseData, logLabel: "FP-Setup Phase1")

        case 0x03:
            // Phase 2: 存储 key message，返回 header(12) + req[144:20] = 32 字节
            guard body.count >= 164 else {
                print("[RAOPServer] FP-Setup Phase 2: 数据不足 (\(body.count) bytes)")
                sendBinaryResponse(connection: connection, cseq: cseq, body: Data(), logLabel: "FP-Setup Phase2")
                return
            }

            // 存储 key message 供后续 FairPlay 解密使用
            let pairingState = state(for: connection)
            pairingState.fairPlayKeyMessage = Data(body)

            var responseData = Data(Self.fpPhase2Header)
            responseData.append(body[144..<164])
            print("[RAOPServer] FP-Setup Phase 2: 返回 \(responseData.count) bytes")
            sendBinaryResponse(connection: connection, cseq: cseq, body: responseData, logLabel: "FP-Setup Phase2")

        default:
            print("[RAOPServer] FP-Setup: 未知 phase=\(phase)")
            sendBinaryResponse(connection: connection, cseq: cseq, body: Data(), logLabel: "FP-Setup")
        }
    }

    // MARK: - AirPlay 2 SETUP

    private func handleAirPlay2Setup(header: String, body: Data, connection: NWConnection) {
        let cseq = parseCSeq(from: header)

        // 解析 binary plist
        guard let plist = try? PropertyListSerialization.propertyList(from: body, format: nil) as? [String: Any] else {
            print("[RAOPServer] SETUP: 无法解析 binary plist (body=\(body.count) bytes)")
            sendBinaryResponse(connection: connection, cseq: cseq, body: Data(), logLabel: "SETUP")
            return
        }

        print("[RAOPServer] SETUP plist keys: \(plist.keys.sorted())")

        // ── 1. 启动 event + timing 监听（只启动一次）──
        if !isEventListenerActive {
            startEventListener(port: eventPort)
            startTimingListener(port: timingPort)
            isEventListenerActive = true
        }

        // ── 2. 区分会话级 SETUP 和流级 SETUP ──
        if let streams = plist["streams"] as? [[String: Any]] {
            // ===== 流级 SETUP =====
            var responseStreams: [[String: Any]] = []

            for (index, stream) in streams.enumerated() {
                let type = (stream["type"] as? NSNumber)?.intValue ?? 0
                let streamConnID = (stream["streamConnectionID"] as? NSNumber)?.int64Value ?? 0
                print("[RAOPServer] SETUP stream[\(index)]: type=\(type) connectionID=\(streamConnID) keys=\(stream.keys.sorted())")

                switch type {
                case 110:
                    // 屏幕镜像（TCP）
                    if !isMirrorListenerActive {
                        startMirrorDataListener(port: mirrorDataPort)
                        isMirrorListenerActive = true
                    }
                    if streamConnID != 0 {
                        mirrorStreamConnectionID = UInt64(bitPattern: streamConnID)
                        configureMirrorDecryptionIfPossible(for: connection)
                    }
                    var mirrorResponse: [String: Any] = [
                        "type": NSNumber(value: 110),
                        "streamID": NSNumber(value: 1),
                        "dataPort": NSNumber(value: mirrorDataPort),
                    ]
                    if streamConnID != 0 {
                        mirrorResponse["streamConnectionID"] = NSNumber(value: streamConnID)
                    }
                    responseStreams.append(mirrorResponse)

                case 96:
                    // 实时音频（UDP）
                    let sr = (stream["sr"] as? NSNumber)?.intValue ?? 44100
                    let sc = (stream["sc"] as? NSNumber)?.intValue ?? 2
                    let ct = (stream["ct"] as? NSNumber)?.intValue ?? 2  // 1=AAC-LC, 2=AAC-ELD, 4=ALAC, 8=PCM
                    let spf = (stream["spf"] as? NSNumber)?.intValue ?? 0
                    let af = (stream["audioFormat"] as? NSNumber)?.intValue ?? 0
                    audioFormat = (sampleRate: sr, channels: sc, codecType: ct, spf: spf)
                    print("[RAOPServer] Audio SETUP: sr=\(sr) ch=\(sc) ct=\(ct) spf=\(spf) audioFormat=0x\(String(af, radix: 16)) keys=\(stream.keys.sorted())")

                    if !isAudioListenerActive {
                        startAudioDataListener(port: audioDataPort)
                        startAudioControlListener(port: audioControlPort)
                        isAudioListenerActive = true
                    }
                    responseStreams.append([
                        "type": NSNumber(value: 96),
                        "streamID": NSNumber(value: 2),
                        "dataPort": NSNumber(value: audioDataPort),
                        "controlPort": NSNumber(value: audioControlPort),
                        "audioBufferSize": NSNumber(value: 8388608),
                    ])

                default:
                    print("[RAOPServer] SETUP: 未知 stream type=\(type)")
                    responseStreams.append([
                        "type": NSNumber(value: type),
                        "streamID": NSNumber(value: index + 1),
                        "dataPort": NSNumber(value: mirrorDataPort + UInt16(index) * 2 + 4),
                    ])
                }
            }

            let responsePlist: [String: Any] = [
                "streams": responseStreams,
                "eventPort": NSNumber(value: eventPort),
                "timingPort": NSNumber(value: timingPort),
            ]
            sendSetupPlistResponse(connection: connection, cseq: cseq, plist: responsePlist,
                                   label: "SETUP(streams=\(responseStreams.count))")

        } else {
            // ===== 会话级 SETUP（无 streams，包含 ekey/eiv/et 等）=====
            if let ekey = plist["ekey"] as? Data, ekey.count == 72 {
                // 通过 FairPlay (PlayFair) 解密 ekey 得到真正的 16 字节 AES 密钥
                let pairingState = state(for: connection)
                if let keyMsg = pairingState.fairPlayKeyMessage, keyMsg.count == 164 {
                    var decryptedKey = Data(count: 16)
                    var keyMsgBytes = [UInt8](keyMsg)
                    var ekeyBytes = [UInt8](ekey)
                    decryptedKey.withUnsafeMutableBytes { outPtr in
                        playfair_decrypt(&keyMsgBytes, &ekeyBytes, outPtr.bindMemory(to: UInt8.self).baseAddress)
                    }
                    streamEncryptionKey = decryptedKey
                    let hexKey = decryptedKey.map { String(format: "%02x", $0) }.joined()
                    print("[RAOPServer] SETUP 会话: FairPlay 解密 ekey 成功, AES key=\(hexKey)")
                } else {
                    print("[RAOPServer] SETUP 会话: 无 FairPlay keyMessage，无法解密 ekey")
                    streamEncryptionKey = ekey
                }
            }
            if let eiv = plist["eiv"] as? Data {
                streamEncryptionIV = eiv
                print("[RAOPServer] SETUP 会话: 保存 eiv (\(eiv.count) bytes)")
            }
            configureMirrorDecryptionIfPossible(for: connection)
            let et = (plist["et"] as? NSNumber)?.intValue ?? 0
            streamEncryptionType = et
            let timingProto = plist["timingProtocol"] as? String ?? "unknown"
            let iOSTimingPort = (plist["timingPort"] as? NSNumber)?.uint16Value ?? 0
            print("[RAOPServer] SETUP 会话: et=\(et) timingProtocol=\(timingProto) iOSTimingPort=\(iOSTimingPort)")

            let responsePlist: [String: Any] = [
                "eventPort": NSNumber(value: eventPort),
                "timingPort": NSNumber(value: timingPort),
            ]
            sendSetupPlistResponse(connection: connection, cseq: cseq, plist: responsePlist,
                                   label: "SETUP(session)")
        }
    }

    /// 序列化 plist 并发送 SETUP 响应
    private func sendSetupPlistResponse(connection: NWConnection, cseq: String, plist: [String: Any], label: String) {
        do {
            let responseData = try PropertyListSerialization.data(fromPropertyList: plist, format: .binary, options: 0)
            let responseHeader = makeResponseHeader(connection: connection, cseq: cseq,
                contentType: "application/x-apple-binary-plist", contentLength: responseData.count)
            var fullResponse = responseHeader.data(using: .utf8)!
            fullResponse.append(responseData)

            connection.send(content: fullResponse, completion: .contentProcessed { error in
                if let error {
                    print("[RAOPServer] 发送 \(label) 响应失败: \(error)")
                } else {
                    print("[RAOPServer] 发送 \(label) 响应成功 (body=\(responseData.count) bytes)")
                }
            })
        } catch {
            print("[RAOPServer] \(label): 序列化响应失败: \(error)")
        }
    }

    private func handleGetParameter(header: String, body: Data, connection: NWConnection) {
        let cseq = parseCSeq(from: header)
        let bodyStr = String(data: body, encoding: .utf8) ?? ""
        print("[RAOPServer] GET_PARAMETER: \(bodyStr.trimmingCharacters(in: .whitespacesAndNewlines))")

        // 常见查询: volume
        if bodyStr.contains("volume") {
            let response = "volume: 0.0\r\n"
            let respData = response.data(using: .utf8) ?? Data()
            let respHeader = makeResponseHeader(connection: connection, cseq: cseq,
                contentType: "text/parameters", contentLength: respData.count)
            var full = respHeader.data(using: .utf8)!
            full.append(respData)
            connection.send(content: full, completion: .contentProcessed { _ in })
        } else {
            sendBinaryResponse(connection: connection, cseq: cseq, body: Data(), logLabel: "GET_PARAMETER")
        }
    }

    private func handleSetParameter(header: String, body: Data, connection: NWConnection) {
        let cseq = parseCSeq(from: header)
        print("[RAOPServer] SET_PARAMETER (body=\(body.count) bytes)")
        sendBinaryResponse(connection: connection, cseq: cseq, body: Data(), logLabel: "SET_PARAMETER")
    }

    private func handleRecord(header: String, body: Data, connection: NWConnection) {
        let cseq = parseCSeq(from: header)
        print("[RAOPServer] RECORD — 开始接收镜像数据")

        let responseHeader = makeResponseHeader(connection: connection, cseq: cseq,
            contentType: "application/octet-stream", contentLength: 0)
        connection.send(content: responseHeader.data(using: .utf8), completion: .contentProcessed { error in
            if let error {
                print("[RAOPServer] 发送 RECORD 响应失败: \(error)")
            } else {
                print("[RAOPServer] 发送 RECORD 响应成功")
            }
        })

        onMirrorStreamReady?(mirrorDataPort)
    }

    private func handleTeardown(header: String, body: Data, connection: NWConnection) {
        let cseq = parseCSeq(from: header)

        // 解析 body plist，判断是流级别还是会话级别 TEARDOWN
        var plist: [String: Any]?
        if !body.isEmpty {
            plist = try? PropertyListSerialization.propertyList(from: body, format: nil) as? [String: Any]
        }

        if let streams = plist?["streams"] as? [[String: Any]] {
            // 流级别 TEARDOWN：只停止指定流
            let types = streams.compactMap { ($0["type"] as? NSNumber)?.intValue }
            print("[RAOPServer] TEARDOWN 流级别: types=\(types)")

            for streamType in types {
                switch streamType {
                case 96:
                    // 停止音频流
                    audioDataListener?.cancel()
                    audioDataListener = nil
                    audioControlListener?.cancel()
                    audioControlListener = nil
                    audioConnections.forEach { $0.cancel() }
                    audioConnections.removeAll()
                    isAudioListenerActive = false
                    audioPacketCount = 0
                    print("[RAOPServer] 音频流已停止")
                case 110:
                    // 停止镜像流
                    print("[RAOPServer] TEARDOWN 镜像流")
                    stopStreamListeners()
                    onStreamTeardown?()
                default:
                    print("[RAOPServer] TEARDOWN 未知流类型: \(streamType)")
                }
            }

            sendBinaryResponse(connection: connection, cseq: cseq, body: Data(), logLabel: "TEARDOWN")
        } else {
            // 会话级别 TEARDOWN：停止所有
            print("[RAOPServer] TEARDOWN 会话级别 — 停止所有流")
            sendBinaryResponse(connection: connection, cseq: cseq, body: Data(), logLabel: "TEARDOWN")
            stopStreamListeners()
            onStreamTeardown?()
        }
    }

    // MARK: - Mirror Data / Event 监听器

    private func startMirrorDataListener(port: UInt16) {
        mirrorDataListener?.cancel()

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true

        do {
            let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    print("[RAOPServer] Mirror 数据监听就绪，端口 \(port)")
                case .failed(let error):
                    print("[RAOPServer] Mirror 数据监听失败: \(error)")
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] conn in
                guard let self else { return }
                print("[RAOPServer] Mirror 数据连接: \(conn.endpoint)")
                self.mirrorConnections.append(conn)
                self.mirrorReceiveBuffers[ObjectIdentifier(conn)] = Data()
                conn.start(queue: self.queue)
                self.receiveMirrorData(from: conn)
            }
            listener.start(queue: queue)
            mirrorDataListener = listener
        } catch {
            print("[RAOPServer] Mirror 数据监听器创建失败: \(error)")
        }
    }

    private func startEventListener(port: UInt16) {
        eventListener?.cancel()

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true

        do {
            let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    print("[RAOPServer] Event 监听就绪，端口 \(port)")
                case .failed(let error):
                    print("[RAOPServer] Event 监听失败: \(error)")
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] conn in
                guard let self else { return }
                print("[RAOPServer] Event 连接: \(conn.endpoint)")
                self.eventConnections.append(conn)
                conn.start(queue: self.queue)
                self.receiveEventData(from: conn)
            }
            listener.start(queue: queue)
            eventListener = listener
        } catch {
            print("[RAOPServer] Event 监听器创建失败: \(error)")
        }
    }

    private func receiveMirrorData(from connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 131072) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let data, !data.isEmpty {
                let hex = data.prefix(32).map { String(format: "%02x", $0) }.joined(separator: " ")
                print("[RAOPServer] Mirror 原始数据: \(data.count) bytes, hex: \(hex)")

                let connID = ObjectIdentifier(connection)
                self.mirrorQueue.async {
                    var buf = self.mirrorReceiveBuffers[connID] ?? Data()
                    buf.append(data)
                    self.mirrorReceiveBuffers[connID] = buf
                    self.processMirrorBuffer(connID: connID)
                }
            }

            if let error {
                print("[RAOPServer] Mirror 数据接收错误: \(error)")
                return
            }

            if isComplete {
                print("[RAOPServer] Mirror 数据连接关闭")
                return
            }

            self.receiveMirrorData(from: connection)
        }
    }

    private var mirrorFrameCount = 0

    private func processMirrorBuffer(connID: ObjectIdentifier) {
        guard var buf = mirrorReceiveBuffers[connID] else { return }

        // AirPlay 2 镜像帧格式:
        // [0-3]  payloadSize: UInt32 (little-endian)
        // [4]    payloadType: UInt8  0=video(P/IDR, flags=0x10 for IDR), 1=codec config, 5=statistics plist
        // [5]    flags (e.g. 0x10=IDR keyframe)
        // [6-7]  reserved/flags
        // [8-15] NTP timestamp
        // ...
        // 头部共 128 字节，随后是 payloadSize 字节的视频数据
        while buf.count >= 128 {
            let payloadSize = UInt32(buf[0]) | UInt32(buf[1]) << 8 | UInt32(buf[2]) << 16 | UInt32(buf[3]) << 24
            let payloadType = buf[4]
            let flags = buf[5]
            let frameSize = 128 + Int(payloadSize)

            // 防止畸形帧导致无限循环
            guard payloadSize > 0, payloadSize < 10_000_000 else {
                print("[RAOPServer] Mirror 帧异常: payloadSize=\(payloadSize)，丢弃 buffer")
                buf = Data()
                break
            }

            guard buf.count >= frameSize else { break }

            let header = Data(buf[0..<128])
            var payload = Data(buf[128..<frameSize])

            mirrorFrameCount += 1

            // 前 5 帧打印详细头部信息，帮助诊断
            if mirrorFrameCount <= 5 {
                let headerHex = header.prefix(32).map { String(format: "%02x", $0) }.joined(separator: " ")
                let payloadHex = payload.prefix(32).map { String(format: "%02x", $0) }.joined(separator: " ")
                print("[RAOPServer] Mirror 帧 #\(mirrorFrameCount): type=\(payloadType) flags=0x\(String(format: "%02x", flags)) size=\(payloadSize)")
                print("[RAOPServer]   header[0:32]: \(headerHex)")
                print("[RAOPServer]   payload[0:32]: \(payloadHex)")
                print("[RAOPServer]   et=\(streamEncryptionType) ekey=\(streamEncryptionKey?.count ?? 0)B eiv=\(streamEncryptionIV?.count ?? 0)B")
            } else if mirrorFrameCount % 30 == 0 {
                print("[RAOPServer] Mirror 帧 #\(mirrorFrameCount): type=\(payloadType) flags=0x\(String(format: "%02x", flags)) size=\(payloadSize)")
            }

            if streamEncryptionType > 0, !payload.isEmpty, payloadType == 0 {
                payload = decryptMirrorPayload(payload)
            }

            onMirrorData?(header, payload)

            buf = Data(buf[frameSize...])
        }

        mirrorReceiveBuffers[connID] = buf
    }

    /// AES-128-CTR 解密镜像帧 payload
    /// 关键：AirPlay mirror 流使用连续的 CTR counter，所有帧共用同一个 cryptor，
    /// counter 随每次 CCCryptorUpdate 自动递增，不能每帧重置。
    private func decryptMirrorPayload(_ encrypted: Data) -> Data {
        guard let cryptor = mirrorCryptor else {
            print("[RAOPServer] Mirror 解密: cryptor 未初始化")
            return encrypted
        }

        let outputCapacity = encrypted.count + kCCBlockSizeAES128
        var output = Data(count: outputCapacity)
        var outMoved = 0
        let updateStatus = output.withUnsafeMutableBytes { outBytes in
            encrypted.withUnsafeBytes { inBytes in
                CCCryptorUpdate(cryptor, inBytes.baseAddress, encrypted.count,
                                outBytes.baseAddress, outputCapacity, &outMoved)
            }
        }

        guard updateStatus == kCCSuccess else {
            print("[RAOPServer] Mirror 解密: CCCryptorUpdate 失败 status=\(updateStatus)")
            return encrypted
        }

        output.removeSubrange(outMoved..<output.count)

        // 诊断：前 10 帧打印解密后前 16 字节
        if mirrorFrameCount <= 10 {
            let hex = output.prefix(16).map { String(format: "%02x", $0) }.joined(separator: " ")
            print("[RAOPServer] Mirror 解密后 #\(mirrorFrameCount): prefix=\(hex) size=\(output.count)")
        }

        return output
    }

    private func receiveEventData(from connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let data, !data.isEmpty {
                print("[RAOPServer] Event 数据: \(data.count) bytes")
            }

            if let error {
                print("[RAOPServer] Event 接收错误: \(error)")
                return
            }

            if isComplete {
                print("[RAOPServer] Event 连接关闭")
                return
            }

            self.receiveEventData(from: connection)
        }
    }

    // MARK: - Audio UDP 监听器

    private func startAudioDataListener(port: UInt16) {
        audioDataListener?.cancel()

        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true

        do {
            let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    print("[RAOPServer] Audio 数据监听就绪 (UDP)，端口 \(port)")
                case .failed(let error):
                    print("[RAOPServer] Audio 数据监听失败: \(error)")
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] conn in
                guard let self else { return }
                print("[RAOPServer] Audio 数据连接: \(conn.endpoint)")
                self.audioConnections.append(conn)
                conn.start(queue: self.queue)
                self.receiveAudioData(from: conn)
            }
            listener.start(queue: queue)
            audioDataListener = listener
        } catch {
            print("[RAOPServer] Audio 数据监听器创建失败: \(error)")
        }
    }

    private func startAudioControlListener(port: UInt16) {
        audioControlListener?.cancel()

        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true

        do {
            let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    print("[RAOPServer] Audio 控制监听就绪 (UDP)，端口 \(port)")
                case .failed(let error):
                    print("[RAOPServer] Audio 控制监听失败: \(error)")
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] conn in
                guard let self else { return }
                print("[RAOPServer] Audio 控制连接: \(conn.endpoint)")
                self.audioConnections.append(conn)
                conn.start(queue: self.queue)
                self.receiveAudioControl(from: conn)
            }
            listener.start(queue: queue)
            audioControlListener = listener
        } catch {
            print("[RAOPServer] Audio 控制监听器创建失败: \(error)")
        }
    }

    private func receiveAudioData(from connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let data, data.count > 12 {
                self.audioPacketCount += 1
                if self.audioPacketCount <= 3 || self.audioPacketCount % 500 == 0 {
                    let hex = data.prefix(16).map { String(format: "%02x", $0) }.joined(separator: " ")
                    print("[RAOPServer] Audio RTP #\(self.audioPacketCount): \(data.count)B hex=\(hex)")
                }

                // 解析 RTP 头：取出 payload
                let byte0 = data[0]
                let hasExtension = (byte0 & 0x10) != 0
                let csrcCount = Int(byte0 & 0x0F)
                var headerLen = 12 + csrcCount * 4

                // RTP 扩展头
                if hasExtension, headerLen + 4 <= data.count {
                    let extLen = Int(data[headerLen + 2]) << 8 | Int(data[headerLen + 3])
                    headerLen += 4 + extLen * 4
                }

                // 提取 timestamp
                let timestamp = UInt32(data[4]) << 24 | UInt32(data[5]) << 16 |
                                UInt32(data[6]) << 8  | UInt32(data[7])

                if headerLen < data.count {
                    let payload = Data(data[headerLen...])
                    self.onAudioData?(payload, timestamp)
                }
            }

            if let error {
                print("[RAOPServer] Audio 数据接收错误: \(error)")
                return
            }

            self.receiveAudioData(from: connection)
        }
    }

    private func receiveAudioControl(from connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let data, !data.isEmpty {
                // RTCP 控制包（暂时忽略）
            }

            if let error {
                return
            }

            self.receiveAudioControl(from: connection)
        }
    }

    // MARK: - NTP Timing

    private func startTimingListener(port: UInt16) {
        timingListener?.cancel()

        let params = NWParameters.udp
        params.allowLocalEndpointReuse = true

        do {
            let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    print("[RAOPServer] NTP Timing 监听就绪 (UDP)，端口 \(port)")
                case .failed(let error):
                    print("[RAOPServer] NTP Timing 监听失败: \(error)")
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] conn in
                guard let self else { return }
                print("[RAOPServer] NTP Timing 连接: \(conn.endpoint)")
                self.timingConnections.append(conn)
                conn.start(queue: self.queue)
                self.receiveTimingData(from: conn)
            }
            listener.start(queue: queue)
            timingListener = listener
        } catch {
            print("[RAOPServer] NTP Timing 监听器创建失败: \(error)")
        }
    }

    private func receiveTimingData(from connection: NWConnection) {
        connection.receiveMessage { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let data, data.count >= 32 {
                self.handleTimingRequest(data: data, connection: connection)
            }

            if let error {
                print("[RAOPServer] NTP Timing 接收错误: \(error)")
                return
            }

            self.receiveTimingData(from: connection)
        }
    }

    private func handleTimingRequest(data: Data, connection: NWConnection) {
        // AirPlay NTP timing packet: 32 bytes
        // Bytes 0-7: header/flags
        // Bytes 8-15: reference/origin timestamp
        // Bytes 16-23: receive timestamp
        // Bytes 24-31: transmit timestamp (set by iOS)
        //
        // Response:
        // - Copy iOS transmit timestamp to origin (bytes 8-15)
        // - Set receive timestamp to our current time (bytes 16-23)
        // - Set transmit timestamp to our current time (bytes 24-31)

        var response = Data(data)

        // 标记为响应包
        if response.count > 1 {
            response[0] = 0x00
            response[1] = 0x01  // response marker
        }

        // 复制 iOS 的 transmit timestamp 到 origin
        if data.count >= 32 {
            response.replaceSubrange(8..<16, with: data[24..<32])
        }

        // 当前 NTP 时间戳
        let now = Date().timeIntervalSince1970
        let ntpEpochOffset: TimeInterval = 2208988800 // 1900-01-01 to 1970-01-01
        let ntpSeconds = UInt32(now + ntpEpochOffset)
        let ntpFraction = UInt32((now - floor(now)) * Double(UInt32.max))

        // 设置 receive timestamp (bytes 16-23)
        var recvSec = ntpSeconds.bigEndian
        var recvFrac = ntpFraction.bigEndian
        response.replaceSubrange(16..<20, with: withUnsafeBytes(of: &recvSec) { Data($0) })
        response.replaceSubrange(20..<24, with: withUnsafeBytes(of: &recvFrac) { Data($0) })

        // 设置 transmit timestamp (bytes 24-31)
        var sendSec = ntpSeconds.bigEndian
        var sendFrac = ntpFraction.bigEndian
        response.replaceSubrange(24..<28, with: withUnsafeBytes(of: &sendSec) { Data($0) })
        response.replaceSubrange(28..<32, with: withUnsafeBytes(of: &sendFrac) { Data($0) })

        connection.send(content: response, completion: .contentProcessed { _ in })
    }

    private func parseContentLength(from header: String) -> Int {
        let lines = header.components(separatedBy: "\r\n")
        for line in lines {
            let parts = line.components(separatedBy: ":")
            guard parts.count >= 2 else { continue }
            if parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "content-length" {
                return Int(parts[1].trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            }
        }
        return 0
    }

    private func parseCSeq(from header: String) -> String {
        let lines = header.components(separatedBy: "\r\n")
        for line in lines {
            let parts = line.components(separatedBy: ":")
            guard parts.count >= 2 else { continue }
            if parts[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "cseq" {
                return parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return "0"
    }

    private func removeConnection(_ connection: NWConnection) {
        let connectionID = ObjectIdentifier(connection)
        activeConnections.removeAll { $0 === connection }
        receiveBuffers.removeValue(forKey: connectionID)
        pairingStates.removeValue(forKey: connectionID)
    }
    
    private func sendInfoResponse(connection: NWConnection, requestHeader: String) {
        // 构造 iOS 期望的特性信息字典
        let keyPair = KeyPairManager.shared
        let deviceID = keyPair.deviceID
        let deviceName = Host.current().localizedName ?? "AirScreen"
        let featuresValue = UInt64(0x5A7FFFF7) | (UInt64(0x1E) << 32)
        let txtAirPlay = buildInfoTXTRecord(deviceID: deviceID, deviceName: deviceName, publicKey: keyPair.publicKeyHex)
        
        // 必须与 Bonjour 中公布的一致
        // 0x5A7FFFF7 是我们宣告的 features 掩码 (Int 整形，这里如果超出 32bit 需要用 UInt64，先转成 Int)
        // 实际上 iOS 更喜欢接受字典里的各种特征
        
        var pubKeyData = Data()
        let pkData = keyPair.publicKey.rawRepresentation
        if true { // It turns out it might not be optional or we can safely just take rawRepresentation
            pubKeyData = pkData
        }
        
        let infoDict: [String: Any] = [
            "audioFormats": [NSNumber(value: 100)],
            "audioInputFormats": [NSNumber(value: 100)],
            "audioLatencies": [[
                "audioType": "default",
                "inputLatencyMicros": NSNumber(value: 0),
                "outputLatencyMicros": NSNumber(value: 0),
                "type": NSNumber(value: 100)
            ]],
            "audioOutputFormats": [NSNumber(value: 100)],
            "build": "17.0",
            "deviceID": deviceID.replacingOccurrences(of: ":", with: ""),
            "displays": [[
                "features": NSNumber(value: 14),
                "height": NSNumber(value: 1920),
                "heightPhysical": NSNumber(value: 0),
                "heightPixels": NSNumber(value: 1920),
                "maxFPS": NSNumber(value: 60),
                "overscanned": false,
                "refreshRate": NSNumber(value: 60),
                "rotation": false,
                "uuid": displayUUID,
                "width": NSNumber(value: 1080),
                "widthPhysical": NSNumber(value: 0),
                "widthPixels": NSNumber(value: 1080)
            ]],
            "features": NSNumber(value: featuresValue),
            "keepAliveLowPower": true,
            "keepAliveSendStatsAsBody": true,
            "macAddress": deviceID,
            "model": "AppleTV6,2",
            "name": deviceName,
            "nameIsFactoryDefault": false,
            "pi": receiverInstanceID,
            "pk": pubKeyData,
            "protocolVersion": "1.1",
            "sdk": "AirPlay;2.1.1-f.1",
            "sourceVersion": "220.68",
            "srcvers": "220.68",
            "statusFlags": NSNumber(value: 0x44),
            "txtAirPlay": txtAirPlay,
            "vv": NSNumber(value: 2)
        ]
        
        do {
            let plistData = try PropertyListSerialization.data(fromPropertyList: infoDict, format: .binary, options: 0)

            let cseq = parseCSeq(from: requestHeader)
            var header = makeResponseHeader(connection: connection, cseq: cseq, contentType: "application/x-apple-binary-plist", contentLength: plistData.count)
            
            var responseData = header.data(using: .utf8)!
            responseData.append(plistData)
            
            connection.send(content: responseData, completion: .contentProcessed({ error in
                if let err = error {
                    print("[RAOPServer] 发送 GET /info 响应失败: \(err)")
                } else {
                    print("[RAOPServer] 发送 GET /info 响应成功 (body=\(plistData.count) bytes)")
                }
            }))
        } catch {
            print("[RAOPServer] 生成 Info plist 失败: \(error)")
        }
    }

    private func state(for connection: NWConnection) -> PairingState {
        let connectionID = ObjectIdentifier(connection)
        if let state = pairingStates[connectionID] {
            return state
        }
        let state = PairingState()
        pairingStates[connectionID] = state
        return state
    }

    private var receiverInstanceID: String {
        if let stored = UserDefaults.standard.string(forKey: receiverInstanceKey) {
            return stored
        }
        let value = UUID().uuidString.lowercased()
        UserDefaults.standard.set(value, forKey: receiverInstanceKey)
        return value
    }

    private var displayUUID: String {
        if let stored = UserDefaults.standard.string(forKey: displayUUIDKey) {
            return stored
        }
        let value = UUID().uuidString.lowercased()
        UserDefaults.standard.set(value, forKey: displayUUIDKey)
        return value
    }

    private func buildInfoTXTRecord(deviceID: String, deviceName: String, publicKey: String) -> Data {
        buildTXTRecord([
            "acl": "0",
            "deviceid": deviceID,
            "features": "0x5A7FFFF7,0x1E",
            "flags": "0x44",
            "model": "AppleTV6,2",
            "pi": receiverInstanceID,
            "pk": publicKey,
            "protovers": "1.1",
            "srcvers": "220.68",
            "vv": "2"
        ])
    }

    private func buildTXTRecord(_ dict: [String: String]) -> Data {
        var data = Data()
        for (key, value) in dict {
            let entry = "\(key)=\(value)"
            let bytes = Array(entry.utf8.prefix(255))
            data.append(UInt8(bytes.count))
            data.append(contentsOf: bytes)
        }
        return data
    }

    private func makeResponseHeader(connection: NWConnection, cseq: String, contentType: String, contentLength: Int) -> String {
        let state = state(for: connection)
        let sessionID = state.sessionID

        var response = "RTSP/1.0 200 OK\r\n"
        response += "Audio-Jack-Status: Connected; type=digital\r\n"
        response += "Date: \(RFC1123DateFormatter.string(from: Date()))\r\n"
        response += "Session: \(sessionID)\r\n"
        response += "Content-Type: \(contentType)\r\n"
        response += "Content-Length: \(contentLength)\r\n"
        response += "Server: AirTunes/220.68\r\n"
        response += "CSeq: \(cseq)\r\n\r\n"
        return response
    }

    private func sendBinaryResponse(connection: NWConnection, cseq: String, body: Data, logLabel: String) {
        let header = makeResponseHeader(connection: connection, cseq: cseq, contentType: "application/octet-stream", contentLength: body.count)
        var fullResponse = header.data(using: .utf8)!
        fullResponse.append(body)

        connection.send(content: fullResponse, completion: .contentProcessed { error in
            if let error {
                print("[RAOPServer] 发送 \(logLabel) 响应失败: \(error)")
            } else {
                print("[RAOPServer] 发送 \(logLabel) 响应成功 (body=\(body.count) bytes)")
            }
        })
    }

    private func configureMirrorDecryptionIfPossible(for connection: NWConnection) {
        guard let fairPlayKey = streamEncryptionKey, fairPlayKey.count >= 16,
              let sharedSecret = state(for: connection).sharedSecret, sharedSecret.count >= 32,
              let streamConnectionID = mirrorStreamConnectionID else {
            return
        }

        let baseDigest = SHA512.hash(data: Data(fairPlayKey.prefix(16)) + sharedSecret)
        let baseKey = Data(baseDigest.prefix(16))
        let keySeed = Data("AirPlayStreamKey\(streamConnectionID)".utf8) + baseKey
        let ivSeed = Data("AirPlayStreamIV\(streamConnectionID)".utf8) + baseKey
        let derivedKey = Data(SHA512.hash(data: keySeed).prefix(16))
        let derivedIV = Data(SHA512.hash(data: ivSeed).prefix(16))

        if mirrorAESKey == derivedKey, mirrorAESIV == derivedIV, mirrorCryptor != nil {
            return
        }

        if let mirrorCryptor {
            CCCryptorRelease(mirrorCryptor)
            self.mirrorCryptor = nil
        }

        var cryptor: CCCryptorRef?
        var createStatus: CCCryptorStatus = Int32(kCCSuccess)
        derivedKey.withUnsafeBytes { keyBytes in
            derivedIV.withUnsafeBytes { ivBytes in
                createStatus = CCCryptorCreateWithMode(
                    CCOperation(kCCDecrypt),
                    CCMode(kCCModeCTR),
                    CCAlgorithm(kCCAlgorithmAES),
                    CCPadding(ccNoPadding),
                    ivBytes.baseAddress,
                    keyBytes.baseAddress,
                    derivedKey.count,
                    nil,
                    0,
                    0,
                    CCModeOptions(kCCModeOptionCTR_BE),
                    &cryptor
                )
            }
        }

        guard createStatus == Int32(kCCSuccess), let cryptor else {
            print("[RAOPServer] Mirror AES 派生成功，但 cryptor 创建失败 status=\(createStatus)")
            return
        }

        mirrorAESKey = derivedKey
        mirrorAESIV = derivedIV
        mirrorCryptor = cryptor
        print("[RAOPServer] Mirror AES 已初始化: streamConnectionID=\(streamConnectionID)")
    }

    private func aesCTRTransform(data: Data, sharedSecret: Data, ctrBigEndian: Bool = true) throws -> Data {
        // AirPlay Pair-Verify 使用 SHA-512(salt || ecdh_shared) 派生 AES 密钥和 IV
        // salt 字符串与 UxPlay / AirPlay 协议规范一致
        let keySalt = Data("Pair-Verify-AES-Key".utf8)
        let ivSalt  = Data("Pair-Verify-AES-IV".utf8)

        let keyDigest = SHA512.hash(data: keySalt + sharedSecret)
        let ivDigest  = SHA512.hash(data: ivSalt + sharedSecret)
        let key = Data(keyDigest.prefix(16))
        let iv = Data(ivDigest.prefix(16))

        var cryptor: CCCryptorRef?
        var createStatus: CCCryptorStatus = Int32(kCCSuccess)
        key.withUnsafeBytes { keyBytes in
            iv.withUnsafeBytes { ivBytes in
                let ctrMode: CCModeOptions = ctrBigEndian ? CCModeOptions(kCCModeOptionCTR_BE) : CCModeOptions(0)
                createStatus = CCCryptorCreateWithMode(CCOperation(kCCEncrypt), CCMode(kCCModeCTR), CCAlgorithm(kCCAlgorithmAES), CCPadding(ccNoPadding), ivBytes.baseAddress, keyBytes.baseAddress, key.count, nil, 0, 0, ctrMode, &cryptor)
            }
        }

        guard createStatus == Int32(kCCSuccess), let cryptor else {
            throw NSError(domain: "RAOPServer", code: Int(createStatus), userInfo: [NSLocalizedDescriptionKey: "无法创建 AES-CTR 加密器"])
        }
        defer { CCCryptorRelease(cryptor) }

        var output = Data(count: data.count + kCCBlockSizeAES128)
        let outputCapacity = output.count
        var outMoved = 0
        let updateStatus = output.withUnsafeMutableBytes { outBytes in
            data.withUnsafeBytes { dataBytes in
                CCCryptorUpdate(cryptor, dataBytes.baseAddress, data.count, outBytes.baseAddress, outputCapacity, &outMoved)
            }
        }

        guard updateStatus == kCCSuccess else {
            throw NSError(domain: "RAOPServer", code: Int(updateStatus), userInfo: [NSLocalizedDescriptionKey: "AES-CTR 处理失败"])
        }

        output.removeSubrange(outMoved..<output.count)
        return output
    }
}

private enum RFC1123DateFormatter {
    static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        f.timeZone = TimeZone(abbreviation: "GMT")
        return f
    }()

    static func string(from date: Date) -> String {
        formatter.string(from: date)
    }
}
