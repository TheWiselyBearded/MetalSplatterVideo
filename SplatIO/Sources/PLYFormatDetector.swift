import Foundation
import PLYIO

/// Utility for detecting PLY file formats, including compressed PlayCanvas format
public enum PLYFormatDetector {
    /// Detected PLY format type
    public enum FormatType {
        case standard
        case compressed
        case unknown
    }
    
    /// Result of format detection
    public struct DetectionResult {
        public let formatType: FormatType
        public let shDegree: Int?
        
        public init(formatType: FormatType, shDegree: Int? = nil) {
            self.formatType = formatType
            self.shDegree = shDegree
        }
    }
    
    /// Detect PLY format by inspecting file header
    /// - Parameter url: URL to the PLY file
    /// - Returns: Detection result with format type and optional SH degree
    public static func detectFormat(at url: URL) -> DetectionResult {
        guard let inputStream = InputStream(url: url) else {
            return DetectionResult(formatType: .unknown)
        }
        
        inputStream.open()
        defer { inputStream.close() }
        
        // Read header to detect format
        var headerData = Data()
        let bufferSize = 8192
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
        defer { buffer.deallocate() }
        
        var foundEndHeader = false
        while !foundEndHeader && inputStream.hasBytesAvailable {
            let bytesRead = inputStream.read(buffer, maxLength: bufferSize)
            if bytesRead <= 0 {
                break
            }
            
            headerData.append(buffer, count: bytesRead)
            
            // Check if we've found the end of header
            if let headerString = String(data: headerData, encoding: .utf8),
               headerString.contains("end_header") {
                foundEndHeader = true
            }
            
            // Safety limit: don't read more than 64KB for header
            if headerData.count > 65536 {
                break
            }
        }
        
        guard let headerString = String(data: headerData, encoding: .utf8) else {
            return DetectionResult(formatType: .unknown)
        }
        
        return detectFormat(from: headerString)
    }
    
    /// Detect PLY format from header string
    /// - Parameter headerString: PLY header as string
    /// - Returns: Detection result with format type and optional SH degree
    public static func detectFormat(from headerString: String) -> DetectionResult {
        // Check for compressed format markers
        // Compressed PLY files typically have:
        // 1. Specific comments indicating compression
        // 2. Different property structures
        // 3. PlayCanvas-specific markers
        
        let lowercasedHeader = headerString.lowercased()
        
        // Check for standard Gaussian splat properties first
        // Standard PLY files have properties like: x, y, z, f_dc_0, scale_0, etc.
        let hasStandardProperties = headerString.contains("property float x") &&
                                   headerString.contains("property float y") &&
                                   headerString.contains("property float z")
        
        // VERY CONSERVATIVE: Only mark as compressed if:
        // 1. We have explicit PlayCanvas/compressed markers in comments
        // 2. AND we don't have standard float properties (meaning properties are quantized)
        // This prevents false positives where standard PLY files are marked as compressed
        let hasExplicitCompressionMarker = lowercasedHeader.contains("comment.*playcanvas") ||
                                          lowercasedHeader.contains("comment.*compressed") ||
                                          lowercasedHeader.contains("comment.*gaussian_splat_compressed") ||
                                          (lowercasedHeader.contains("playcanvas") && !hasStandardProperties) ||
                                          (lowercasedHeader.contains("gaussian_splat_compressed") && !hasStandardProperties)
        
        // Check if properties are quantized (uchar/uint8 instead of float)
        let hasQuantizedPositionProperties = (headerString.contains("property uchar x") ||
                                             headerString.contains("property uint8 x") ||
                                             headerString.contains("property uchar y") ||
                                             headerString.contains("property uint8 y")) &&
                                             !hasStandardProperties
        
        // Only mark as compressed if we have BOTH explicit markers AND quantized properties
        if hasExplicitCompressionMarker && hasQuantizedPositionProperties {
            return DetectionResult(formatType: .compressed)
        }
        
        // Default to standard format - this is safer and allows fallback
        // Try to detect SH degree from header
        let shDegree = detectSHDegree(from: headerString)
        
        return DetectionResult(formatType: .standard, shDegree: shDegree)
    }
    
    /// Detect spherical harmonics degree from PLY header
    /// - Parameter headerString: PLY header as string
    /// - Returns: Detected SH degree or nil if not found
    private static func detectSHDegree(from headerString: String) -> Int? {
        // Look for f_rest_ properties which indicate higher-order SH coefficients
        // SH degree can be inferred from the number of f_rest_ properties
        // Use NSRegularExpression for compatibility
        guard let regex = try? NSRegularExpression(pattern: "f_rest_(\\d+)", options: []) else {
            return nil
        }
        
        let range = NSRange(headerString.startIndex..<headerString.endIndex, in: headerString)
        let matches = regex.matches(in: headerString, options: [], range: range)
        
        if !matches.isEmpty {
            // Count unique f_rest_ properties to determine SH degree
            // For SH degree N, we expect N*(N+1)/2 - 1 f_rest_ properties (excluding DC)
            // Common values: SH0 = 0, SH1 = 2, SH2 = 5, SH3 = 9, etc.
            var maxIndex = -1
            for match in matches {
                if match.numberOfRanges > 1,
                   let range = Range(match.range(at: 1), in: headerString),
                   let index = Int(headerString[range]) {
                    maxIndex = max(maxIndex, index)
                }
            }
            
            // Infer degree from max index
            // SH degree 0: no f_rest_
            // SH degree 1: f_rest_0, f_rest_1 (indices 0-1)
            // SH degree 2: f_rest_0 through f_rest_4 (indices 0-4)
            // SH degree 3: f_rest_0 through f_rest_8 (indices 0-8)
            if maxIndex >= 0 {
                // Reverse calculation: if max index is N, find degree D where D*(D+1)/2 - 1 >= N
                for degree in 0...10 {
                    let expectedCount = (degree * (degree + 1)) / 2 - 1
                    if maxIndex <= expectedCount {
                        return degree
                    }
                }
            }
        }
        
        // If no f_rest_ properties, likely SH0 (DC only)
        if headerString.contains("f_dc_0") || headerString.contains("f_dc_1") || headerString.contains("f_dc_2") {
            return 0
        }
        
        return nil
    }
}

