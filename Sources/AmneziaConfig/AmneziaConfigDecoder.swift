import Foundation
import Compression
import zlib

public enum AmneziaConfigDecodeError: LocalizedError, Equatable {
    case invalidScheme
    case invalidBase64
    case compressedPayloadTooShort
    case decompressionFailed
    case decompressedPayloadSizeMismatch(expected: Int, actual: Int)
    case payloadIsNotUTF8

    public var errorDescription: String? {
        switch self {
        case .invalidScheme:
            return "Amnezia key must start with vpn://."
        case .invalidBase64:
            return "Amnezia key is not valid base64url data."
        case .compressedPayloadTooShort:
            return "Amnezia key payload is too short."
        case .decompressionFailed:
            return "Amnezia key payload could not be decompressed."
        case .decompressedPayloadSizeMismatch(let expected, let actual):
            return "Amnezia key payload looks incomplete or unsupported: expected \(expected) bytes after decompression, got \(actual)."
        case .payloadIsNotUTF8:
            return "Amnezia key payload is not a readable WireGuard configuration."
        }
    }
}

public struct AmneziaConfigDecoder: Sendable {
    public init() {}

    public func decodePayload(from urlString: String) throws -> Data {
        let encoded: String

        if urlString.hasPrefix("vpn://") {
            encoded = String(urlString.dropFirst("vpn://".count))
        } else {
            throw AmneziaConfigDecodeError.invalidScheme
        }

        guard let compressed = Data(base64URLEncoded: encoded) else {
            throw AmneziaConfigDecodeError.invalidBase64
        }

        return try decompressQtPayload(compressed)
    }

    public func decodeString(from urlString: String) throws -> String {
        let payload = try decodePayload(from: urlString)

        guard let string = String(data: payload, encoding: .utf8) else {
            throw AmneziaConfigDecodeError.payloadIsNotUTF8
        }

        return string
    }

    private func decompressQtPayload(_ compressed: Data) throws -> Data {
        guard compressed.count > 4 else {
            throw AmneziaConfigDecodeError.compressedPayloadTooShort
        }

        let expectedSize = compressed.prefix(4).reduce(UInt32(0)) { partial, byte in
            (partial << 8) | UInt32(byte)
        }

        guard expectedSize > 0 else {
            throw AmneziaConfigDecodeError.decompressionFailed
        }

        let zlibPayload = compressed.dropFirst(4)
        let expectedCount = Int(expectedSize)
        var outputCapacity = max(expectedCount * 2, 256)
        let maximumCapacity = max(outputCapacity * 16, 1024 * 1024)

        if let output = zlibDecompress(zlibPayload, initialCapacity: outputCapacity, maximumCapacity: maximumCapacity) {
            return output
        }

        outputCapacity = max(expectedCount * 2, 256)
        while outputCapacity <= maximumCapacity {
            if let output = compressionFrameworkDecompress(zlibPayload, capacity: outputCapacity, minimumBytes: expectedCount) {
                return output
            }

            outputCapacity *= 2
        }

        throw AmneziaConfigDecodeError.decompressionFailed
    }

    private func zlibDecompress(_ payload: Data.SubSequence, initialCapacity: Int, maximumCapacity: Int) -> Data? {
        var outputCapacity = initialCapacity
        while outputCapacity <= maximumCapacity {
            var output = Data(count: outputCapacity)
            var outputSize = uLongf(outputCapacity)
            let status = output.withUnsafeMutableBytes { outputBytes in
                payload.withUnsafeBytes { inputBytes in
                    uncompress(
                        outputBytes.bindMemory(to: Bytef.self).baseAddress!,
                        &outputSize,
                        inputBytes.bindMemory(to: Bytef.self).baseAddress!,
                        uLong(payload.count)
                    )
                }
            }

            if status == Z_OK {
                let written = Int(outputSize)
                output.removeSubrange(written..<output.count)
                return output
            }

            guard status == Z_BUF_ERROR else {
                return nil
            }

            outputCapacity *= 2
        }

        return nil
    }

    private func compressionFrameworkDecompress(_ payload: Data.SubSequence, capacity: Int, minimumBytes: Int) -> Data? {
        var output = Data(count: capacity)
        let written = output.withUnsafeMutableBytes { outputBytes in
            payload.withUnsafeBytes { inputBytes in
                compression_decode_buffer(
                    outputBytes.bindMemory(to: UInt8.self).baseAddress!,
                    outputBytes.count,
                    inputBytes.bindMemory(to: UInt8.self).baseAddress!,
                    inputBytes.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }

        guard written > 0, written < capacity, written >= minimumBytes else {
            return nil
        }

        output.removeSubrange(written..<output.count)
        return output
    }
}

private extension Data {
    init?(base64URLEncoded value: String) {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")

        let padding = base64.count % 4
        if padding > 0 {
            base64.append(String(repeating: "=", count: 4 - padding))
        }

        self.init(base64Encoded: base64)
    }
}
