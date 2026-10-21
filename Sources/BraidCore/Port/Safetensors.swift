//
//  Safetensors.swift
//  BraidCore
//
//  Created by Ritesh Pakala.
//  Copyright © 2026 Rao Studios LLC.
//
//  WHAT: A small safetensors reader with no MLX: the header, and any I32, F16 or F32 tensor as a
//        Swift array. Enough to read a RaoLM provenance index's layout (its values, key rows and
//        offsets) for the port validation and for `braid verify` on an imported RaoLM log.
//  PIN:  The format is little-endian: an 8-byte header length, the header's JSON, then the data,
//        each tensor at `data_offsets` relative to the data's start. Every range is checked
//        against the file and against its dtype and shape before a byte is read; F16 is widened
//        bit-exactly (subnormals, infinities and NaN included).
//

import Foundation

public struct SafetensorsFile: Sendable {
    public struct Tensor: Sendable, Equatable {
        public var name: String
        /// "I32", "F16", "F32", … as the header names it.
        public var dtype: String
        public var shape: [Int]
        /// The tensor's bytes, absolute in the file.
        public var bytes: Range<Int>

        public var count: Int { shape.reduce(1, *) }
    }

    public enum Failure: Error, CustomStringConvertible, Equatable {
        case short(String)
        case header(String)
        case missing(String)
        case dtype(name: String, found: String, expected: String)
        case bounds(String)

        public var description: String {
            switch self {
            case .short(let detail): return "safetensors: the file is too short (\(detail))"
            case .header(let detail): return "safetensors: the header is not valid (\(detail))"
            case .missing(let name): return "safetensors: no tensor named \(name)"
            case .dtype(let name, let found, let expected): return "safetensors: \(name) is \(found), not \(expected)"
            case .bounds(let detail): return "safetensors: \(detail)"
            }
        }
    }

    public let url: URL?
    public let data: Data
    public let tensors: [String: Tensor]
    public let metadata: [String: String]

    /// Reads (maps) the file at `url`.
    public init(url: URL) throws {
        try self.init(data: Data(contentsOf: url, options: .alwaysMapped), url: url)
    }

    public init(data: Data, url: URL? = nil) throws {
        self.url = url
        self.data = data
        guard data.count >= 8 else { throw Failure.short("\(data.count) bytes, no header length") }
        let length = data.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: 0, as: UInt64.self)) }
        guard length <= UInt64(data.count - 8) else { throw Failure.short("a \(length)-byte header in \(data.count) bytes") }
        let start = data.startIndex
        let headerData = data.subdata(in: (start + 8)..<(start + 8 + Int(length)))
        guard let object = try? JSONSerialization.jsonObject(with: headerData), let header = object as? [String: Any] else {
            throw Failure.header("not a JSON object")
        }
        let base = 8 + Int(length)
        var tensors: [String: Tensor] = [:]
        var metadata: [String: String] = [:]
        for (name, value) in header {
            if name == "__metadata__" {
                for (key, entry) in (value as? [String: Any]) ?? [:] { metadata[key] = entry as? String ?? "\(entry)" }
                continue
            }
            guard let entry = value as? [String: Any], let dtype = entry["dtype"] as? String,
                  let shape = (entry["shape"] as? [Any])?.compactMap({ ($0 as? NSNumber)?.intValue }),
                  let offsets = (entry["data_offsets"] as? [Any])?.compactMap({ ($0 as? NSNumber)?.intValue }), offsets.count == 2
            else { throw Failure.header("tensor \(name) has no dtype, shape or data_offsets") }
            guard offsets[0] >= 0, offsets[0] <= offsets[1], base + offsets[1] <= data.count else {
                throw Failure.bounds("\(name) spans \(offsets[0])..<\(offsets[1]) past the file's \(data.count - base) data bytes")
            }
            let tensor = Tensor(name: name, dtype: dtype, shape: shape, bytes: (base + offsets[0])..<(base + offsets[1]))
            if let width = Self.width(dtype), tensor.count * width != tensor.bytes.count {
                throw Failure.bounds("\(name) is \(dtype) \(shape) but holds \(tensor.bytes.count) bytes")
            }
            tensors[name] = tensor
        }
        self.tensors = tensors
        self.metadata = metadata
    }

    /// Bytes per element of the dtypes this reader widens; nil for the rest.
    static func width(_ dtype: String) -> Int? {
        switch dtype {
        case "I32", "F32": return 4
        case "F16", "BF16", "I16": return 2
        case "I64", "F64": return 8
        case "U8", "I8", "BOOL": return 1
        default: return nil
        }
    }

    public func tensor(_ name: String) throws -> Tensor {
        guard let tensor = tensors[name] else { throw Failure.missing(name) }
        return tensor
    }

    /// An I32 tensor, flattened.
    public func int32(_ name: String) throws -> [Int32] {
        let tensor = try tensor(name)
        guard tensor.dtype == "I32" else { throw Failure.dtype(name: name, found: tensor.dtype, expected: "I32") }
        return data.withUnsafeBytes { raw in
            (0..<tensor.count).map { Int32(littleEndian: raw.loadUnaligned(fromByteOffset: tensor.bytes.lowerBound + 4 * $0, as: Int32.self)) }
        }
    }

    /// An F32 tensor, or an F16 one widened, flattened.
    public func float32(_ name: String) throws -> [Float] {
        let tensor = try tensor(name)
        switch tensor.dtype {
        case "F32":
            return data.withUnsafeBytes { raw in
                (0..<tensor.count).map { Float(bitPattern: UInt32(littleEndian: raw.loadUnaligned(fromByteOffset: tensor.bytes.lowerBound + 4 * $0, as: UInt32.self))) }
            }
        case "F16":
            return data.withUnsafeBytes { raw in
                (0..<tensor.count).map { Self.widen(UInt16(littleEndian: raw.loadUnaligned(fromByteOffset: tensor.bytes.lowerBound + 2 * $0, as: UInt16.self))) }
            }
        default:
            throw Failure.dtype(name: name, found: tensor.dtype, expected: "F32 or F16")
        }
    }

    /// IEEE half to single, exactly.
    public static func widen(_ half: UInt16) -> Float {
        let sign = UInt32(half & 0x8000) << 16
        let exponent = UInt32((half >> 10) & 0x1F)
        let mantissa = UInt32(half & 0x03FF)
        if exponent == 0 {
            // Zero or subnormal: mantissa × 2^-24, exact in single precision.
            let magnitude = Float(mantissa) * Float(bitPattern: 0x3380_0000)
            return sign == 0 ? magnitude : -magnitude
        }
        if exponent == 0x1F { return Float(bitPattern: sign | 0x7F80_0000 | (mantissa << 13)) }
        return Float(bitPattern: sign | ((exponent + 112) << 23) | (mantissa << 13))
    }

    /// The SHA-256 of the whole file: what a RaoLM manifest calls the index's sha256.
    public var sha256: String { ContentHash.sha256Hex(data) }
}
