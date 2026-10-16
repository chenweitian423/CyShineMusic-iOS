// CyShineMusic iOS —— 音源脚本加密工具。
//
// 与 Android 的 MusicSourceCrypto.java 逐函数对齐，输入输出格式完全一致：
//   md5              hex 小写
//   bytesToBase64    "[1,2,3]" -> base64（无换行）
//   base64ToBytes    base64 -> "[1,2,3]"（无符号整数数组）
//   aesEncrypt       (dataB64, keyB64, ivB64, transformation) -> base64（无换行）
//                    transformation 支持 "AES"（ECB）与 "AES/CBC/PKCS7Padding"
//   rsaEncrypt       (dataB64, "-----BEGIN PUBLIC KEY-----...", padding) -> base64
//                    padding 支持 RSA/ECB/NoPadding、PKCS1Padding、OAEP 各变体
//
// 因为 preload.js 只依赖这些函数的「输入输出形状」，只要形状一致，
// Dart 与 JS 两侧都不需要为 iOS 做任何改动。

import CommonCrypto
import Foundation
import Security

enum MusicSourceCrypto {

  enum CryptoError: LocalizedError {
    case invalidBase64
    case invalidJsonBytes
    case unsupportedTransformation(String)
    case unsupportedPadding(String)
    case invalidPublicKey
    case failed(String)

    var errorDescription: String? {
      switch self {
      case .invalidBase64: return "非法的 Base64 输入"
      case .invalidJsonBytes: return "非法的字节数组输入"
      case .unsupportedTransformation(let value): return "不支持的 AES 变换: \(value)"
      case .unsupportedPadding(let value): return "不支持的 RSA padding: \(value)"
      case .invalidPublicKey: return "非法的 RSA 公钥"
      case .failed(let value): return value
      }
    }
  }

  // MARK: - MD5

  static func md5(_ value: String) throws -> String {
    let bytes = Array(value.utf8)
    var digest = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
    bytes.withUnsafeBufferPointer { buffer in
      _ = CC_MD5(buffer.baseAddress, CC_LONG(buffer.count), &digest)
    }
    return digest.map { String(format: "%02x", $0) }.joined()
  }

  // MARK: - Base64 <-> 字节数组

  /// 输入是 JS 侧 JSON.stringify(Array.from(uint8Array)) 的字符串。
  static func bytesToBase64(_ jsonBytes: String) throws -> String {
    guard let data = jsonBytes.data(using: .utf8),
          let raw = try? JSONSerialization.jsonObject(with: data) as? [Any] else {
      throw CryptoError.invalidJsonBytes
    }
    var bytes = [UInt8]()
    bytes.reserveCapacity(raw.count)
    for item in raw {
      let value: Int
      if let number = item as? NSNumber {
        value = number.intValue
      } else if let number = item as? Int {
        value = number
      } else {
        throw CryptoError.invalidJsonBytes
      }
      bytes.append(UInt8(truncatingIfNeeded: value))
    }
    return Data(bytes).base64EncodedString()
  }

  /// 输出形如 "[1,2,3]"，元素为无符号整数（对应 Java 的 item & 0xff）。
  static func base64ToBytes(_ value: String) throws -> String {
    guard let data = Data(base64Encoded: value,
                          options: [.ignoreUnknownCharacters]) else {
      throw CryptoError.invalidBase64
    }
    let numbers = data.map { String(Int($0)) }.joined(separator: ",")
    return "[\(numbers)]"
  }

  // MARK: - AES

  static func aesEncrypt(_ dataBase64: String,
                         _ keyBase64: String,
                         _ ivBase64: String,
                         _ transformation: String) throws -> String {
    guard let data = Data(base64Encoded: dataBase64, options: [.ignoreUnknownCharacters]) else {
      throw CryptoError.invalidBase64
    }
    guard let key = Data(base64Encoded: keyBase64, options: [.ignoreUnknownCharacters]) else {
      throw CryptoError.invalidBase64
    }

    // Java 的 PKCS7Padding 就是 PKCS5Padding，两者在 AES 下等价。
    let normalized = transformation.replacingOccurrences(of: "PKCS5Padding",
                                                        with: "PKCS7Padding")
    let upper = normalized.uppercased()

    var options = CCOptions(kCCOptionPKCS7Padding)
    var iv = [UInt8](repeating: 0, count: kCCBlockSizeAES128)

    if upper.contains("/CBC/") {
      guard let sourceIv = Data(base64Encoded: ivBase64, options: [.ignoreUnknownCharacters]) else {
        throw CryptoError.invalidBase64
      }
      // 与 Java 一致：IV 不足 16 字节时右侧补零，超出则截断。
      let bytes = [UInt8](sourceIv)
      for index in 0..<min(bytes.count, iv.count) { iv[index] = bytes[index] }
    } else if upper == "AES" || upper.hasPrefix("AES/ECB") {
      options |= CCOptions(kCCOptionECBMode)
    } else {
      throw CryptoError.unsupportedTransformation(transformation)
    }

    let keyBytes = [UInt8](key)
    guard keyBytes.count == kCCKeySizeAES128 ||
            keyBytes.count == kCCKeySizeAES192 ||
            keyBytes.count == kCCKeySizeAES256 else {
      throw CryptoError.failed("AES 密钥长度必须是 16/24/32 字节，当前 \(keyBytes.count)")
    }

    var output = [UInt8](repeating: 0, count: data.count + kCCBlockSizeAES128)
    var moved = 0
    let status = keyBytes.withUnsafeBufferPointer { keyPointer in
      iv.withUnsafeBufferPointer { ivPointer in
        [UInt8](data).withUnsafeBufferPointer { dataPointer in
          CCCrypt(CCOperation(kCCEncrypt),
                  CCAlgorithm(kCCAlgorithmAES),
                  options,
                  keyPointer.baseAddress, keyBytes.count,
                  ivPointer.baseAddress,
                  dataPointer.baseAddress, dataPointer.count,
                  &output, output.count,
                  &moved)
        }
      }
    }

    guard status == kCCSuccess else {
      throw CryptoError.failed("AES 加密失败 (CCCrypt status=\(status))")
    }
    return Data(output.prefix(moved)).base64EncodedString()
  }

  // MARK: - RSA

  static func rsaEncrypt(_ dataBase64: String,
                         _ publicKey: String,
                         _ padding: String) throws -> String {
    guard let data = Data(base64Encoded: dataBase64, options: [.ignoreUnknownCharacters]) else {
      throw CryptoError.invalidBase64
    }
    let key = try parseRSAPublicKey(publicKey)
    let algorithm: SecKeyAlgorithm
    switch padding.uppercased() {
    case "RSA/ECB/NOPADDING": algorithm = .rsaEncryptionRaw
    case "RSA/ECB/PKCS1PADDING": algorithm = .rsaEncryptionPKCS1
    case "RSA/ECB/OAEPWITHSHA-1ANDMGF1PADDING": algorithm = .rsaEncryptionOAEPSHA1
    case "RSA/ECB/OAEPWITHSHA-256ANDMGF1PADDING": algorithm = .rsaEncryptionOAEPSHA256
    default: throw CryptoError.unsupportedPadding(padding)
    }

    guard SecKeyIsAlgorithmSupported(key, .encrypt, algorithm) else {
      throw CryptoError.failed("公钥不支持该 padding: \(padding)")
    }
    var error: Unmanaged<CFError>?
    guard let encrypted = SecKeyCreateEncryptedData(key, algorithm, data as CFData, &error) else {
      throw CryptoError.failed("RSA 加密失败: \(describe(error))")
    }
    return (encrypted as Data).base64EncodedString()
  }

  /// 解析 PEM/裸 Base64 的 X.509 SubjectPublicKeyInfo 公钥。
  ///
  /// SecKeyCreateWithData 需要 PKCS#1 RSAPublicKey，而 PEM 里是 SPKI 包裹，
  /// 因此要先做一次最小 ASN.1 拆包取出 subjectPublicKey BIT STRING。
  static func parseRSAPublicKey(_ pem: String) throws -> SecKey {
    let normalized = pem
      .replacingOccurrences(of: "-----BEGIN PUBLIC KEY-----", with: "")
      .replacingOccurrences(of: "-----END PUBLIC KEY-----", with: "")
      .replacingOccurrences(of: "-----BEGIN RSA PUBLIC KEY-----", with: "")
      .replacingOccurrences(of: "-----END RSA PUBLIC KEY-----", with: "")
      .components(separatedBy: .whitespacesAndNewlines)
      .joined()

    guard let der = Data(base64Encoded: normalized, options: [.ignoreUnknownCharacters]),
          !der.isEmpty else {
      throw CryptoError.invalidPublicKey
    }

    let pkcs1 = (try? extractSubjectPublicKey(from: der)) ?? der

    let attributes: [String: Any] = [
      kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
      kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
    ]
    var error: Unmanaged<CFError>?
    if let key = SecKeyCreateWithData(pkcs1 as CFData, attributes as CFDictionary, &error) {
      return key
    }
    // 有些密钥本身就是 PKCS#1，直接重试一次裸 DER。
    if pkcs1 != der,
       let key = SecKeyCreateWithData(der as CFData, attributes as CFDictionary, &error) {
      return key
    }
    throw CryptoError.failed("无法解析 RSA 公钥: \(describe(error))")
  }

  /// 从 SPKI 中取出 BIT STRING 内容（= PKCS#1 RSAPublicKey）。
  private static func extractSubjectPublicKey(from der: Data) throws -> Data {
    let bytes = [UInt8](der)
    var index = 0

    // SEQUENCE (SubjectPublicKeyInfo)
    guard readTag(bytes, &index) == 0x30 else { throw CryptoError.invalidPublicKey }
    _ = try readLength(bytes, &index)
    // AlgorithmIdentifier SEQUENCE
    guard readTag(bytes, &index) == 0x30 else { throw CryptoError.invalidPublicKey }
    let algorithmLength = try readLength(bytes, &index)
    index += algorithmLength
    guard index < bytes.count else { throw CryptoError.invalidPublicKey }
    // BIT STRING
    guard readTag(bytes, &index) == 0x03 else { throw CryptoError.invalidPublicKey }
    let bitStringLength = try readLength(bytes, &index)
    guard index < bytes.count else { throw CryptoError.invalidPublicKey }
    // BIT STRING 首字节是「未使用位数」，恒为 0。
    let unused = bytes[index]
    guard unused == 0 else { throw CryptoError.invalidPublicKey }
    index += 1
    let end = min(index + bitStringLength - 1, bytes.count)
    guard end > index else { throw CryptoError.invalidPublicKey }
    return Data(bytes[index..<end])
  }

  private static func readTag(_ bytes: [UInt8], _ index: inout Int) -> UInt8? {
    guard index < bytes.count else { return nil }
    let tag = bytes[index]
    index += 1
    return tag
  }

  private static func readLength(_ bytes: [UInt8], _ index: inout Int) throws -> Int {
    guard index < bytes.count else { throw CryptoError.invalidPublicKey }
    let first = bytes[index]
    index += 1
    if first & 0x80 == 0 { return Int(first) }
    let count = Int(first & 0x7F)
    guard count > 0, count <= 4, index + count <= bytes.count else {
      throw CryptoError.invalidPublicKey
    }
    var length = 0
    for _ in 0..<count {
      length = (length << 8) | Int(bytes[index])
      index += 1
    }
    return length
  }

  private static func describe(_ error: Unmanaged<CFError>?) -> String {
    guard let error else { return "unknown" }
    return (error.takeRetainedValue() as Error).localizedDescription
  }
}
