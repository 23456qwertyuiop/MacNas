//
//  Crypto.swift
//  MacNas
//
//  SHA-256（文件流式 / 增量）与密码哈希（PBKDF2-HMAC-SHA256）。
//

import Foundation
import CryptoKit
import CommonCrypto

func hexString<S: Sequence>(_ bytes: S) -> String where S.Element == UInt8 {
    var out = String()
    out.reserveCapacity(64)
    for byte in bytes {
        out += String(format: "%02x", byte)
    }
    return out
}

func dataFromHex(_ hex: String) -> Data? {
    var hex = hex
    if hex.count % 2 != 0 { return nil }
    var data = Data(capacity: hex.count / 2)
    while !hex.isEmpty {
        let index = hex.index(hex.startIndex, offsetBy: 2)
        guard let byte = UInt8(hex[hex.startIndex..<index], radix: 16) else { return nil }
        data.append(byte)
        hex = String(hex[index...])
    }
    return data
}

// MARK: - 文件哈希

/// 增量式 SHA-256：上传时边收边算，落盘后不需要再读一遍文件
final class StreamingHasher {
    private var hasher = SHA256()
    private(set) var byteCount: Int64 = 0

    func update(_ data: Data) {
        hasher.update(data: data)
        byteCount += Int64(data.count)
    }

    func finalize() -> String {
        hexString(hasher.finalize())
    }
}

enum FileHash {
    /// 流式读取整个文件计算 SHA-256
    static func sha256(of url: URL, chunkSize: Int = 1 << 20) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try handle.read(upToCount: chunkSize) ?? Data()
            if chunk.isEmpty { break }
            hasher.update(data: chunk)
        }
        return hexString(hasher.finalize())
    }

    static func sha256(of data: Data) -> String {
        hexString(SHA256.hash(data: data))
    }
}

// MARK: - 随机数

enum RandomBytes {
    static func make(count: Int) -> Data {
        var bytes = [UInt8](repeating: 0, count: count)
        for i in 0..<count { bytes[i] = UInt8.random(in: 0...255) }
        return Data(bytes)
    }

    static func hex(count: Int) -> String { hexString(make(count: count)) }
}

// MARK: - 密码

enum PasswordHasher {
    static let iterations = 100_000
    static let saltByteCount = 16
    static let keyByteCount = 32

    static func makeSalt() -> String { hexString(RandomBytes.make(count: saltByteCount)) }

    static func derive(password: String, saltHex: String) -> String {
        guard let salt = dataFromHex(saltHex) else { return "" }
        let key = pbkdf2(password: Data(password.utf8), salt: salt,
                         iterations: iterations, keyByteCount: keyByteCount)
        return hexString(key)
    }

    static func verify(password: String, saltHex: String, expectedHex: String) -> Bool {
        let actual = derive(password: password, saltHex: saltHex)
        guard !actual.isEmpty, !expectedHex.isEmpty else { return false }
        return constantTimeEquals(actual, expectedHex)
    }

    static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        if x.count != y.count { return false }
        var diff: UInt8 = 0
        for i in 0..<x.count { diff |= x[i] ^ y[i] }
        return diff == 0
    }

    /// PBKDF2-HMAC-SHA256。
    ///
    /// 用系统 CommonCrypto 而不是自己用 CryptoKit 拼 HMAC 循环：
    /// 参数与输出完全一致（PBKDF2 是标准算法，已有哈希继续有效），但快一个数量级。
    /// 这一点很关键：macOS 的 WebDAV 客户端对单个请求有约 300~500ms 的容忍上限，
    /// 手写实现在 Debug 构建下要 500ms 以上，会导致 Finder 挂在协商阶段、无法挂载。
    static func pbkdf2(password: Data, salt: Data, iterations: Int, keyByteCount: Int) -> Data {
        var derived = [UInt8](repeating: 0, count: keyByteCount)
        let status = password.withUnsafeBytes { passwordBuffer -> Int32 in
            let passwordBase = passwordBuffer.bindMemory(to: Int8.self).baseAddress
            return salt.withUnsafeBytes { saltBuffer -> Int32 in
                let saltBase = saltBuffer.bindMemory(to: UInt8.self).baseAddress
                return CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                                            passwordBase, password.count,
                                            saltBase, salt.count,
                                            CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                                            UInt32(iterations),
                                            &derived, derived.count)
            }
        }
        // 失败时返回空数据，verify 会因为长度不符而判为不通过（不在这里依赖日志模块）
        guard status == kCCSuccess else { return Data() }
        return Data(derived)
    }
}
