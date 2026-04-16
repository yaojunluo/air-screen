//
//  KeyPairManager.swift
//  AirScreen
//
//  管理 Ed25519 密钥对（持久化存储于 UserDefaults）
//  用于 AirPlay 配对认证的长期身份密钥
//

import Foundation
import CryptoKit

final class KeyPairManager {
    static let shared = KeyPairManager()

    private let publicKeyDefaultsKey  = "airplay.ed25519.publicKey"
    private let privateKeyDefaultsKey = "airplay.ed25519.privateKey"

    private(set) var privateKey: Curve25519.Signing.PrivateKey
    private(set) var publicKey:  Curve25519.Signing.PublicKey

    private init() {
        let defaults = UserDefaults.standard

        if let pubData  = defaults.data(forKey: publicKeyDefaultsKey),
           let privData = defaults.data(forKey: privateKeyDefaultsKey),
           let privKey  = try? Curve25519.Signing.PrivateKey(rawRepresentation: privData) {
            privateKey = privKey
            publicKey  = privKey.publicKey
            // 验证公钥一致
            guard privKey.publicKey.rawRepresentation == pubData else {
                (privateKey, publicKey) = KeyPairManager.generateAndStore()
                return
            }
        } else {
            (privateKey, publicKey) = KeyPairManager.generateAndStore()
        }
    }

    @discardableResult
    private static func generateAndStore() -> (Curve25519.Signing.PrivateKey, Curve25519.Signing.PublicKey) {
        let privKey = Curve25519.Signing.PrivateKey()
        let pubKey  = privKey.publicKey
        let defaults = UserDefaults.standard
        defaults.set(privKey.rawRepresentation, forKey: "airplay.ed25519.privateKey")
        defaults.set(pubKey.rawRepresentation,  forKey: "airplay.ed25519.publicKey")
        print("[KeyPair] 生成新的 Ed25519 密钥对")
        return (privKey, pubKey)
    }

    /// 公钥的十六进制字符串（用于 mDNS TXT Record pk 字段）
    var publicKeyHex: String {
        publicKey.rawRepresentation.hexString
    }

    /// 生成一个伪随机的设备 MAC 地址（首次运行后固定）
    var deviceID: String {
        let key = "airplay.deviceID"
        if let stored = UserDefaults.standard.string(forKey: key) { return stored }
        var bytes = [UInt8](repeating: 0, count: 6)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        bytes[0] = (bytes[0] & 0xFE) | 0x02  // 本地管理、单播
        let mac = bytes.map { String(format: "%02X", $0) }.joined(separator: ":")
        UserDefaults.standard.set(mac, forKey: key)
        return mac
    }
}

extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
