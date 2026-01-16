import Foundation

/// Cache for PLY format detection results, organized by directory
/// 
/// Assumes that all PLY files in a directory share the same format.
/// This avoids redundant format detection for each file in a sequence.
public class PLYFormatCache {
    /// Shared singleton instance
    public static let shared = PLYFormatCache()
    
    /// Format information for a directory
    private struct DirectoryFormat {
        let formatType: PLYFormatDetector.FormatType
        let shDegree: Int?
        let detectedAt: Date
        let isExplicit: Bool  // Track if format was explicitly set vs auto-detected
        
        init(formatType: PLYFormatDetector.FormatType, shDegree: Int? = nil, isExplicit: Bool = false) {
            self.formatType = formatType
            self.shDegree = shDegree
            self.detectedAt = Date()
            self.isExplicit = isExplicit
        }
    }
    
    private var cache: [String: DirectoryFormat] = [:]
    private let cacheLock = NSLock()
    
    private init() {}
    
    /// Get the directory path key for a file URL
    private func directoryKey(for url: URL) -> String {
        url.deletingLastPathComponent().path
    }
    
    /// Get cached format for a directory, or detect and cache it
    /// - Parameter url: URL to a PLY file (format will be cached for its directory)
    /// - Returns: Detection result with format type and optional SH degree
    public func getFormat(for url: URL) -> PLYFormatDetector.DetectionResult {
        let key = directoryKey(for: url)
        
        cacheLock.lock()
        defer { cacheLock.unlock() }
        
        // Check cache first
        if let cached = cache[key] {
            return PLYFormatDetector.DetectionResult(
                formatType: cached.formatType,
                shDegree: cached.shDegree
            )
        }
        
        // Detect format from the file
        let detection = PLYFormatDetector.detectFormat(at: url)
        
        // Cache the result for the entire directory (not explicitly set)
        cache[key] = DirectoryFormat(
            formatType: detection.formatType,
            shDegree: detection.shDegree,
            isExplicit: false
        )
        
        return detection
    }
    
    /// Explicitly set format for a directory (useful when format is known)
    /// - Parameters:
    ///   - url: URL to a PLY file in the directory
    ///   - formatType: Format type to cache
    ///   - shDegree: Optional SH degree to cache
    public func setFormat(for url: URL, formatType: PLYFormatDetector.FormatType, shDegree: Int? = nil) {
        let key = directoryKey(for: url)
        
        cacheLock.lock()
        defer { cacheLock.unlock() }
        
        cache[key] = DirectoryFormat(formatType: formatType, shDegree: shDegree, isExplicit: true)
    }
    
    /// Check if format was explicitly set for a directory
    /// - Parameter url: URL to a PLY file in the directory
    /// - Returns: True if format was explicitly set, false if auto-detected or not cached
    public func isFormatExplicit(for url: URL) -> Bool {
        let key = directoryKey(for: url)
        
        cacheLock.lock()
        defer { cacheLock.unlock() }
        
        return cache[key]?.isExplicit ?? false
    }
    
    /// Clear cached format for a directory
    /// - Parameter url: URL to a PLY file in the directory
    public func clearFormat(for url: URL) {
        let key = directoryKey(for: url)
        
        cacheLock.lock()
        defer { cacheLock.unlock() }
        
        cache.removeValue(forKey: key)
    }
    
    /// Clear all cached formats
    public func clearAll() {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        
        cache.removeAll()
    }
    
    /// Get cache statistics
    public func getCacheStats() -> (count: Int, directories: [String]) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        
        return (cache.count, Array(cache.keys))
    }
}

