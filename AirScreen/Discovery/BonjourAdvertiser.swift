//
//  BonjourAdvertiser.swift
//  AirScreen
//
//  使用 DNS-SD API 在局域网广播 AirPlay 接收端服务
//  iOS 通过 mDNS 发现此服务后，才能发起 AirPlay 投屏连接
//
//  注册的服务类型：
//    _airplay._tcp  - 视频/屏幕镜像服务（端口 7000）
//    _raop._tcp     - 音频服务（端口 7001）
//

import Foundation
import dnssd

struct AirPlayServicePorts: Equatable {
    static let standard = AirPlayServicePorts(airPlay: 7000, raop: 7001)

    let airPlay: UInt16
    let raop: UInt16
}

final class BonjourAdvertiser {

    // MARK: - 公开属性

    static let shared = BonjourAdvertiser()

    // MARK: - 私有状态

    private var airplayRef: DNSServiceRef?
    private var raopRef:    DNSServiceRef?
    private var airplaySource: DispatchSourceRead?
    private var raopSource:    DispatchSourceRead?

    private let queue = DispatchQueue(label: "com.airscreen.bonjour", qos: .utility)
    private let receiverInstanceKey = "airplay.receiverInstanceID"

    private init() {}

    // MARK: - 公开接口

    /// 开始广播 AirPlay 服务（应用启动后调用）
    func startAdvertising(deviceName: String = "AirScreen", ports: AirPlayServicePorts = .standard) {
        stopAdvertising()

        let keyPair  = KeyPairManager.shared
        let deviceID = keyPair.deviceID
        let publicKey = keyPair.publicKeyHex
        let receiverInstanceID = self.receiverInstanceID

        // ── _airplay._tcp TXT Record ──────────────────────────────────────
        // features 位掩码含义（十六进制）：
        //   0x00000001 = Video
        //   0x00000080 = Screen Mirroring ← 关键
        //   0x00000200 = Audio
        //   完整值参考 UxPlay / RPiPlay 开源实现
        let airplayTXT: [String: String] = [
            "acl":      "0",
            "deviceid": deviceID,
            "features": "0x5A7FFFF7,0x1E",
            "flags":    "0x44",
            "model":    "AppleTV6,2",
            "pi":       receiverInstanceID,
            "protovers": "1.1",
            "pk":       publicKey,
            "srcvers":  "220.68",
            "vv":       "2",
        ]

        // ── _raop._tcp TXT Record ─────────────────────────────────────────
        // RAOP = Remote Audio Output Protocol（AirPlay 音频子协议）
        let raopTXT: [String: String] = [
            "acl":     "0",
            "am":      "AppleTV6,2",
            "ch":      "2",          // channels
            "cn":      "0,1,2,3",   // codec: PCM, AAC, AAC-ELD, ALAC
            "da":      "true",
            "et":      "0,3,5",     // encryption types
            "ft":      "0x5A7FFFF7,0x1E",
            "md":      "0,1,2",     // metadata
            "pk":      publicKey,
            "pi":      receiverInstanceID,
            "pw":      "false",     // no password
            "sf":      "0x44",
            "sm":      "false",
            "sv":      "false",
            "sr":      "44100",     // sample rate
            "ss":      "16",        // sample size
            "tp":      "UDP",
            "vn":      "65537",
            "vs":      "220.68",
            "vv":      "2",
        ]

        // 注册 _airplay._tcp
        register(
            name:    deviceName,
            type:    "_airplay._tcp",
            port:    ports.airPlay,
            txtDict: airplayTXT,
            refOut:  &airplayRef,
            sourceOut: &airplaySource
        )

        // 注册 _raop._tcp（名称格式：DEVICEID@设备名）
        let raopName = "\(deviceID.replacingOccurrences(of: ":", with: ""))@\(deviceName)"
        register(
            name:    raopName,
            type:    "_raop._tcp",
            port:    ports.raop,
            txtDict: raopTXT,
            refOut:  &raopRef,
            sourceOut: &raopSource
        )

        print("[Bonjour] 开始广播：\(deviceName)（设备ID: \(deviceID) airplay=\(ports.airPlay) raop=\(ports.raop)）")
    }

    /// 停止广播（应用退出前调用）
    func stopAdvertising() {
        airplaySource?.cancel()
        raopSource?.cancel()
        if let ref = airplayRef { DNSServiceRefDeallocate(ref); airplayRef = nil }
        if let ref = raopRef    { DNSServiceRefDeallocate(ref); raopRef    = nil }
        print("[Bonjour] 已停止广播")
    }

    // MARK: - 私有实现

    private func register(
        name: String,
        type: String,
        port: UInt16,
        txtDict: [String: String],
        refOut: inout DNSServiceRef?,
        sourceOut: inout DispatchSourceRead?
    ) {
        let txtData = buildTXTRecord(txtDict)
        let bigEndianPort = port.bigEndian

        let result = txtData.withUnsafeBytes { ptr -> DNSServiceErrorType in
            DNSServiceRegister(
                &refOut,
                0,                                          // flags
                0,                                          // interfaceIndex: 0 = all
                name,                                       // 服务名
                type,                                       // 服务类型
                nil,                                        // domain: nil = .local
                nil,                                        // host: nil = 本机
                bigEndianPort,                              // 端口（网络字节序）
                UInt16(txtData.count),                      // TXT record 长度
                ptr.baseAddress,                            // TXT record 内容
                { _, _, error, _, _, _, _ in                // 注册回调
                    if error != kDNSServiceErr_NoError {
                        print("[Bonjour] 注册失败，错误码: \(error)")
                    }
                },
                nil                                         // context
            )
        }

        guard result == kDNSServiceErr_NoError, let ref = refOut else {
            print("[Bonjour] DNSServiceRegister 调用失败: \(result) type=\(type)")
            return
        }

        // 使用 GCD DispatchSource 驱动 DNS-SD 事件循环（非阻塞）
        let fd = DNSServiceRefSockFD(ref)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler {
            let err = DNSServiceProcessResult(ref)
            if err != kDNSServiceErr_NoError {
                print("[Bonjour] DNSServiceProcessResult 错误: \(err)")
            }
        }
        source.resume()
        sourceOut = source

        print("[Bonjour] 已注册 \(type) → \(name):\(port)")
    }

    /// 将 String:String 字典编码为 DNS-SD TXT Record 二进制格式
    /// 格式：每条记录 = [length byte][key=value bytes]
    private func buildTXTRecord(_ dict: [String: String]) -> Data {
        var data = Data()
        for (key, value) in dict {
            let entry = "\(key)=\(value)"
            let bytes  = entry.utf8
            let length = UInt8(min(bytes.count, 255))
            data.append(length)
            data.append(contentsOf: bytes.prefix(255))
        }
        return data
    }

    private var receiverInstanceID: String {
        if let stored = UserDefaults.standard.string(forKey: receiverInstanceKey) {
            return stored
        }
        let value = UUID().uuidString.lowercased()
        UserDefaults.standard.set(value, forKey: receiverInstanceKey)
        return value
    }
}
