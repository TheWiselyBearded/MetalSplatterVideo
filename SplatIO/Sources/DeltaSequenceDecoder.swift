import Foundation
import Compression
import simd

/// Decodes delta-encoded Gaussian splat sequences.
///
/// The encoder outputs:
/// - Keyframe files (keyframe_*.ply.gz): Full Gaussian splat frames saved periodically
/// - Delta file (deltas.npz): Compressed delta encodings for non-keyframe frames
///
/// Each delta stores differences (positions, scales, rotations, colors, opacities) between
/// a frame and its reference keyframe, along with spatial matching indices.
public class DeltaSequenceDecoder {
    
    public enum Error: LocalizedError {
        case noKeyframesFound
        case noDeltaFileFound
        case invalidNPZFormat
        case invalidNPYFormat(String)
        case decompressionFailed
        case invalidDeltaData(String)
        case keyframeLoadFailed(Int, Swift.Error?)
        
        public var errorDescription: String? {
            switch self {
            case .noKeyframesFound:
                return "No keyframe files (keyframe_*.ply.gz) found in directory"
            case .noDeltaFileFound:
                return "No delta file (deltas.npz) found in directory"
            case .invalidNPZFormat:
                return "Invalid NPZ file format"
            case .invalidNPYFormat(let detail):
                return "Invalid NPY array format: \(detail)"
            case .decompressionFailed:
                return "Failed to decompress gzip file"
            case .invalidDeltaData(let detail):
                return "Invalid delta data: \(detail)"
            case .keyframeLoadFailed(let index, let error):
                return "Failed to load keyframe \(index): \(error?.localizedDescription ?? "unknown error")"
            }
        }
    }
    
    /// Represents a decoded delta frame
    public struct DeltaFrame {
        public let frameIndex: Int
        public let baseFrameIndex: Int
        public let deltaMean: [[Float]]           // [N, 3] positions
        public let deltaScales: [[Float]]         // [N, 3] scales
        public let deltaQuaternions: [[Float]]    // [N, 4] rotations
        public let deltaColors: [[Float]]         // [N, 3 or more] colors (SH coefficients)
        public let deltaOpacities: [Float]        // [N] opacities
        public let baseMatchIndices: [Int32]?     // Indices in base keyframe
        public let currentMatchIndices: [Int32]?  // Indices in current frame
        public let changedIndices: [Int32]?       // Sparse encoding: which indices changed
        public let isNewGaussian: [Bool]?         // Which deltas are new vs matched
    }
    
    /// Decoded keyframe with its frame index
    public struct KeyframeData {
        public let frameIndex: Int
        public let points: [SplatScenePoint]
    }
    
    private let directoryURL: URL
    
    // Store keyframe URLs instead of loaded data
    private var keyframeURLs: [Int: URL] = [:]
    private var keyframeIndices: Set<Int> = []
    
    // Store NPY arrays (raw) instead of parsed DeltaFrame objects
    private var deltaNPZArrays: [String: NPYArray] = [:]
    private var deltaFrameMetadata: [Int: (frameIndex: Int, baseIndex: Int, prefix: String)] = [:]
    
    private var allFrameIndices: [Int] = []
    
    // Small cache for recently used keyframes (keep at most 1 in memory)
    private var keyframeCache: (index: Int, points: [SplatScenePoint])?
    
    public init(directoryURL: URL) {
        self.directoryURL = directoryURL
    }
    
    /// Total number of frames in the sequence
    public var frameCount: Int {
        allFrameIndices.count
    }
    
    /// Get sorted frame indices
    public var frameIndices: [Int] {
        allFrameIndices
    }
    
    /// Check if directory contains a valid delta sequence
    public static func isValidDeltaSequenceDirectory(_ url: URL) -> Bool {
        let fileManager = FileManager.default
        
        // Check for keyframe files
        let hasKeyframes: Bool
        if let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]) {
            hasKeyframes = enumerator.contains { item in
                guard let fileURL = item as? URL else { return false }
                return fileURL.lastPathComponent.hasPrefix("keyframe_") &&
                       (fileURL.pathExtension == "gz" || fileURL.lastPathComponent.contains(".ply"))
            }
        } else {
            hasKeyframes = false
        }
        
        // Check for delta file
        let deltasPath = url.appendingPathComponent("deltas.npz")
        let hasDeltaFile = fileManager.fileExists(atPath: deltasPath.path)
        
        return hasKeyframes && hasDeltaFile
    }
    
    /// Load metadata only (keyframe URLs and delta NPZ arrays) - doesn't load actual frame data
    public func load() async throws {
        try await discoverKeyframes()
        try loadDeltaMetadata()
        buildFrameIndex()
    }
    
    /// Get reconstructed points for a specific frame index (loads on-demand)
    public func getFrame(at index: Int) async throws -> [SplatScenePoint] {
        // Check if it's a keyframe
        if keyframeIndices.contains(index) {
            return try await loadKeyframe(onDemand: index)
        }
        
        // Find the delta metadata for this frame
        guard let deltaMeta = deltaFrameMetadata[index] else {
            throw Error.invalidDeltaData("No data found for frame \(index)")
        }
        
        // Load the base keyframe on-demand
        let basePoints = try await loadKeyframe(onDemand: deltaMeta.baseIndex)
        
        // Parse and apply delta on-demand
        let delta = try parseDeltaFrame(prefix: deltaMeta.prefix, frameIndex: deltaMeta.frameIndex, baseIndex: deltaMeta.baseIndex)
        
        // Reconstruct the frame
        return try applyDelta(delta, to: basePoints)
    }
    
    // MARK: - Private Implementation
    
    /// Discover keyframe files and store URLs (doesn't load data)
    private func discoverKeyframes() async throws {
        let fileManager = FileManager.default
        
        guard let enumerator = fileManager.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else {
            throw Error.noKeyframesFound
        }
        
        var discoveredURLs: [(Int, URL)] = []
        
        for case let fileURL as URL in enumerator {
            let filename = fileURL.lastPathComponent
            if filename.hasPrefix("keyframe_") {
                // Extract frame index from filename like "keyframe_0.ply.gz" or "keyframe_10.ply"
                let stem = filename
                    .replacingOccurrences(of: "keyframe_", with: "")
                    .replacingOccurrences(of: ".ply.gz", with: "")
                    .replacingOccurrences(of: ".ply", with: "")
                    .replacingOccurrences(of: ".gz", with: "")
                
                if let frameIndex = Int(stem) {
                    discoveredURLs.append((frameIndex, fileURL))
                }
            }
        }
        
        guard !discoveredURLs.isEmpty else {
            throw Error.noKeyframesFound
        }
        
        // Store URLs only
        for (frameIndex, url) in discoveredURLs {
            keyframeURLs[frameIndex] = url
            keyframeIndices.insert(frameIndex)
        }
        
        print("📦 Discovered \(keyframeURLs.count) keyframes: \(keyframeIndices.sorted())")
    }
    
    /// Load a keyframe on-demand
    private func loadKeyframe(onDemand index: Int) async throws -> [SplatScenePoint] {
        // Check cache first
        if let cached = keyframeCache, cached.index == index {
            return cached.points
        }
        
        guard let url = keyframeURLs[index] else {
            throw Error.invalidDeltaData("Keyframe \(index) not found")
        }
        
        // Load the keyframe
        let points = try await loadKeyframe(at: url)
        
        // Update cache (evict previous)
        keyframeCache = (index: index, points: points)
        
        return points
    }
    
    private func loadKeyframe(at url: URL) async throws -> [SplatScenePoint] {
        let data: Data
        
        if url.pathExtension == "gz" {
            // Decompress gzip
            let compressedData = try Data(contentsOf: url)
            guard let decompressed = decompressGzip(compressedData) else {
                throw Error.decompressionFailed
            }
            data = decompressed
        } else {
            data = try Data(contentsOf: url)
        }
        
        // Write to temp file and use existing PLY reader
        let tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("ply")
        
        defer {
            try? FileManager.default.removeItem(at: tempURL)
        }
        
        try data.write(to: tempURL)
        
        var buffer = SplatMemoryBuffer()
        try await buffer.read(from: SplatPLYSceneReader(tempURL))
        return buffer.points
    }
    
    /// Load NPZ file and store raw NPY arrays (doesn't parse to Swift types)
    private func loadDeltaMetadata() throws {
        let deltasURL = directoryURL.appendingPathComponent("deltas.npz")
        
        guard FileManager.default.fileExists(atPath: deltasURL.path) else {
            throw Error.noDeltaFileFound
        }
        
        let npzData = try Data(contentsOf: deltasURL)
        let arrays = try parseNPZ(npzData)
        
        // Store all NPY arrays (raw data)
        deltaNPZArrays = arrays
        
        // Find all frame indices and parse only metadata (indices, not arrays)
        var frameIndicesSet = Set<Int>()
        for key in arrays.keys {
            if key.hasPrefix("frame_") && key.contains("_frame_idx") {
                let parts = key.split(separator: "_")
                if parts.count >= 2, let idx = Int(parts[1]) {
                    frameIndicesSet.insert(idx)
                }
            }
        }
        
        let sortedFrameIndices = frameIndicesSet.sorted()
        print("📊 Found \(sortedFrameIndices.count) delta frames in NPZ")
        
        // Parse only frame indices and base indices (metadata), not the actual arrays
        for frameIdx in sortedFrameIndices {
            let prefix = "frame_\(frameIdx)"
            
            guard let frameIdxArray = arrays["\(prefix)_frame_idx"],
                  let baseIdxArray = arrays["\(prefix)_base_idx"] else {
                print("⚠️ Missing frame_idx or base_idx for frame \(frameIdx)")
                continue
            }
            
            // Parse only indices (small metadata)
            let frameIndex: Int
            let baseIndex: Int
            do {
                frameIndex = try parseIntValue(frameIdxArray)
                baseIndex = try parseIntValue(baseIdxArray)
                
                // Store metadata only
                deltaFrameMetadata[frameIndex] = (frameIndex: frameIndex, baseIndex: baseIndex, prefix: prefix)
            } catch {
                print("⚠️ Failed to parse indices for frame \(frameIdx): \(error)")
                continue
            }
        }
        
        print("📊 Indexed \(deltaFrameMetadata.count) delta frames")
    }
    
    /// Parse a single delta frame from NPY arrays on-demand
    private func parseDeltaFrame(prefix: String, frameIndex: Int, baseIndex: Int) throws -> DeltaFrame {
        // Load delta arrays from stored NPY arrays
        guard let meanArray = deltaNPZArrays["\(prefix)_mean"],
              let scalesArray = deltaNPZArrays["\(prefix)_scales"],
              let quatsArray = deltaNPZArrays["\(prefix)_quats"],
              let colorsArray = deltaNPZArrays["\(prefix)_colors"],
              let opacitiesArray = deltaNPZArrays["\(prefix)_opacities"] else {
            throw Error.invalidDeltaData("Missing required arrays for prefix \(prefix)")
        }
        
        // Parse arrays into Swift types on-demand
        let deltaMean = try parseFloat2DArray(meanArray)
        let deltaScales = try parseFloat2DArray(scalesArray)
        let deltaQuats = try parseFloat2DArray(quatsArray)
        let deltaColors = try parseFloat2DArray(colorsArray)
        let deltaOpacities = try parseFloat1DArray(opacitiesArray)
        
        // Optional matching indices
        var baseMatchIndices: [Int32]? = nil
        var currentMatchIndices: [Int32]? = nil
        var changedIndices: [Int32]? = nil
        var isNewGaussian: [Bool]? = nil
        
        if let baseMatchArray = deltaNPZArrays["\(prefix)_base_match"] {
            baseMatchIndices = try? parseInt32Array(baseMatchArray)
        }
        if let currentMatchArray = deltaNPZArrays["\(prefix)_current_match"] {
            currentMatchIndices = try? parseInt32Array(currentMatchArray)
        }
        if let changedArray = deltaNPZArrays["\(prefix)_changed"] {
            changedIndices = try? parseInt32Array(changedArray)
        }
        if let isNewArray = deltaNPZArrays["\(prefix)_is_new"] {
            isNewGaussian = try? parseBoolArray(isNewArray)
        }
        
        return DeltaFrame(
            frameIndex: frameIndex,
            baseFrameIndex: baseIndex,
            deltaMean: deltaMean,
            deltaScales: deltaScales,
            deltaQuaternions: deltaQuats,
            deltaColors: deltaColors,
            deltaOpacities: deltaOpacities,
            baseMatchIndices: baseMatchIndices,
            currentMatchIndices: currentMatchIndices,
            changedIndices: changedIndices,
            isNewGaussian: isNewGaussian
        )
    }
    
    private func buildFrameIndex() {
        var indices = Set<Int>()
        
        // Add keyframe indices
        indices.formUnion(keyframeIndices)
        
        // Add delta frame indices
        indices.formUnion(deltaFrameMetadata.keys)
        
        allFrameIndices = indices.sorted()
        print("📊 Total frames in sequence: \(allFrameIndices.count)")
    }
    
    private func applyDelta(_ delta: DeltaFrame, to basePoints: [SplatScenePoint]) throws -> [SplatScenePoint] {
        let numDeltas = delta.deltaMean.count
        
        if let baseMatchIndices = delta.baseMatchIndices,
           let isNewGaussian = delta.isNewGaussian {
            // Spatial matching mode with new Gaussians
            var resultPoints: [SplatScenePoint] = []
            
            var matchedDeltaIdx = 0
            var newDeltaIdx = 0
            
            for i in 0..<numDeltas {
                if isNewGaussian[i] {
                    // New Gaussian - use delta values directly as full values
                    let point = createPointFromDelta(delta, at: i, isNew: true)
                    resultPoints.append(point)
                    newDeltaIdx += 1
                } else {
                    // Matched Gaussian - apply delta to base
                    let baseIdx = Int(baseMatchIndices[matchedDeltaIdx])
                    guard baseIdx < basePoints.count else {
                        throw Error.invalidDeltaData("Base index \(baseIdx) out of range")
                    }
                    let basePoint = basePoints[baseIdx]
                    let point = applyDeltaToPoint(delta, at: i, base: basePoint)
                    resultPoints.append(point)
                    matchedDeltaIdx += 1
                }
            }
            
            return resultPoints
            
        } else if let baseMatchIndices = delta.baseMatchIndices {
            // Spatial matching mode without new Gaussians
            var resultPoints: [SplatScenePoint] = []
            
            for i in 0..<numDeltas {
                let baseIdx = Int(baseMatchIndices[i])
                guard baseIdx < basePoints.count else {
                    throw Error.invalidDeltaData("Base index \(baseIdx) out of range")
                }
                let basePoint = basePoints[baseIdx]
                let point = applyDeltaToPoint(delta, at: i, base: basePoint)
                resultPoints.append(point)
            }
            
            return resultPoints
            
        } else if let changedIndices = delta.changedIndices {
            // Sparse delta - only update changed indices
            var resultPoints = basePoints
            
            for (deltaIdx, changedIdx) in changedIndices.enumerated() {
                let idx = Int(changedIdx)
                guard idx < resultPoints.count else {
                    throw Error.invalidDeltaData("Changed index \(idx) out of range")
                }
                resultPoints[idx] = applyDeltaToPoint(delta, at: deltaIdx, base: resultPoints[idx])
            }
            
            return resultPoints
            
        } else {
            // Dense delta - apply to all (index-based matching)
            guard numDeltas == basePoints.count else {
                throw Error.invalidDeltaData("Delta count (\(numDeltas)) doesn't match base count (\(basePoints.count))")
            }
            
            var resultPoints: [SplatScenePoint] = []
            for i in 0..<numDeltas {
                let point = applyDeltaToPoint(delta, at: i, base: basePoints[i])
                resultPoints.append(point)
            }
            
            return resultPoints
        }
    }
    
    private func applyDeltaToPoint(_ delta: DeltaFrame, at index: Int, base: SplatScenePoint) -> SplatScenePoint {
        // Position: base + delta
        let newPosition = SIMD3<Float>(
            base.position.x + delta.deltaMean[index][0],
            base.position.y + delta.deltaMean[index][1],
            base.position.z + delta.deltaMean[index][2]
        )
        
        // Scale: base (as exponent) + delta
        let baseScale = base.scale.asExponent
        let newScale: SplatScenePoint.Scale = .exponent(SIMD3<Float>(
            baseScale.x + delta.deltaScales[index][0],
            baseScale.y + delta.deltaScales[index][1],
            baseScale.z + delta.deltaScales[index][2]
        ))
        
        // Rotation: base + delta (quaternion addition for small deltas)
        let newRotation = simd_quatf(
            ix: base.rotation.imag.x + delta.deltaQuaternions[index][1],
            iy: base.rotation.imag.y + delta.deltaQuaternions[index][2],
            iz: base.rotation.imag.z + delta.deltaQuaternions[index][3],
            r: base.rotation.real + delta.deltaQuaternions[index][0]
        ).normalized
        
        // Color: base (as SH) + delta
        let baseSH = base.color.asSphericalHarmonic
        let newColor: SplatScenePoint.Color
        if delta.deltaColors[index].count >= 3 {
            let deltaSH = SIMD3<Float>(
                delta.deltaColors[index][0],
                delta.deltaColors[index][1],
                delta.deltaColors[index][2]
            )
            if !baseSH.isEmpty {
                let newSH = baseSH[0] + deltaSH
                newColor = .sphericalHarmonic([newSH])
            } else {
                newColor = .sphericalHarmonic([deltaSH])
            }
        } else {
            newColor = base.color
        }
        
        // Opacity: base (as logit) + delta
        let baseOpacity = base.opacity.asLogitFloat
        let newOpacity: SplatScenePoint.Opacity = .logitFloat(baseOpacity + delta.deltaOpacities[index])
        
        return SplatScenePoint(
            position: newPosition,
            color: newColor,
            opacity: newOpacity,
            scale: newScale,
            rotation: newRotation
        )
    }
    
    private func createPointFromDelta(_ delta: DeltaFrame, at index: Int, isNew: Bool) -> SplatScenePoint {
        // For new Gaussians, delta values are full values not differences
        let position = SIMD3<Float>(
            delta.deltaMean[index][0],
            delta.deltaMean[index][1],
            delta.deltaMean[index][2]
        )
        
        let scale: SplatScenePoint.Scale = .exponent(SIMD3<Float>(
            delta.deltaScales[index][0],
            delta.deltaScales[index][1],
            delta.deltaScales[index][2]
        ))
        
        let rotation = simd_quatf(
            ix: delta.deltaQuaternions[index][1],
            iy: delta.deltaQuaternions[index][2],
            iz: delta.deltaQuaternions[index][3],
            r: delta.deltaQuaternions[index][0]
        ).normalized
        
        let color: SplatScenePoint.Color
        if delta.deltaColors[index].count >= 3 {
            let sh = SIMD3<Float>(
                delta.deltaColors[index][0],
                delta.deltaColors[index][1],
                delta.deltaColors[index][2]
            )
            color = .sphericalHarmonic([sh])
        } else {
            color = .linearFloat(.zero)
        }
        
        let opacity: SplatScenePoint.Opacity = .logitFloat(delta.deltaOpacities[index])
        
        return SplatScenePoint(
            position: position,
            color: color,
            opacity: opacity,
            scale: scale,
            rotation: rotation
        )
    }
    
    // MARK: - Gzip Decompression
    
    private func decompressGzip(_ data: Data) -> Data? {
        // Check for gzip magic number
        guard data.count > 10,
              data[0] == 0x1f,
              data[1] == 0x8b else {
            return nil
        }
        
        return data.withUnsafeBytes { (sourcePtr: UnsafeRawBufferPointer) -> Data? in
            // Skip gzip header (minimum 10 bytes)
            var headerSize = 10
            let flags = data[3]
            
            // FEXTRA
            if flags & 0x04 != 0 {
                guard data.count > headerSize + 2 else { return nil }
                let extraLen = Int(data[headerSize]) | (Int(data[headerSize + 1]) << 8)
                headerSize += 2 + extraLen
            }
            
            // FNAME
            if flags & 0x08 != 0 {
                while headerSize < data.count && data[headerSize] != 0 {
                    headerSize += 1
                }
                headerSize += 1
            }
            
            // FCOMMENT
            if flags & 0x10 != 0 {
                while headerSize < data.count && data[headerSize] != 0 {
                    headerSize += 1
                }
                headerSize += 1
            }
            
            // FHCRC
            if flags & 0x02 != 0 {
                headerSize += 2
            }
            
            guard data.count > headerSize + 8 else { return nil }
            
            // Get uncompressed size from last 4 bytes (modulo 2^32)
            let sizeOffset = data.count - 4
            let uncompressedSize = Int(data[sizeOffset]) |
                                   (Int(data[sizeOffset + 1]) << 8) |
                                   (Int(data[sizeOffset + 2]) << 16) |
                                   (Int(data[sizeOffset + 3]) << 24)
            
            // Allocate output buffer (use larger size to handle files > 4GB)
            let outputSize = max(uncompressedSize, data.count * 4)
            var output = Data(count: outputSize)
            
            let compressedData = data.subdata(in: headerSize..<(data.count - 8))
            
            let result = output.withUnsafeMutableBytes { destPtr -> Int in
                compressedData.withUnsafeBytes { srcPtr -> Int in
                    let decompressed = compression_decode_buffer(
                        destPtr.bindMemory(to: UInt8.self).baseAddress!,
                        outputSize,
                        srcPtr.bindMemory(to: UInt8.self).baseAddress!,
                        compressedData.count,
                        nil,
                        COMPRESSION_ZLIB
                    )
                    return decompressed
                }
            }
            
            guard result > 0 else { return nil }
            output.count = result
            return output
        }
    }
    
    // MARK: - NPZ Parsing
    
    private struct NPYArray {
        let shape: [Int]
        let dtype: String
        let data: Data
    }
    
    private func parseNPZ(_ data: Data) throws -> [String: NPYArray] {
        var arrays: [String: NPYArray] = [:]
        
        // NPZ is a ZIP file - parse using central directory for reliable size info
        // First, find the end of central directory record
        var eocdOffset = data.count - 22
        while eocdOffset >= 0 {
            let sig = data.subdata(in: eocdOffset..<eocdOffset+4).withUnsafeBytes { $0.load(as: UInt32.self) }
            if sig == 0x06054b50 {
                break
            }
            eocdOffset -= 1
        }
        
        guard eocdOffset >= 0 else {
            throw Error.invalidNPZFormat
        }
        
        // Read central directory offset
        let cdOffset = Int(data.subdata(in: eocdOffset+16..<eocdOffset+20).withUnsafeBytes { $0.load(as: UInt32.self) })
        let cdEntries = Int(data.subdata(in: eocdOffset+10..<eocdOffset+12).withUnsafeBytes { $0.load(as: UInt16.self) })
        
        // Parse central directory entries
        var cdPos = cdOffset
        for _ in 0..<cdEntries {
            guard cdPos + 46 <= data.count else { break }
            
            let sig = data.subdata(in: cdPos..<cdPos+4).withUnsafeBytes { $0.load(as: UInt32.self) }
            guard sig == 0x02014b50 else { break }
            
            let compMethod = data.subdata(in: cdPos+10..<cdPos+12).withUnsafeBytes { $0.load(as: UInt16.self) }
            var compSize = Int(data.subdata(in: cdPos+20..<cdPos+24).withUnsafeBytes { $0.load(as: UInt32.self) })
            var uncompSize = Int(data.subdata(in: cdPos+24..<cdPos+28).withUnsafeBytes { $0.load(as: UInt32.self) })
            let nameLen = Int(data.subdata(in: cdPos+28..<cdPos+30).withUnsafeBytes { $0.load(as: UInt16.self) })
            let extraLen = Int(data.subdata(in: cdPos+30..<cdPos+32).withUnsafeBytes { $0.load(as: UInt16.self) })
            let commentLen = Int(data.subdata(in: cdPos+32..<cdPos+34).withUnsafeBytes { $0.load(as: UInt16.self) })
            var localHeaderOffset = Int(data.subdata(in: cdPos+42..<cdPos+46).withUnsafeBytes { $0.load(as: UInt32.self) })
            
            guard cdPos + 46 + nameLen <= data.count else { break }
            let nameData = data.subdata(in: cdPos+46..<cdPos+46+nameLen)
            let filename = String(data: nameData, encoding: .utf8) ?? ""
            
            // Handle ZIP64 - check extra field for actual sizes
            if compSize == 0xFFFFFFFF || uncompSize == 0xFFFFFFFF || localHeaderOffset == 0xFFFFFFFF {
                var extraPos = cdPos + 46 + nameLen
                let extraEnd = extraPos + extraLen
                while extraPos + 4 <= extraEnd {
                    let extraId = data.subdata(in: extraPos..<extraPos+2).withUnsafeBytes { $0.load(as: UInt16.self) }
                    let extraSize = Int(data.subdata(in: extraPos+2..<extraPos+4).withUnsafeBytes { $0.load(as: UInt16.self) })
                    
                    if extraId == 0x0001 { // ZIP64 extended info
                        var zip64Pos = extraPos + 4
                        if uncompSize == 0xFFFFFFFF && zip64Pos + 8 <= extraEnd {
                            uncompSize = Int(data.subdata(in: zip64Pos..<zip64Pos+8).withUnsafeBytes { $0.load(as: UInt64.self) })
                            zip64Pos += 8
                        }
                        if compSize == 0xFFFFFFFF && zip64Pos + 8 <= extraEnd {
                            compSize = Int(data.subdata(in: zip64Pos..<zip64Pos+8).withUnsafeBytes { $0.load(as: UInt64.self) })
                            zip64Pos += 8
                        }
                        if localHeaderOffset == 0xFFFFFFFF && zip64Pos + 8 <= extraEnd {
                            localHeaderOffset = Int(data.subdata(in: zip64Pos..<zip64Pos+8).withUnsafeBytes { $0.load(as: UInt64.self) })
                        }
                        break
                    }
                    extraPos += 4 + extraSize
                }
            }
            
            // Move to next central directory entry
            cdPos += 46 + nameLen + extraLen + commentLen
            
            // Only process .npy files
            guard filename.hasSuffix(".npy") else { continue }
            
            // Read local file header to get actual data position
            guard localHeaderOffset + 30 <= data.count else { continue }
            let localNameLen = Int(data.subdata(in: localHeaderOffset+26..<localHeaderOffset+28).withUnsafeBytes { $0.load(as: UInt16.self) })
            let localExtraLen = Int(data.subdata(in: localHeaderOffset+28..<localHeaderOffset+30).withUnsafeBytes { $0.load(as: UInt16.self) })
            
            let dataStart = localHeaderOffset + 30 + localNameLen + localExtraLen
            let dataEnd = dataStart + compSize
            
            guard dataStart >= 0 && dataEnd <= data.count && dataStart <= dataEnd else { continue }
            
            let fileData = data.subdata(in: dataStart..<dataEnd)
            
            // Decompress if needed
            let arrayData: Data
            if compMethod == 0 {
                // Stored (no compression)
                arrayData = fileData
            } else if compMethod == 8 {
                // Deflate
                guard let decompressed = decompressDeflate(fileData, uncompressedSize: uncompSize) else {
                    continue
                }
                arrayData = decompressed
            } else {
                continue
            }
            
            // Parse NPY array
            let arrayName = String(filename.dropLast(4))
            if let npyArray = try? parseNPY(arrayData) {
                arrays[arrayName] = npyArray
            }
        }
        
        return arrays
    }
    
    private func decompressDeflate(_ data: Data, uncompressedSize: Int) -> Data? {
        let outputSize = max(uncompressedSize, data.count * 4)
        var output = Data(count: outputSize)
        
        let result = output.withUnsafeMutableBytes { destPtr -> Int in
            data.withUnsafeBytes { srcPtr -> Int in
                compression_decode_buffer(
                    destPtr.bindMemory(to: UInt8.self).baseAddress!,
                    outputSize,
                    srcPtr.bindMemory(to: UInt8.self).baseAddress!,
                    data.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        
        guard result > 0 else { return nil }
        output.count = result
        return output
    }
    
    private func parseNPY(_ data: Data) throws -> NPYArray {
        // NPY format: magic string, version, header len, header (Python dict), data
        guard data.count > 10 else {
            throw Error.invalidNPYFormat("Data too short")
        }
        
        // Check magic: \x93NUMPY
        guard data[0] == 0x93,
              data[1] == 0x4E, // N
              data[2] == 0x55, // U
              data[3] == 0x4D, // M
              data[4] == 0x50, // P
              data[5] == 0x59  // Y
        else {
            throw Error.invalidNPYFormat("Invalid magic number")
        }
        
        let majorVersion = data[6]
        // let minorVersion = data[7]
        
        let headerLen: Int
        let headerStart: Int
        
        if majorVersion == 1 {
            headerLen = Int(data[8]) | (Int(data[9]) << 8)
            headerStart = 10
        } else if majorVersion == 2 || majorVersion == 3 {
            headerLen = Int(data[8]) |
                       (Int(data[9]) << 8) |
                       (Int(data[10]) << 16) |
                       (Int(data[11]) << 24)
            headerStart = 12
        } else {
            throw Error.invalidNPYFormat("Unsupported version \(majorVersion)")
        }
        
        guard data.count > headerStart + headerLen else {
            throw Error.invalidNPYFormat("Header extends beyond data")
        }
        
        let headerData = data.subdata(in: headerStart..<headerStart+headerLen)
        guard let headerStr = String(data: headerData, encoding: .utf8) else {
            throw Error.invalidNPYFormat("Cannot decode header")
        }
        
        // Parse Python dict-like header: {'descr': '<f4', 'fortran_order': False, 'shape': (3,)}
        let (dtype, shape) = try parseNPYHeader(headerStr)
        
        let dataStart = headerStart + headerLen
        let arrayData = data.subdata(in: dataStart..<data.count)
        
        return NPYArray(shape: shape, dtype: dtype, data: arrayData)
    }
    
    private func parseNPYHeader(_ header: String) throws -> (dtype: String, shape: [Int]) {
        // Simple parser for NPY header: {'descr': '<f4', 'fortran_order': False, 'shape': (3,)}
        var dtype = ""
        var shape: [Int] = []
        
        // Extract dtype - look for 'descr': '...' pattern
        // Try multiple patterns for robustness
        let descrPatterns = [
            "'descr'\\s*:\\s*'([^']+)'",
            "\"descr\"\\s*:\\s*\"([^\"]+)\"",
            "'descr'\\s*:\\s*'(<[^']+)'",
        ]
        
        for pattern in descrPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern),
               let match = regex.firstMatch(in: header, range: NSRange(header.startIndex..., in: header)) {
                if match.numberOfRanges > 1,
                   let range = Range(match.range(at: 1), in: header) {
                    dtype = String(header[range])
                    break
                }
            }
        }
        
        // If regex failed, try simple string search
        if dtype.isEmpty {
            if let descrStart = header.range(of: "'descr':") ?? header.range(of: "\"descr\":") {
                let afterDescr = header[descrStart.upperBound...]
                if let quoteStart = afterDescr.firstIndex(of: "'") ?? afterDescr.firstIndex(of: "\"") {
                    let quoteChar = afterDescr[quoteStart]
                    let afterQuote = afterDescr[afterDescr.index(after: quoteStart)...]
                    if let quoteEnd = afterQuote.firstIndex(of: quoteChar) {
                        dtype = String(afterDescr[afterDescr.index(after: quoteStart)..<quoteEnd])
                    }
                }
            }
        }
        
        // Extract shape - look for 'shape': (...) pattern
        if let shapeStart = header.range(of: "'shape':") ?? header.range(of: "\"shape\":") {
            let afterShape = header[shapeStart.upperBound...]
            if let parenStart = afterShape.firstIndex(of: "("),
               let parenEnd = afterShape.firstIndex(of: ")") {
                let shapeStr = afterShape[afterShape.index(after: parenStart)..<parenEnd]
                shape = shapeStr.split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                    .compactMap { Int($0) }
            }
        }
        
        if dtype.isEmpty {
            throw Error.invalidNPYFormat("Could not parse dtype from header: \(header)")
        }
        
        return (dtype, shape)
    }
    
    // MARK: - Array Parsing Helpers
    
    private func parseFloat2DArray(_ array: NPYArray) throws -> [[Float]] {
        let dtype = array.dtype.lowercased()
        let isFloat32 = dtype.contains("f4") || dtype.contains("float32") || dtype == "<f4" || dtype == ">f4"
        let isFloat16 = dtype.contains("f2") || dtype.contains("float16") || dtype == "<f2" || dtype == ">f2"
        let isFloat64 = dtype.contains("f8") || dtype.contains("float64") || dtype == "<f8" || dtype == ">f8"
        
        guard isFloat32 || isFloat16 || isFloat64 else {
            throw Error.invalidNPYFormat("Unsupported float dtype: \(dtype) for 2D array")
        }
        
        let shape = array.shape
        
        // Handle scalar case
        if shape.isEmpty {
            let values = try parseFloatArray(array.data, count: 1, dtype: dtype)
            return [values]
        }
        
        // Handle 1D case (add extra dimension)
        if shape.count == 1 {
            let count = shape[0]
            let values = try parseFloatArray(array.data, count: count, dtype: dtype)
            return values.map { [$0] }
        }
        
        // For 3D arrays (e.g., [1, N, 3]), flatten the first dimension
        let rows: Int
        let cols: Int
        if shape.count == 3 {
            rows = shape[0] * shape[1]
            cols = shape[2]
        } else {
            rows = shape[0]
            cols = shape[1]
        }
        
        let totalCount = rows * cols
        let values = try parseFloatArray(array.data, count: totalCount, dtype: dtype)
        
        var result: [[Float]] = []
        for i in 0..<rows {
            var row: [Float] = []
            for j in 0..<cols {
                let idx = i * cols + j
                if idx < values.count {
                    row.append(values[idx])
                } else {
                    row.append(0)
                }
            }
            result.append(row)
        }
        
        return result
    }
    
    private func parseFloat1DArray(_ array: NPYArray) throws -> [Float] {
        let shape = array.shape
        let count: Int
        
        if shape.isEmpty {
            count = 1
        } else if shape.count == 1 {
            count = shape[0]
        } else {
            // Flatten any multi-dimensional array
            count = shape.reduce(1, *)
        }
        
        return try parseFloatArray(array.data, count: count, dtype: array.dtype)
    }
    
    private func parseFloatArray(_ data: Data, count: Int, dtype: String) throws -> [Float] {
        let dtypeLower = dtype.lowercased()
        let isFloat32 = dtypeLower.contains("f4") || dtypeLower.contains("float32")
        let isFloat16 = dtypeLower.contains("f2") || dtypeLower.contains("float16")
        let isFloat64 = dtypeLower.contains("f8") || dtypeLower.contains("float64")
        
        var values: [Float] = []
        values.reserveCapacity(count)
        
        if isFloat32 {
            let bytesPerElement = 4
            let maxElements = data.count / bytesPerElement
            data.withUnsafeBytes { ptr in
                let floatPtr = ptr.bindMemory(to: Float.self)
                for i in 0..<min(count, maxElements) {
                    values.append(floatPtr[i])
                }
            }
        } else if isFloat64 {
            let bytesPerElement = 8
            let maxElements = data.count / bytesPerElement
            data.withUnsafeBytes { ptr in
                let doublePtr = ptr.bindMemory(to: Double.self)
                for i in 0..<min(count, maxElements) {
                    values.append(Float(doublePtr[i]))
                }
            }
        } else if isFloat16 {
            let bytesPerElement = 2
            let maxElements = data.count / bytesPerElement
            data.withUnsafeBytes { ptr in
                let uint16Ptr = ptr.bindMemory(to: UInt16.self)
                for i in 0..<min(count, maxElements) {
                    values.append(float16ToFloat32(uint16Ptr[i]))
                }
            }
        } else {
            throw Error.invalidNPYFormat("Unsupported float dtype: \(dtype)")
        }
        
        // Pad with zeros if needed
        while values.count < count {
            values.append(0)
        }
        
        return values
    }
    
    private func parseInt32Array(_ array: NPYArray) throws -> [Int32] {
        let data = array.data
        let dtype = array.dtype.lowercased()
        
        let count: Int
        if array.shape.isEmpty {
            count = 1
        } else {
            count = array.shape.reduce(1, *)
        }
        
        var values: [Int32] = []
        values.reserveCapacity(count)
        
        // Check for various integer types
        let isInt32 = dtype.contains("i4") || dtype.contains("int32") || dtype == "<i4" || dtype == ">i4"
        let isInt64 = dtype.contains("i8") || dtype.contains("int64") || dtype == "<i8" || dtype == ">i8"
        let isInt16 = dtype.contains("i2") || dtype.contains("int16") || dtype == "<i2" || dtype == ">i2"
        let isUInt32 = dtype.contains("u4") || dtype.contains("uint32")
        let isUInt64 = dtype.contains("u8") || dtype.contains("uint64")
        
        if isInt32 {
            data.withUnsafeBytes { ptr in
                let intPtr = ptr.bindMemory(to: Int32.self)
                for i in 0..<min(count, intPtr.count) {
                    values.append(intPtr[i])
                }
            }
        } else if isInt64 {
            data.withUnsafeBytes { ptr in
                let intPtr = ptr.bindMemory(to: Int64.self)
                for i in 0..<min(count, intPtr.count) {
                    values.append(Int32(clamping: intPtr[i]))
                }
            }
        } else if isInt16 {
            data.withUnsafeBytes { ptr in
                let intPtr = ptr.bindMemory(to: Int16.self)
                for i in 0..<min(count, intPtr.count) {
                    values.append(Int32(intPtr[i]))
                }
            }
        } else if isUInt32 {
            data.withUnsafeBytes { ptr in
                let intPtr = ptr.bindMemory(to: UInt32.self)
                for i in 0..<min(count, intPtr.count) {
                    values.append(Int32(bitPattern: intPtr[i]))
                }
            }
        } else if isUInt64 {
            data.withUnsafeBytes { ptr in
                let intPtr = ptr.bindMemory(to: UInt64.self)
                for i in 0..<min(count, intPtr.count) {
                    values.append(Int32(clamping: Int64(bitPattern: intPtr[i])))
                }
            }
        } else {
            throw Error.invalidNPYFormat("Unsupported int dtype: \(dtype) for array with shape \(array.shape)")
        }
        
        return values
    }
    
    /// Parse any numeric array as Int (for frame indices, etc.)
    private func parseIntValue(_ array: NPYArray) throws -> Int {
        let dtype = array.dtype.lowercased()
        let data = array.data
        
        // Try to read as various numeric types
        if dtype.contains("i8") || dtype.contains("int64") {
            return data.withUnsafeBytes { Int($0.load(as: Int64.self)) }
        } else if dtype.contains("i4") || dtype.contains("int32") {
            return data.withUnsafeBytes { Int($0.load(as: Int32.self)) }
        } else if dtype.contains("i2") || dtype.contains("int16") {
            return data.withUnsafeBytes { Int($0.load(as: Int16.self)) }
        } else if dtype.contains("u8") || dtype.contains("uint64") {
            return data.withUnsafeBytes { Int($0.load(as: UInt64.self)) }
        } else if dtype.contains("u4") || dtype.contains("uint32") {
            return data.withUnsafeBytes { Int($0.load(as: UInt32.self)) }
        } else if dtype.contains("f8") || dtype.contains("float64") {
            return data.withUnsafeBytes { Int($0.load(as: Double.self)) }
        } else if dtype.contains("f4") || dtype.contains("float32") {
            return data.withUnsafeBytes { Int($0.load(as: Float.self)) }
        } else {
            throw Error.invalidNPYFormat("Cannot parse \(dtype) as integer")
        }
    }
    
    private func parseBoolArray(_ array: NPYArray) throws -> [Bool] {
        let data = array.data
        
        let count: Int
        if array.shape.isEmpty {
            count = 1
        } else {
            count = array.shape.reduce(1, *)
        }
        
        var values: [Bool] = []
        values.reserveCapacity(count)
        
        data.withUnsafeBytes { ptr in
            for i in 0..<min(count, ptr.count) {
                values.append(ptr[i] != 0)
            }
        }
        
        return values
    }
    
    private func float16ToFloat32(_ value: UInt16) -> Float {
        let sign = (value >> 15) & 0x1
        var exponent = (value >> 10) & 0x1F
        var mantissa = value & 0x3FF
        
        if exponent == 0 {
            if mantissa == 0 {
                // Zero
                return sign == 0 ? 0.0 : -0.0
            } else {
                // Subnormal
                while (mantissa & 0x400) == 0 {
                    mantissa <<= 1
                    exponent -= 1
                }
                exponent += 1
                mantissa &= 0x3FF
            }
        } else if exponent == 31 {
            // Inf or NaN
            if mantissa == 0 {
                return sign == 0 ? Float.infinity : -Float.infinity
            } else {
                return Float.nan
            }
        }
        
        let f32Sign = UInt32(sign) << 31
        let f32Exponent = UInt32(Int(exponent) - 15 + 127) << 23
        let f32Mantissa = UInt32(mantissa) << 13
        
        let bits = f32Sign | f32Exponent | f32Mantissa
        return Float(bitPattern: bits)
    }
}

