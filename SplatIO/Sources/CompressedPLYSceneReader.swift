import Foundation
import PLYIO
import simd

/// Reader for compressed PlayCanvas PLY files
/// 
/// Compressed PLY files use a binary format with chunk metadata and packed vertex data.
/// They do NOT have standard PLY headers with property declarations.
public class CompressedPLYSceneReader: SplatSceneReader {
    enum Error: LocalizedError {
        case cannotOpenSource(URL)
        case unsupportedCompressionFormat
        case decompressionFailed
        case invalidFileStructure(String)
        case propertyNotFound(String)
        
        public var errorDescription: String? {
            switch self {
            case .cannotOpenSource(let url):
                "Cannot open compressed PLY file at \(url)"
            case .unsupportedCompressionFormat:
                "Unsupported compression format in PLY file"
            case .decompressionFailed:
                "Failed to decompress PLY file data"
            case .invalidFileStructure(let details):
                "Invalid compressed PLY file structure: \(details)"
            case .propertyNotFound(let name):
                "Required property '\(name)' not found in compressed PLY file"
            }
        }
    }
    
    private let url: URL
    private var fallbackReader: SplatPLYSceneReader?
    private let allowFallback: Bool  // Control whether to allow fallback to standard PLY reader
    
    public init(_ url: URL, allowFallback: Bool = true) throws {
        self.url = url
        self.allowFallback = allowFallback
        print("[CompressedPLYSceneReader] Initializing for: \(url.lastPathComponent), allowFallback=\(allowFallback)")
        // Only set up fallback reader if fallback is allowed
        if allowFallback {
            self.fallbackReader = try? SplatPLYSceneReader(url)
            print("[CompressedPLYSceneReader] Fallback reader created: \(fallbackReader != nil)")
        } else {
            print("[CompressedPLYSceneReader] Fallback reader disabled")
        }
    }
    
    public convenience init(_ inputStream: InputStream) throws {
        // For InputStream, we need to write to temp file first
        throw Error.unsupportedCompressionFormat
    }
    
    public func read(to delegate: any SplatSceneReaderDelegate) {
        print("[CompressedPLYSceneReader] Reading compressed PLY from: \(url.lastPathComponent)")
        print("[CompressedPLYSceneReader] allowFallback = \(allowFallback)")
        
        // Use a wrapper delegate that prevents multiple failure reports
        let safeDelegate = SafeSplatSceneReaderDelegate(original: delegate)
        
        // First, try to read as PLY file with header (for chunked formats from splat-transform)
        // This handles files with "element chunk" and quantized properties in the header
        print("[CompressedPLYSceneReader] Attempting PLY header-based reader (for chunked formats)...")
        var plyReaderSucceeded = false
        let plyReaderSucceededLock = NSLock()
        
        do {
            let plyReader = try PLYReader(url)
            let streamHandler = CompressedPLYSceneReaderStream(
                quantizationRanges: CompressedPLYDecompressor.QuantizationRanges.default
            )
            
            let trackingDelegate = TrackingSplatSceneReaderDelegate(
                original: safeDelegate,
                onStart: { count in
                    if let count = count {
                        print("[CompressedPLYSceneReader] PLY header-based reader started reading \(count) points")
                    } else {
                        print("[CompressedPLYSceneReader] PLY header-based reader started reading (count unknown)")
                    }
                },
                onFinish: {
                    plyReaderSucceededLock.lock()
                    plyReaderSucceeded = true
                    plyReaderSucceededLock.unlock()
                    print("[CompressedPLYSceneReader] PLY header-based reader succeeded!")
                },
                onFailure: { error in
                    print("[CompressedPLYSceneReader] PLY header-based reader failed: \(error?.localizedDescription ?? "unknown")")
                }
            )
            
            streamHandler.read(plyReader, to: trackingDelegate) {
                // Fallback handler - PLY reader failed, will try binary parser after read() returns
                print("[CompressedPLYSceneReader] PLY header-based reader fallback triggered")
            }
            
            // Check if PLY reader succeeded (read() is synchronous, so this happens after it completes)
            plyReaderSucceededLock.lock()
            let succeeded = plyReaderSucceeded
            plyReaderSucceededLock.unlock()
            
            if succeeded {
                return
            }
            
            // PLY reader failed, continue to try binary parser
            print("[CompressedPLYSceneReader] PLY header-based reader failed, trying binary parser...")
            
        } catch {
            print("[CompressedPLYSceneReader] Failed to create PLY reader: \(error)")
            // Continue to try binary parser
        }
        
        // If PLY reader approach fails, try binary format parser
        do {
            print("[CompressedPLYSceneReader] Attempting binary format parser...")
            let points = try PlayCanvasCompressedPLYReader.readCompressedPLY(from: url)
            
            print("[CompressedPLYSceneReader] Binary parser succeeded! Loaded \(points.count) points")
            
            // Notify delegate
            safeDelegate.didStartReading(withPointCount: UInt32(points.count))
            
            // Send points in batches
            let batchSize = 1000
            for i in stride(from: 0, to: points.count, by: batchSize) {
                let end = min(i + batchSize, points.count)
                let batch = Array(points[i..<end])
                safeDelegate.didRead(points: batch)
            }
            
            safeDelegate.didFinishReading()
            print("[CompressedPLYSceneReader] Successfully completed reading")
        } catch {
            print("[CompressedPLYSceneReader] Binary parser also failed: \(error)")
            print("[CompressedPLYSceneReader] Error type: \(type(of: error))")
            if let compressedError = error as? CompressedPLYSceneReader.Error {
                print("[CompressedPLYSceneReader] Compressed error: \(compressedError.localizedDescription)")
            }
            
            // If we know this is compressed (allowFallback == false), don't try standard PLY fallback
            // This prevents the fallback from trying to read as standard PLY, which will fail
            if !allowFallback {
                print("[CompressedPLYSceneReader] Fallback disabled, reporting error")
                safeDelegate.didFailReading(withError: error)
                return
            }
            
            // If both compressed approaches fail, try standard PLY reader as last resort
            // (only if fallback is allowed, e.g., for auto-detected compressed files)
            print("[CompressedPLYSceneReader] Attempting fallback to standard PLY reader...")
            if let fallbackReader = fallbackReader {
                fallbackReader.read(to: safeDelegate)
            } else {
                print("[CompressedPLYSceneReader] No fallback reader available")
                safeDelegate.didFailReading(withError: error)
            }
        }
    }
}

/// Safe delegate wrapper that ensures didFailReading is only called once
private class SafeSplatSceneReaderDelegate: SplatSceneReaderDelegate {
    private let original: SplatSceneReaderDelegate
    private var hasReportedFailure = false
    private var hasFinished = false
    private let lock = NSLock()
    
    init(original: SplatSceneReaderDelegate) {
        self.original = original
    }
    
    func didStartReading(withPointCount pointCount: UInt32?) {
        original.didStartReading(withPointCount: pointCount)
    }
    
    func didRead(points: [SplatScenePoint]) {
        original.didRead(points: points)
    }
    
    func didFinishReading() {
        lock.lock()
        defer { lock.unlock() }
        guard !hasFinished && !hasReportedFailure else {
            print("[SafeSplatSceneReaderDelegate] Ignoring didFinishReading - already finished or failed")
            return
        }
        hasFinished = true
        original.didFinishReading()
    }
    
    func didFailReading(withError error: Error?) {
        lock.lock()
        defer { lock.unlock() }
        guard !hasReportedFailure && !hasFinished else {
            print("[SafeSplatSceneReaderDelegate] Ignoring didFailReading - already reported failure or finished")
            return
        }
        hasReportedFailure = true
        original.didFailReading(withError: error)
    }
}


/// Tracking delegate to monitor PLY reader success/failure
/// This delegate swallows failures if we're going to try another approach
private class TrackingSplatSceneReaderDelegate: SplatSceneReaderDelegate {
    private let original: SplatSceneReaderDelegate
    private let onStart: (UInt32?) -> Void
    private let onFinish: () -> Void
    private let onFailure: (Error?) -> Void
    private var shouldSwallowFailures: Bool = true  // Don't propagate failures if we'll try another approach
    
    init(original: SplatSceneReaderDelegate, onStart: @escaping (UInt32?) -> Void, onFinish: @escaping () -> Void, onFailure: @escaping (Error?) -> Void) {
        self.original = original
        self.onStart = onStart
        self.onFinish = onFinish
        self.onFailure = onFailure
    }
    
    func didStartReading(withPointCount pointCount: UInt32?) {
        shouldSwallowFailures = false  // Once we start reading, propagate failures
        onStart(pointCount)
        original.didStartReading(withPointCount: pointCount)
    }
    
    func didRead(points: [SplatScenePoint]) {
        shouldSwallowFailures = false  // Once we start reading, propagate failures
        original.didRead(points: points)
    }
    
    func didFinishReading() {
        shouldSwallowFailures = false
        onFinish()
        original.didFinishReading()
    }
    
    func didFailReading(withError error: Error?) {
        onFailure(error)
        // Only propagate failure if we've actually started reading
        // If we're still in the mapping phase, swallow it so we can try another approach
        if !shouldSwallowFailures {
            original.didFailReading(withError: error)
        } else {
            print("[TrackingSplatSceneReaderDelegate] Swallowing failure (will try another approach): \(error?.localizedDescription ?? "unknown")")
        }
    }
}

/// Protocol for element mappings that can convert PLY elements to SplatScenePoint
private protocol ElementInputMappingProtocol {
    var elementTypeIndex: Int { get }
    func apply(from element: PLYElement, to result: inout SplatScenePoint) throws
}

/// Internal stream handler for compressed PLY reading with decompression
private class CompressedPLYSceneReaderStream {
    private weak var delegate: SplatSceneReaderDelegate?
    private var active = false
    private var elementMapping: ElementInputMappingProtocol?
    private var expectedPointCount: UInt32 = 0
    private var pointCount: UInt32 = 0
    private var reusablePoint = SplatScenePoint(
        position: .zero,
        color: .linearUInt8(.zero),
        opacity: .linearFloat(.zero),
        scale: .exponent(.zero),
        rotation: .init(vector: .zero)
    )
    private var batchedPoints: [SplatScenePoint] = []
    private static let batchSize = 1000
    private let quantizationRanges: CompressedPLYDecompressor.QuantizationRanges
    
    init(quantizationRanges: CompressedPLYDecompressor.QuantizationRanges) {
        self.quantizationRanges = quantizationRanges
    }
    
    private var fallbackHandler: (() -> Void)?
    
    func read(_ ply: PLYReader, to delegate: SplatSceneReaderDelegate, fallbackReader: @escaping () -> Void) {
        self.delegate = delegate
        self.fallbackHandler = fallbackReader
        active = true
        elementMapping = nil
        expectedPointCount = 0
        pointCount = 0
        batchedPoints.removeAll(keepingCapacity: true)
        
        ply.read(to: self)
        
        assert(!active)
    }
    
    private func flushBatch() {
        guard !batchedPoints.isEmpty else { return }
        delegate?.didRead(points: batchedPoints)
        batchedPoints.removeAll(keepingCapacity: true)
    }
}

extension CompressedPLYSceneReaderStream: PLYReaderDelegate {
    func didStartReading(withHeader header: PLYHeader) {
        guard active else { return }
        guard elementMapping == nil else {
            active = false
            fallbackHandler?()
            return
        }
        
        // Log header information for debugging
        print("[CompressedPLYSceneReaderStream] PLY header has \(header.elements.count) element types:")
        for (index, element) in header.elements.enumerated() {
            print("[CompressedPLYSceneReaderStream]   Element \(index): '\(element.name)' with \(element.count) items")
            print("[CompressedPLYSceneReaderStream]     Properties: \(element.properties.map { "\($0.name): \($0.type)" }.joined(separator: ", "))")
        }
        
        // Check if this is a packed format (has packed_position, packed_rotation, etc.)
        let hasPackedFormat = header.elements.contains { element in
            element.name == "vertex" && 
            element.properties.contains { $0.name == "packed_position" || $0.name == "packed_rotation" }
        }
        
        if hasPackedFormat {
            print("[CompressedPLYSceneReaderStream] Detected packed format (packed_* properties)")
            // Try to create packed format mapping
            do {
                let elementMapping = try PackedElementInputMapping.elementMapping(
                    for: header,
                    quantizationRanges: quantizationRanges
                )
                self.elementMapping = elementMapping
                expectedPointCount = header.elements[elementMapping.elementTypeIndex].count
                print("[CompressedPLYSceneReaderStream] Successfully created packed mapping for element '\(header.elements[elementMapping.elementTypeIndex].name)' with \(expectedPointCount) points")
                delegate?.didStartReading(withPointCount: expectedPointCount)
            } catch {
                print("[CompressedPLYSceneReaderStream] Failed to create packed mapping: \(error)")
                active = false
                fallbackHandler?()
                return
            }
        } else {
            // Try to create standard compressed mapping - if it fails, fall back immediately
            do {
                let elementMapping = try CompressedElementInputMapping.elementMapping(
                    for: header,
                    quantizationRanges: quantizationRanges
                )
                self.elementMapping = elementMapping
                expectedPointCount = header.elements[elementMapping.elementTypeIndex].count
                print("[CompressedPLYSceneReaderStream] Successfully created mapping for element '\(header.elements[elementMapping.elementTypeIndex].name)' with \(expectedPointCount) points")
                delegate?.didStartReading(withPointCount: expectedPointCount)
            } catch {
                // Mapping failed - log why and fall back
                print("[CompressedPLYSceneReaderStream] Failed to create compressed mapping: \(error)")
                print("[CompressedPLYSceneReaderStream] This might be a chunked format - will try binary parser")
                active = false
                fallbackHandler?()
                return
            }
        }
    }
    
    func didRead(element: PLYElement, typeIndex: Int, withHeader elementHeader: PLYHeader.Element) {
        guard active else { return }
        guard let elementMapping else {
            delegate?.didFailReading(withError: CompressedPLYSceneReader.Error.invalidFileStructure("Element mapping failed"))
            active = false
            return
        }
        
        // If this is a chunk element, we might want to store metadata (for future use)
        if elementHeader.name == "chunk" {
            // For now, we'll skip chunks - they're metadata
            // In the future, we could read chunk bounds here and use them for vertex dequantization
            return
        }
        
        guard typeIndex == elementMapping.elementTypeIndex else { return }
        do {
            try elementMapping.apply(from: element, to: &reusablePoint)
            pointCount += 1
            
            batchedPoints.append(reusablePoint)
            if batchedPoints.count >= Self.batchSize {
                flushBatch()
            }
        } catch {
            delegate?.didFailReading(withError: error)
            active = false
            return
        }
    }
    
    func didFinishReading() {
        guard active else { return }
        guard expectedPointCount == pointCount else {
            delegate?.didFailReading(withError: SplatPLYSceneReader.Error.unexpectedPointCountDiscrepancy)
            active = false
            return
        }
        
        flushBatch()
        delegate?.didFinishReading()
        active = false
    }
    
    func didFailReading(withError error: Swift.Error?) {
        guard active else { return }
        delegate?.didFailReading(withError: error)
        active = false
    }
}

/// Mapping for compressed PLY element properties with decompression
private struct CompressedElementInputMapping: ElementInputMappingProtocol {
    enum Color {
        case sphericalHarmonic([SIMD3<Int>])
        case linearFloat256(SIMD3<Int>)
        case linearUInt8(SIMD3<Int>)
    }
    
    let elementTypeIndex: Int
    let quantizationRanges: CompressedPLYDecompressor.QuantizationRanges
    
    // Property indices (may be quantized uint8/uint16 instead of float32)
    let positionXPropertyIndex: Int
    let positionYPropertyIndex: Int
    let positionZPropertyIndex: Int
    let colorPropertyIndices: Color
    let scaleXPropertyIndex: Int
    let scaleYPropertyIndex: Int
    let scaleZPropertyIndex: Int
    let opacityPropertyIndex: Int
    let rotation0PropertyIndex: Int
    let rotation1PropertyIndex: Int
    let rotation2PropertyIndex: Int
    let rotation3PropertyIndex: Int
    
    static func elementMapping(for header: PLYHeader, 
                               quantizationRanges: CompressedPLYDecompressor.QuantizationRanges) throws -> CompressedElementInputMapping {
        guard let elementTypeIndex = header.index(forElementNamed: SplatPLYConstants.ElementName.point.rawValue) else {
            throw CompressedPLYSceneReader.Error.propertyNotFound(SplatPLYConstants.ElementName.point.rawValue)
        }
        let headerElement = header.elements[elementTypeIndex]
        
        // Find position properties (may be quantized)
        // Try to find properties - if any required property is missing, throw to trigger fallback
        guard let positionXPropertyIndex = findPropertyIndex(
            in: headerElement,
            names: SplatPLYConstants.PropertyName.positionX,
            allowQuantized: true
        ),
        let positionYPropertyIndex = findPropertyIndex(
            in: headerElement,
            names: SplatPLYConstants.PropertyName.positionY,
            allowQuantized: true
        ),
        let positionZPropertyIndex = findPropertyIndex(
            in: headerElement,
            names: SplatPLYConstants.PropertyName.positionZ,
            allowQuantized: true
        ) else {
            throw CompressedPLYSceneReader.Error.propertyNotFound("position (x, y, z)")
        }
        
        // Find color properties (handle both SH and RGB, may be quantized)
        let color: Color
        if let sh0_r = findPropertyIndex(in: headerElement, names: SplatPLYConstants.PropertyName.sh0_r, allowQuantized: true),
           let sh0_g = findPropertyIndex(in: headerElement, names: SplatPLYConstants.PropertyName.sh0_g, allowQuantized: true),
           let sh0_b = findPropertyIndex(in: headerElement, names: SplatPLYConstants.PropertyName.sh0_b, allowQuantized: true) {
            // Spherical harmonics format
            let primaryColorIndices = SIMD3<Int>(x: sh0_r, y: sh0_g, z: sh0_b)
            if headerElement.hasProperty(forName: "\(SplatPLYConstants.PropertyName.sphericalHarmonicsPrefix)0") {
                let shCount = 45 // Standard spherical harmonics count
                var shIndices: [SIMD3<Int>] = [primaryColorIndices]
                for i in 0..<shCount {
                    if let idx = findPropertyIndex(
                        in: headerElement,
                        names: ["\(SplatPLYConstants.PropertyName.sphericalHarmonicsPrefix)\(i)"],
                        allowQuantized: true
                    ) {
                        // SH coefficients come in groups of 3 (RGB)
                        if i % 3 == 0 && i + 2 < shCount {
                            let r = idx
                            let g = findPropertyIndex(in: headerElement, names: ["\(SplatPLYConstants.PropertyName.sphericalHarmonicsPrefix)\(i+1)"], allowQuantized: true) ?? r
                            let b = findPropertyIndex(in: headerElement, names: ["\(SplatPLYConstants.PropertyName.sphericalHarmonicsPrefix)\(i+2)"], allowQuantized: true) ?? r
                            shIndices.append(SIMD3<Int>(x: r, y: g, z: b))
                        }
                    }
                }
                color = .sphericalHarmonic(shIndices)
            } else {
                color = .sphericalHarmonic([primaryColorIndices])
            }
        } else if let r = findPropertyIndex(in: headerElement, names: SplatPLYConstants.PropertyName.colorR, allowQuantized: true),
                  let g = findPropertyIndex(in: headerElement, names: SplatPLYConstants.PropertyName.colorG, allowQuantized: true),
                  let b = findPropertyIndex(in: headerElement, names: SplatPLYConstants.PropertyName.colorB, allowQuantized: true) {
            // RGB format - check if it's float32 or uint8
            let rProperty = headerElement.properties[r]
            if case .primitive(.float32) = rProperty.type {
                color = .linearFloat256(SIMD3(r, g, b))
            } else {
                color = .linearUInt8(SIMD3(r, g, b))
            }
        } else {
            throw CompressedPLYSceneReader.Error.propertyNotFound("color")
        }
        
        // Find scale, opacity, and rotation properties (may be quantized)
        // If any required property is missing, throw to trigger fallback
        guard let scaleXPropertyIndex = findPropertyIndex(in: headerElement, names: SplatPLYConstants.PropertyName.scaleX, allowQuantized: true),
              let scaleYPropertyIndex = findPropertyIndex(in: headerElement, names: SplatPLYConstants.PropertyName.scaleY, allowQuantized: true),
              let scaleZPropertyIndex = findPropertyIndex(in: headerElement, names: SplatPLYConstants.PropertyName.scaleZ, allowQuantized: true),
              let opacityPropertyIndex = findPropertyIndex(in: headerElement, names: SplatPLYConstants.PropertyName.opacity, allowQuantized: true),
              let rotation0PropertyIndex = findPropertyIndex(in: headerElement, names: SplatPLYConstants.PropertyName.rotation0, allowQuantized: true),
              let rotation1PropertyIndex = findPropertyIndex(in: headerElement, names: SplatPLYConstants.PropertyName.rotation1, allowQuantized: true),
              let rotation2PropertyIndex = findPropertyIndex(in: headerElement, names: SplatPLYConstants.PropertyName.rotation2, allowQuantized: true),
              let rotation3PropertyIndex = findPropertyIndex(in: headerElement, names: SplatPLYConstants.PropertyName.rotation3, allowQuantized: true) else {
            throw CompressedPLYSceneReader.Error.propertyNotFound("required properties")
        }
        
        return CompressedElementInputMapping(
            elementTypeIndex: elementTypeIndex,
            quantizationRanges: quantizationRanges,
            positionXPropertyIndex: positionXPropertyIndex,
            positionYPropertyIndex: positionYPropertyIndex,
            positionZPropertyIndex: positionZPropertyIndex,
            colorPropertyIndices: color,
            scaleXPropertyIndex: scaleXPropertyIndex,
            scaleYPropertyIndex: scaleYPropertyIndex,
            scaleZPropertyIndex: scaleZPropertyIndex,
            opacityPropertyIndex: opacityPropertyIndex,
            rotation0PropertyIndex: rotation0PropertyIndex,
            rotation1PropertyIndex: rotation1PropertyIndex,
            rotation2PropertyIndex: rotation2PropertyIndex,
            rotation3PropertyIndex: rotation3PropertyIndex
        )
    }
    
    /// Find property index, allowing quantized types (uint8, uint16) in addition to float32
    /// Returns nil if not found (instead of throwing) for easier fallback handling
    private static func findPropertyIndex(in element: PLYHeader.Element,
                                         names: [String],
                                         allowQuantized: Bool) -> Int? {
        for name in names {
            if let index = element.index(forPropertyNamed: name) {
                let property = element.properties[index]
                // If allowQuantized is true, accept any primitive type (for compressed files)
                if allowQuantized {
                    if case .primitive = property.type {
                        return index
                    }
                } else {
                    // Only accept float types for standard files
                    switch property.type {
                    case .primitive(.float32), .primitive(.float64):
                        return index
                    default:
                        continue
                    }
                }
            }
        }
        return nil
    }
    
    func apply(from element: PLYElement, to result: inout SplatScenePoint) throws {
        // Dequantize position
        result.position = SIMD3(
            x: try dequantizeProperty(element, index: positionXPropertyIndex, name: "x"),
            y: try dequantizeProperty(element, index: positionYPropertyIndex, name: "y"),
            z: try dequantizeProperty(element, index: positionZPropertyIndex, name: "z")
        )
        
        // Dequantize color
        switch colorPropertyIndices {
        case .sphericalHarmonic(let shIndices):
            result.color = .sphericalHarmonic(try shIndices.map { indices in
                SIMD3(
                    x: try dequantizeProperty(element, index: indices.x, name: "sh"),
                    y: try dequantizeProperty(element, index: indices.y, name: "sh"),
                    z: try dequantizeProperty(element, index: indices.z, name: "sh")
                )
            })
        case .linearFloat256(let indices):
            result.color = .linearFloat256(SIMD3(
                x: try dequantizeProperty(element, index: indices.x, name: "color"),
                y: try dequantizeProperty(element, index: indices.y, name: "color"),
                z: try dequantizeProperty(element, index: indices.z, name: "color")
            ))
        case .linearUInt8(let indices):
            result.color = .linearUInt8(SIMD3(
                x: try dequantizeProperty(element, index: indices.x, name: "color").asUInt8,
                y: try dequantizeProperty(element, index: indices.y, name: "color").asUInt8,
                z: try dequantizeProperty(element, index: indices.z, name: "color").asUInt8
            ))
        }
        
        // Dequantize scale (log space)
        result.scale = .exponent(SIMD3(
            x: try dequantizeProperty(element, index: scaleXPropertyIndex, name: "scale"),
            y: try dequantizeProperty(element, index: scaleYPropertyIndex, name: "scale"),
            z: try dequantizeProperty(element, index: scaleZPropertyIndex, name: "scale")
        ))
        
        // Dequantize opacity (logit space)
        result.opacity = .logitFloat(try dequantizeProperty(element, index: opacityPropertyIndex, name: "opacity"))
        
        // Dequantize rotation (quaternion)
        result.rotation.real = try dequantizeProperty(element, index: rotation0PropertyIndex, name: "rotation")
        result.rotation.imag.x = try dequantizeProperty(element, index: rotation1PropertyIndex, name: "rotation")
        result.rotation.imag.y = try dequantizeProperty(element, index: rotation2PropertyIndex, name: "rotation")
        result.rotation.imag.z = try dequantizeProperty(element, index: rotation3PropertyIndex, name: "rotation")
    }
    
    /// Dequantize a property value
    private func dequantizeProperty(_ element: PLYElement, index: Int, name: String) throws -> Float {
        guard index < element.properties.count else {
            throw CompressedPLYSceneReader.Error.propertyNotFound(name)
        }
        
        let property = element.properties[index]
        guard let dequantized = CompressedPLYDecompressor.dequantizeProperty(
            property,
            propertyName: name,
            ranges: quantizationRanges
        ) else {
            throw CompressedPLYSceneReader.Error.decompressionFailed
        }
        
        return dequantized
    }
}

/// Mapping for packed PLY element properties (packed_position, packed_rotation, etc.)
/// Used for splat-transform compressed PLY files with chunked format
private struct PackedElementInputMapping: ElementInputMappingProtocol {
    let elementTypeIndex: Int
    let quantizationRanges: CompressedPLYDecompressor.QuantizationRanges
    
    // Property indices for packed properties
    let packedPositionPropertyIndex: Int
    let packedRotationPropertyIndex: Int
    let packedScalePropertyIndex: Int
    let packedColorPropertyIndex: Int
    let packedOpacityPropertyIndex: Int?  // May or may not be present
    
    // Chunk metadata (if available)
    var chunkMetadata: [ChunkMetadata] = []
    
    struct ChunkMetadata {
        var positionMin: SIMD3<Float>
        var positionMax: SIMD3<Float>
        var scaleMin: Float
        var scaleMax: Float
        var opacityMin: Float
        var opacityMax: Float
        var colorMin: SIMD3<Float>
        var colorMax: SIMD3<Float>
    }
    
    static func elementMapping(for header: PLYHeader,
                               quantizationRanges: CompressedPLYDecompressor.QuantizationRanges) throws -> PackedElementInputMapping {
        // Find vertex element
        guard let vertexElementIndex = header.elements.firstIndex(where: { $0.name == "vertex" }) else {
            throw CompressedPLYSceneReader.Error.propertyNotFound("vertex element")
        }
        let vertexElement = header.elements[vertexElementIndex]
        
        // Find packed properties
        guard let packedPositionIndex = vertexElement.index(forPropertyNamed: "packed_position"),
              let packedRotationIndex = vertexElement.index(forPropertyNamed: "packed_rotation"),
              let packedScaleIndex = vertexElement.index(forPropertyNamed: "packed_scale"),
              let packedColorIndex = vertexElement.index(forPropertyNamed: "packed_color") else {
            throw CompressedPLYSceneReader.Error.propertyNotFound("packed_* properties")
        }
        
        // Check property types - they should be primitive uint32, not lists
        let positionProp = vertexElement.properties[packedPositionIndex]
        let rotationProp = vertexElement.properties[packedRotationIndex]
        let scaleProp = vertexElement.properties[packedScaleIndex]
        let colorProp = vertexElement.properties[packedColorIndex]
        
        print("[PackedElementInputMapping] packed_position type: \(positionProp.type)")
        print("[PackedElementInputMapping] packed_rotation type: \(rotationProp.type)")
        print("[PackedElementInputMapping] packed_scale type: \(scaleProp.type)")
        print("[PackedElementInputMapping] packed_color type: \(colorProp.type)")
        
        // Verify they are primitive uint32 (splat-transform format uses uint32, not lists)
        guard case .primitive(.uint32) = positionProp.type,
              case .primitive(.uint32) = rotationProp.type,
              case .primitive(.uint32) = scaleProp.type,
              case .primitive(.uint32) = colorProp.type else {
            print("[PackedElementInputMapping] ERROR: packed_* properties must be uint32 primitives, not lists")
            throw CompressedPLYSceneReader.Error.invalidFileStructure("packed_* properties must be uint32, not lists. Found: position=\(positionProp.type), rotation=\(rotationProp.type), scale=\(scaleProp.type), color=\(colorProp.type)")
        }
        
        // Find chunk element for metadata (if present)
        var chunkMetadata: [ChunkMetadata] = []
        if let chunkElementIndex = header.elements.firstIndex(where: { $0.name == "chunk" }) {
            print("[PackedElementInputMapping] Found chunk element with \(header.elements[chunkElementIndex].count) chunks")
            // We'll read chunk metadata when we process chunks
        }
        
        // Check for packed_opacity (may be separate or included in packed_color)
        let packedOpacityIndex = vertexElement.index(forPropertyNamed: "packed_opacity")
        
        return PackedElementInputMapping(
            elementTypeIndex: vertexElementIndex,
            quantizationRanges: quantizationRanges,
            packedPositionPropertyIndex: packedPositionIndex,
            packedRotationPropertyIndex: packedRotationIndex,
            packedScalePropertyIndex: packedScaleIndex,
            packedColorPropertyIndex: packedColorIndex,
            packedOpacityPropertyIndex: packedOpacityIndex,
            chunkMetadata: chunkMetadata
        )
    }
    
    func apply(from element: PLYElement, to result: inout SplatScenePoint) throws {
        // Extract packed data - these are uint32 values, not lists
        let packedPosition = element.properties[packedPositionPropertyIndex]
        let packedRotation = element.properties[packedRotationPropertyIndex]
        let packedScale = element.properties[packedScalePropertyIndex]
        let packedColor = element.properties[packedColorPropertyIndex]
        
        // Unpack position from uint32
        // splat-transform uses: 11 bits for x, 11 bits for y, 10 bits for z (total 32 bits)
        let position: SIMD3<Float>
        if case .uint32(let posPacked) = packedPosition {
            // Extract: x (bits 21-31, 11 bits), y (bits 10-20, 11 bits), z (bits 0-9, 10 bits)
            let x = UInt16((posPacked >> 21) & 0x7FF)  // Bits 21-31 (11 bits)
            let y = UInt16((posPacked >> 10) & 0x7FF)  // Bits 10-20 (11 bits)
            let z = UInt16(posPacked & 0x3FF)          // Bits 0-9 (10 bits)
            
            position = SIMD3<Float>(
                x: dequantizeUInt16(x, min: quantizationRanges.positionMin.x, max: quantizationRanges.positionMax.x),
                y: dequantizeUInt16(y, min: quantizationRanges.positionMin.y, max: quantizationRanges.positionMax.y),
                z: dequantizeUInt16(z, min: quantizationRanges.positionMin.z, max: quantizationRanges.positionMax.z)
            )
        } else {
            print("[PackedElementInputMapping] ERROR: packed_position type: \(packedPosition)")
            throw CompressedPLYSceneReader.Error.invalidFileStructure("Invalid packed_position format: expected uint32, got \(packedPosition)")
        }
        
        // Unpack rotation from uint32 (3x UInt8, smallest-three quaternion)
        // Format: 3x 8-bit values packed into uint32 (bits 16-23, 8-15, 0-7)
        let rotation: simd_quatf
        if case .uint32(let rotPacked) = packedRotation {
            let q0 = UInt8((rotPacked >> 16) & 0xFF)  // Bits 16-23
            let q1 = UInt8((rotPacked >> 8) & 0xFF)   // Bits 8-15
            let q2 = UInt8(rotPacked & 0xFF)          // Bits 0-7
            
            rotation = decodeSmallestThreeQuaternion(q0: q0, q1: q1, q2: q2)
        } else {
            print("[PackedElementInputMapping] ERROR: packed_rotation type: \(packedRotation)")
            throw CompressedPLYSceneReader.Error.invalidFileStructure("Invalid packed_rotation format: expected uint32, got \(packedRotation)")
        }
        
        // Unpack scale from uint32 (3x UInt8)
        // Format: 3x 8-bit values packed into uint32 (bits 16-23, 8-15, 0-7)
        let scale: SIMD3<Float>
        if case .uint32(let scalePacked) = packedScale {
            let scaleX = UInt8((scalePacked >> 16) & 0xFF)  // Bits 16-23
            let scaleY = UInt8((scalePacked >> 8) & 0xFF)   // Bits 8-15
            let scaleZ = UInt8(scalePacked & 0xFF)          // Bits 0-7
            
            scale = SIMD3<Float>(
                x: dequantizeUInt8(scaleX, min: quantizationRanges.scaleMin, max: quantizationRanges.scaleMax),
                y: dequantizeUInt8(scaleY, min: quantizationRanges.scaleMin, max: quantizationRanges.scaleMax),
                z: dequantizeUInt8(scaleZ, min: quantizationRanges.scaleMin, max: quantizationRanges.scaleMax)
            )
        } else {
            print("[PackedElementInputMapping] ERROR: packed_scale type: \(packedScale)")
            throw CompressedPLYSceneReader.Error.invalidFileStructure("Invalid packed_scale format: expected uint32, got \(packedScale)")
        }
        
        // Unpack color from uint32 (4x UInt8: RGB + opacity)
        // Format: 4x 8-bit values packed into uint32 (bits 24-31, 16-23, 8-15, 0-7)
        let sh0: SIMD3<Float>
        let opacity: Float
        if case .uint32(let colorPacked) = packedColor {
            let r = UInt8((colorPacked >> 24) & 0xFF)  // Bits 24-31
            let g = UInt8((colorPacked >> 16) & 0xFF)  // Bits 16-23
            let b = UInt8((colorPacked >> 8) & 0xFF)   // Bits 8-15
            let a = UInt8(colorPacked & 0xFF)          // Bits 0-7 (opacity)
            
            sh0 = SIMD3<Float>(
                x: dequantizeUInt8(r, min: quantizationRanges.colorMin, max: quantizationRanges.colorMax),
                y: dequantizeUInt8(g, min: quantizationRanges.colorMin, max: quantizationRanges.colorMax),
                z: dequantizeUInt8(b, min: quantizationRanges.colorMin, max: quantizationRanges.colorMax)
            )
            
            opacity = dequantizeUInt8(a, min: quantizationRanges.opacityMin, max: quantizationRanges.opacityMax)
        } else {
            // Fallback: check if there's a separate packed_opacity property
            if let opacityIndex = packedOpacityPropertyIndex, case .uint32(let opacityPacked) = element.properties[opacityIndex] {
                opacity = dequantizeUInt8(UInt8(opacityPacked & 0xFF), min: quantizationRanges.opacityMin, max: quantizationRanges.opacityMax)
                
                // Color is just RGB (3 bytes)
                if case .uint32(let colorPacked) = packedColor {
                    let r = UInt8((colorPacked >> 16) & 0xFF)  // Bits 16-23
                    let g = UInt8((colorPacked >> 8) & 0xFF)   // Bits 8-15
                    let b = UInt8(colorPacked & 0xFF)          // Bits 0-7
                    
                    sh0 = SIMD3<Float>(
                        x: dequantizeUInt8(r, min: quantizationRanges.colorMin, max: quantizationRanges.colorMax),
                        y: dequantizeUInt8(g, min: quantizationRanges.colorMin, max: quantizationRanges.colorMax),
                        z: dequantizeUInt8(b, min: quantizationRanges.colorMin, max: quantizationRanges.colorMax)
                    )
                } else {
                    print("[PackedElementInputMapping] ERROR: packed_color type: \(packedColor)")
                    throw CompressedPLYSceneReader.Error.invalidFileStructure("Invalid packed_color format: expected uint32, got \(packedColor)")
                }
            } else {
                print("[PackedElementInputMapping] ERROR: packed_color type: \(packedColor)")
                throw CompressedPLYSceneReader.Error.invalidFileStructure("Invalid packed_color format: expected uint32, got \(packedColor)")
            }
        }
        
        result.position = position
        result.rotation = rotation
        result.scale = .exponent(scale)
        result.opacity = .logitFloat(opacity)
        result.color = .sphericalHarmonic([sh0])
    }
}

// Helper functions for unpacking (duplicated from PlayCanvasCompressedPLYReader since they're private)
private func dequantizeUInt8(_ value: UInt8, min: Float, max: Float) -> Float {
    let normalized = Float(value) * (1.0 / 255.0)
    return min + normalized * (max - min)
}

private func dequantizeUInt16(_ value: UInt16, min: Float, max: Float) -> Float {
    let normalized = Float(value) * (1.0 / 65535.0)
    return min + normalized * (max - min)
}

private func decodeSmallestThreeQuaternion(q0: UInt8, q1: UInt8, q2: UInt8) -> simd_quatf {
    // Dequantize from [0, 255] to [-1, 1]
    let q0f = dequantizeUInt8(q0, min: -1.0, max: 1.0)
    let q1f = dequantizeUInt8(q1, min: -1.0, max: 1.0)
    let q2f = dequantizeUInt8(q2, min: -1.0, max: 1.0)
    
    let q0sq = q0f * q0f
    let q1sq = q1f * q1f
    let q2sq = q2f * q2f
    let sumSq = q0sq + q1sq + q2sq
    
    guard sumSq < 1.0 else {
        return simd_quatf(ix: 0, iy: 0, iz: 0, r: 1)
    }
    
    let q3sq = 1.0 - sumSq
    let q3 = sqrt(max(0, q3sq))
    
    // Try all 4 positions and pick the best
    let candidates: [simd_quatf] = [
        simd_quatf(ix: q3, iy: q0f, iz: q1f, r: q2f),
        simd_quatf(ix: q0f, iy: q3, iz: q1f, r: q2f),
        simd_quatf(ix: q0f, iy: q1f, iz: q3, r: q2f),
        simd_quatf(ix: q0f, iy: q1f, iz: q2f, r: q3)
    ]
    
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

/// Helper to get list count from PLYElement.Property (works around internal access)
private func getListCount(from property: PLYElement.Property) -> Int {
    switch property {
    case .listInt8(let values): return values.count
    case .listUInt8(let values): return values.count
    case .listInt16(let values): return values.count
    case .listUInt16(let values): return values.count
    case .listInt32(let values): return values.count
    case .listUInt32(let values): return values.count
    case .listFloat32(let values): return values.count
    case .listFloat64(let values): return values.count
    default: return -1
    }
}

private extension Float {
    var asUInt8: UInt8 {
        UInt8(max(0, min(255, self * 255.0)))
    }
}

private extension PLYHeader.Element {
    func hasProperty(forName name: String, type: PLYHeader.PrimitivePropertyType? = nil) -> Bool {
        guard let index = index(forPropertyNamed: name) else {
            return false
        }
        
        if let type {
            guard case .primitive(type) = properties[index].type else {
                return false
            }
        }
        
        return true
    }
}

