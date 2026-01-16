import Foundation
import simd

/// Binary format reader for PlayCanvas Super-compressed PLY files
/// 
/// Compressed PLY files use a binary format with:
/// - Chunk metadata (quantization bounds)
/// - Packed binary vertex data (quantized)
/// - No standard PLY header with property declarations
internal struct PlayCanvasCompressedPLYReader {
    /// Chunk metadata containing quantization bounds
    struct ChunkMetadata {
        var positionMin: SIMD3<Float>
        var positionMax: SIMD3<Float>
        var scaleMin: Float
        var scaleMax: Float
        var opacityMin: Float
        var opacityMax: Float
    }
    
    /// Read compressed PLY file and convert to SplatScenePoint array
    static func readCompressedPLY(from url: URL) throws -> [SplatScenePoint] {
        guard let inputStream = InputStream(url: url) else {
            throw CompressedPLYSceneReader.Error.cannotOpenSource(url)
        }
        
        inputStream.open()
        defer { inputStream.close() }
        
        // Read entire file into memory
        var fileData = Data()
        let bufferSize = 1024 * 1024 // 1MB chunks
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        
        while inputStream.hasBytesAvailable {
            let bytesRead = inputStream.read(buffer, maxLength: bufferSize)
            if bytesRead <= 0 {
                break
            }
            fileData.append(buffer, count: bytesRead)
        }
        
        guard fileData.count > 0 else {
            throw CompressedPLYSceneReader.Error.invalidFileStructure("File is empty")
        }
        
        return try parseCompressedPLYData(fileData)
    }
    
    /// Parse compressed PLY binary data
    private static func parseCompressedPLYData(_ data: Data) throws -> [SplatScenePoint] {
        var offset = 0
        
        // DEBUG: Log file size
        print("[PlayCanvasCompressedPLYReader] File size: \(data.count) bytes")
        
        // Check if file starts with "ply" header (some compressed formats might have minimal header)
        // If it does, skip to binary data section
        if data.count >= 3, let headerStart = String(data: data.prefix(3), encoding: .utf8), headerStart == "ply" {
            print("[PlayCanvasCompressedPLYReader] File starts with 'ply' header")
            
            // Try to read and log the header
            if let headerEndRange = data.range(of: "end_header\n".data(using: .utf8)!) {
                offset = headerEndRange.upperBound
                let headerData = data.prefix(offset)
                if let headerString = String(data: headerData, encoding: .utf8) {
                    print("[PlayCanvasCompressedPLYReader] PLY Header (first 500 chars):")
                    let preview = String(headerString.prefix(500))
                    print(preview)
                    if headerString.count > 500 {
                        print("... (header truncated, total \(headerString.count) chars)")
                    }
                }
            } else if let headerEndRange = data.range(of: "end_header\r\n".data(using: .utf8)!) {
                offset = headerEndRange.upperBound
                let headerData = data.prefix(offset)
                if let headerString = String(data: headerData, encoding: .utf8) {
                    print("[PlayCanvasCompressedPLYReader] PLY Header (first 500 chars):")
                    let preview = String(headerString.prefix(500))
                    print(preview)
                    if headerString.count > 500 {
                        print("... (header truncated, total \(headerString.count) chars)")
                    }
                }
            } else {
                // No standard header end found, assume it's pure binary
                print("[PlayCanvasCompressedPLYReader] No 'end_header' marker found, treating as pure binary")
                offset = 0
            }
        } else {
            print("[PlayCanvasCompressedPLYReader] File does NOT start with 'ply' header, treating as pure binary")
        }
        
        print("[PlayCanvasCompressedPLYReader] Binary data offset after header: \(offset)")
        print("[PlayCanvasCompressedPLYReader] Remaining data size: \(data.count - offset) bytes")
        
        // Log first few bytes of binary data for inspection
        if data.count > offset {
            let previewSize = min(64, data.count - offset)
            let previewData = data.subdata(in: offset..<(offset + previewSize))
            let hexString = previewData.map { String(format: "%02x", $0) }.joined(separator: " ")
            print("[PlayCanvasCompressedPLYReader] First \(previewSize) bytes of binary data (hex): \(hexString)")
        }
        
        // Try different format layouts - PlayCanvas format might vary
        // Layout 1: Point count first, then metadata, then data
        print("[PlayCanvasCompressedPLYReader] Attempting Layout 1 (point count first, then metadata, then data)")
        do {
            let result = try parseLayout1(data: data, offset: offset)
            print("[PlayCanvasCompressedPLYReader] Layout 1 succeeded! Parsed \(result.count) points")
            return result
        } catch {
            print("[PlayCanvasCompressedPLYReader] Layout 1 failed: \(error.localizedDescription)")
            // Try layout 2 if layout 1 fails
        }
        
        // Layout 2: Metadata first, then point count, then data
        print("[PlayCanvasCompressedPLYReader] Attempting Layout 2 (metadata first, then point count, then data)")
        do {
            let result = try parseLayout2(data: data, offset: offset)
            print("[PlayCanvasCompressedPLYReader] Layout 2 succeeded! Parsed \(result.count) points")
            return result
        } catch {
            print("[PlayCanvasCompressedPLYReader] Layout 2 failed: \(error.localizedDescription)")
            // Both layouts failed
            throw CompressedPLYSceneReader.Error.invalidFileStructure(
                "File size: \(data.count) bytes, offset after header: \(offset). " +
                "Could not parse as compressed PLY (tried both layout formats). " +
                "Layout 1 error: \(error.localizedDescription)"
            )
        }
    }
    
    /// Parse Layout 1: Point count first, then metadata, then data
    private static func parseLayout1(data: Data, offset: Int) throws -> [SplatScenePoint] {
        var offset = offset
        
        // Read point count (UInt32, little-endian)
        guard data.count >= offset + MemoryLayout<UInt32>.size else {
            throw CompressedPLYSceneReader.Error.invalidFileStructure(
                "Layout1: Not enough data for point count at offset \(offset)"
            )
        }
        
        // Log raw bytes for point count
        let pointCountBytes = data.subdata(in: offset..<(offset + MemoryLayout<UInt32>.size))
        let pointCountHex = pointCountBytes.map { String(format: "%02x", $0) }.joined(separator: " ")
        print("[PlayCanvasCompressedPLYReader] Layout1: Point count bytes (hex) at offset \(offset): \(pointCountHex)")
        
        let pointCount = data.withUnsafeBytes { bytes in
            bytes.load(fromByteOffset: offset, as: UInt32.self)
        }
        print("[PlayCanvasCompressedPLYReader] Layout1: Point count = \(pointCount) (interpreted as UInt32)")
        
        // Sanity check: if point count is unreasonably large, it's probably wrong
        if pointCount > 100_000_000 {
            throw CompressedPLYSceneReader.Error.invalidFileStructure(
                "Layout1: Point count \(pointCount) is unreasonably large, likely wrong format"
            )
        }
        
        offset += MemoryLayout<UInt32>.size
        
        // Read chunk metadata (10 floats)
        guard data.count >= offset + 10 * MemoryLayout<Float>.size else {
            throw CompressedPLYSceneReader.Error.invalidFileStructure(
                "Layout1: Not enough data for metadata at offset \(offset)"
            )
        }
        
        let metadata = try readChunkMetadata(from: data, offset: &offset)
        print("[PlayCanvasCompressedPLYReader] Layout1: Metadata read at offset \(offset)")
        print("[PlayCanvasCompressedPLYReader] Layout1: Position range [\(metadata.positionMin)] to [\(metadata.positionMax)]")
        print("[PlayCanvasCompressedPLYReader] Layout1: Scale range [\(metadata.scaleMin), \(metadata.scaleMax)]")
        print("[PlayCanvasCompressedPLYReader] Layout1: Opacity range [\(metadata.opacityMin), \(metadata.opacityMax)]")
        
        // Each compressed point is:
        // - Position: 3x UInt16 (quantized, 6 bytes)
        // - Scale: 3x UInt8 (quantized log space, 3 bytes)
        // - Rotation: 3x UInt8 (smallest-three quaternion, 3 bytes)
        // - Opacity: 1x UInt8 (quantized logit space, 1 byte)
        // - Color: 3x UInt8 (SH DC coefficients, 3 bytes)
        // Total: 16 bytes per point
        let bytesPerPoint = 16
        let expectedDataSize = Int(pointCount) * bytesPerPoint
        
        print("[PlayCanvasCompressedPLYReader] Layout1: Need \(expectedDataSize) bytes for \(pointCount) points, have \(data.count - offset) bytes remaining")
        
        guard data.count >= offset + expectedDataSize else {
            throw CompressedPLYSceneReader.Error.invalidFileStructure(
                "Layout1: Not enough data for \(pointCount) points. Need \(expectedDataSize) bytes, have \(data.count - offset)"
            )
        }
        
        var points: [SplatScenePoint] = []
        points.reserveCapacity(Int(pointCount))
        
        for _ in 0..<Int(pointCount) {
            let point = try readCompressedPoint(
                from: data,
                offset: &offset,
                metadata: metadata
            )
            points.append(point)
        }
        
        return points
    }
    
    /// Parse Layout 2: Metadata first, then point count, then data
    private static func parseLayout2(data: Data, offset: Int) throws -> [SplatScenePoint] {
        var offset = offset
        
        // Read chunk metadata first (10 floats)
        guard data.count >= offset + 10 * MemoryLayout<Float>.size else {
            throw CompressedPLYSceneReader.Error.invalidFileStructure(
                "Layout2: Not enough data for metadata at offset \(offset)"
            )
        }
        
        let metadata = try readChunkMetadata(from: data, offset: &offset)
        print("[PlayCanvasCompressedPLYReader] Layout2: Metadata read at offset \(offset)")
        print("[PlayCanvasCompressedPLYReader] Layout2: Position range [\(metadata.positionMin)] to [\(metadata.positionMax)]")
        print("[PlayCanvasCompressedPLYReader] Layout2: Scale range [\(metadata.scaleMin), \(metadata.scaleMax)]")
        print("[PlayCanvasCompressedPLYReader] Layout2: Opacity range [\(metadata.opacityMin), \(metadata.opacityMax)]")
        
        // Read point count (UInt32, little-endian)
        guard data.count >= offset + MemoryLayout<UInt32>.size else {
            throw CompressedPLYSceneReader.Error.invalidFileStructure(
                "Layout2: Not enough data for point count at offset \(offset)"
            )
        }
        
        // Log raw bytes for point count
        let pointCountBytes = data.subdata(in: offset..<(offset + MemoryLayout<UInt32>.size))
        let pointCountHex = pointCountBytes.map { String(format: "%02x", $0) }.joined(separator: " ")
        print("[PlayCanvasCompressedPLYReader] Layout2: Point count bytes (hex) at offset \(offset): \(pointCountHex)")
        
        let pointCount = data.withUnsafeBytes { bytes in
            bytes.load(fromByteOffset: offset, as: UInt32.self)
        }
        print("[PlayCanvasCompressedPLYReader] Layout2: Point count = \(pointCount) (interpreted as UInt32)")
        
        // Sanity check: if point count is unreasonably large, it's probably wrong
        if pointCount > 100_000_000 {
            throw CompressedPLYSceneReader.Error.invalidFileStructure(
                "Layout2: Point count \(pointCount) is unreasonably large, likely wrong format"
            )
        }
        
        offset += MemoryLayout<UInt32>.size
        
        // Each compressed point is 16 bytes
        let bytesPerPoint = 16
        let expectedDataSize = Int(pointCount) * bytesPerPoint
        
        guard data.count >= offset + expectedDataSize else {
            throw CompressedPLYSceneReader.Error.invalidFileStructure(
                "Layout2: Not enough data for \(pointCount) points. Need \(expectedDataSize) bytes, have \(data.count - offset)"
            )
        }
        
        var points: [SplatScenePoint] = []
        points.reserveCapacity(Int(pointCount))
        
        for _ in 0..<Int(pointCount) {
            let point = try readCompressedPoint(
                from: data,
                offset: &offset,
                metadata: metadata
            )
            points.append(point)
        }
        
        return points
    }
    
    /// Read chunk metadata from binary data
    private static func readChunkMetadata(from data: Data, offset: inout Int) throws -> ChunkMetadata {
        let metadataStartOffset = offset
        
        // Log first few floats to see if they're reasonable
        let firstFloatBytes = data.subdata(in: offset..<(offset + MemoryLayout<Float>.size))
        let firstFloatHex = firstFloatBytes.map { String(format: "%02x", $0) }.joined(separator: " ")
        print("[PlayCanvasCompressedPLYReader] Metadata starts at offset \(offset), first float bytes: \(firstFloatHex)")
        
        let positionMin = SIMD3<Float>(
            x: readFloat(from: data, offset: &offset),
            y: readFloat(from: data, offset: &offset),
            z: readFloat(from: data, offset: &offset)
        )
        
        let positionMax = SIMD3<Float>(
            x: readFloat(from: data, offset: &offset),
            y: readFloat(from: data, offset: &offset),
            z: readFloat(from: data, offset: &offset)
        )
        
        let scaleMin = readFloat(from: data, offset: &offset)
        let scaleMax = readFloat(from: data, offset: &offset)
        let opacityMin = readFloat(from: data, offset: &offset)
        let opacityMax = readFloat(from: data, offset: &offset)
        
        // Log metadata values for debugging
        print("[PlayCanvasCompressedPLYReader] Metadata read from offset \(metadataStartOffset) to \(offset):")
        print("  positionMin: \(positionMin)")
        print("  positionMax: \(positionMax)")
        print("  scaleMin: \(scaleMin), scaleMax: \(scaleMax)")
        print("  opacityMin: \(opacityMin), opacityMax: \(opacityMax)")
        
        return ChunkMetadata(
            positionMin: positionMin,
            positionMax: positionMax,
            scaleMin: scaleMin,
            scaleMax: scaleMax,
            opacityMin: opacityMin,
            opacityMax: opacityMax
        )
    }
    
    /// Read a single compressed point from binary data
    private static func readCompressedPoint(
        from data: Data,
        offset: inout Int,
        metadata: ChunkMetadata
    ) throws -> SplatScenePoint {
        // Read position (3x UInt16, quantized)
        let posX = readUInt16(from: data, offset: &offset)
        let posY = readUInt16(from: data, offset: &offset)
        let posZ = readUInt16(from: data, offset: &offset)
        
        let position = SIMD3<Float>(
            x: dequantizeUInt16(posX, min: metadata.positionMin.x, max: metadata.positionMax.x),
            y: dequantizeUInt16(posY, min: metadata.positionMin.y, max: metadata.positionMax.y),
            z: dequantizeUInt16(posZ, min: metadata.positionMin.z, max: metadata.positionMax.z)
        )
        
        // Read scale (3x UInt8, quantized log space [-20, 20])
        let scaleX = readUInt8(from: data, offset: &offset)
        let scaleY = readUInt8(from: data, offset: &offset)
        let scaleZ = readUInt8(from: data, offset: &offset)
        
        let scale = SIMD3<Float>(
            x: dequantizeUInt8(scaleX, min: metadata.scaleMin, max: metadata.scaleMax),
            y: dequantizeUInt8(scaleY, min: metadata.scaleMin, max: metadata.scaleMax),
            z: dequantizeUInt8(scaleZ, min: metadata.scaleMin, max: metadata.scaleMax)
        )
        
        // Read rotation (3x UInt8, smallest-three quaternion encoding)
        let rot0 = readUInt8(from: data, offset: &offset)
        let rot1 = readUInt8(from: data, offset: &offset)
        let rot2 = readUInt8(from: data, offset: &offset)
        
        let rotation = decodeSmallestThreeQuaternion(
            q0: rot0,
            q1: rot1,
            q2: rot2
        )
        
        // Read opacity (1x UInt8, quantized logit space)
        let opacityQuantized = readUInt8(from: data, offset: &offset)
        let opacity = dequantizeUInt8(opacityQuantized, min: metadata.opacityMin, max: metadata.opacityMax)
        
        // Read color (3x UInt8, SH DC coefficients)
        let colorR = readUInt8(from: data, offset: &offset)
        let colorG = readUInt8(from: data, offset: &offset)
        let colorB = readUInt8(from: data, offset: &offset)
        
        // Convert quantized color to float (SH coefficients typically in [-1, 1] range)
        let sh0 = SIMD3<Float>(
            x: dequantizeUInt8(colorR, min: -1.0, max: 1.0),
            y: dequantizeUInt8(colorG, min: -1.0, max: 1.0),
            z: dequantizeUInt8(colorB, min: -1.0, max: 1.0)
        )
        
        return SplatScenePoint(
            position: position,
            color: .sphericalHarmonic([sh0]),
            opacity: .logitFloat(opacity),
            scale: .exponent(scale),
            rotation: rotation
        )
    }
    
    /// Decode smallest-three quaternion encoding
    /// The 3 bytes represent the 3 smallest components
    /// We need to determine which component is largest and reconstruct it
    private static func decodeSmallestThreeQuaternion(
        q0: UInt8,
        q1: UInt8,
        q2: UInt8
    ) -> simd_quatf {
        // Dequantize from [0, 255] to [-1, 1]
        let q0f = dequantizeUInt8(q0, min: -1.0, max: 1.0)
        let q1f = dequantizeUInt8(q1, min: -1.0, max: 1.0)
        let q2f = dequantizeUInt8(q2, min: -1.0, max: 1.0)
        
        // In smallest-three encoding, we store the 3 smallest components
        // The largest component is reconstructed from: q_largest^2 = 1 - (q0^2 + q1^2 + q2^2)
        let q0sq = q0f * q0f
        let q1sq = q1f * q1f
        let q2sq = q2f * q2f
        let sumSq = q0sq + q1sq + q2sq
        
        guard sumSq < 1.0 else {
            // Invalid quaternion, return identity
            return simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
        }
        
        let q3sq = 1.0 - sumSq
        let q3 = sqrt(max(0, q3sq))
        
        // Determine which of the 4 components is largest
        // The stored components are the 3 smallest, so the largest is the one we calculate
        // But we need to figure out which position it goes in
        // Try all 4 positions and pick the one that gives valid quaternion
        let candidates: [simd_quatf] = [
            simd_quatf(ix: q3, iy: q0f, iz: q1f, r: q2f),  // w is largest
            simd_quatf(ix: q0f, iy: q3, iz: q1f, r: q2f),  // x is largest
            simd_quatf(ix: q0f, iy: q1f, iz: q3, r: q2f),  // y is largest
            simd_quatf(ix: q0f, iy: q1f, iz: q2f, r: q3)   // z is largest
        ]
        
        // Find the candidate with largest absolute component matching our calculated value
        // Typically the largest component is w (real part) for normalized quaternions
        var bestQuat = candidates[0]
        var bestScore = abs(bestQuat.real)
        
        for candidate in candidates {
            let score = max(abs(candidate.real), abs(candidate.imag.x), abs(candidate.imag.y), abs(candidate.imag.z))
            if score > bestScore {
                bestScore = score
                bestQuat = candidate
            }
        }
        
        return bestQuat.normalized
    }
    
    // MARK: - Binary Reading Helpers
    
    private static func readFloat(from data: Data, offset: inout Int) -> Float {
        let value = data.withUnsafeBytes { bytes in
            bytes.load(fromByteOffset: offset, as: Float.self)
        }
        offset += MemoryLayout<Float>.size
        return value
    }
    
    private static func readUInt32(from data: Data, offset: inout Int) -> UInt32 {
        let value = data.withUnsafeBytes { bytes in
            bytes.load(fromByteOffset: offset, as: UInt32.self)
        }
        offset += MemoryLayout<UInt32>.size
        return value
    }
    
    private static func readUInt16(from data: Data, offset: inout Int) -> UInt16 {
        let value = data.withUnsafeBytes { bytes in
            bytes.load(fromByteOffset: offset, as: UInt16.self)
        }
        offset += MemoryLayout<UInt16>.size
        return value
    }
    
    private static func readUInt8(from data: Data, offset: inout Int) -> UInt8 {
        let value = data[offset]
        offset += MemoryLayout<UInt8>.size
        return value
    }
    
    // MARK: - Dequantization
    
    private static func dequantizeUInt8(_ value: UInt8, min: Float, max: Float) -> Float {
        let normalized = Float(value) * (1.0 / 255.0)
        return min + normalized * (max - min)
    }
    
    private static func dequantizeUInt16(_ value: UInt16, min: Float, max: Float) -> Float {
        let normalized = Float(value) * (1.0 / 65535.0)
        return min + normalized * (max - min)
    }
}

