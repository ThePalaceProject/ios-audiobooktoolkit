import CommonCrypto
import Foundation

extension String {
  func hmac(algorithm: HmacAlgorithm, key: Data) -> Data {
    var digest = [UInt8](repeating: 0, count: algorithm.digestLength)
    if let myData = data(using: .utf8) {
      myData.withUnsafeBytes { selfPtr in
        key.withUnsafeBytes { ptr in
          CCHmac(algorithm.algorithm, ptr, key.count, selfPtr, myData.count, &digest)
        }
      }
    }
    return Data(bytes: digest)
  }

  mutating func removed(after substring: String) -> String {
    guard let range = range(of: substring) else {
      return self
    }
    removeSubrange(range.lowerBound..<endIndex)
    return self
  }

  var sha256: Data? {
    guard let data = data(using: .utf8, allowLossyConversion: true) else {
      return nil
    }
    var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
    data.withUnsafeBytes {
      _ = CC_SHA256($0.baseAddress, CC_LONG(data.count), &hash)
    }
    return Data(hash)
  }
}
