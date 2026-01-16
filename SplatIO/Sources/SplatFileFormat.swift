import Foundation

public enum SplatFileFormat {
    case ply
    case compressedPly
    case dotSplat

    public init?(for url: URL) {
        switch url.pathExtension.lowercased() {
        case "ply":
            // Use format cache to avoid redundant detection
            let detection = PLYFormatCache.shared.getFormat(for: url)
            switch detection.formatType {
            case .compressed:
                self = .compressedPly
            case .standard, .unknown:
                self = .ply
            }
        case "splat": 
            self = .dotSplat
        default: 
            return nil
        }
    }
    
    /// Initialize with explicit format (bypasses detection)
    public init?(for url: URL, formatType: PLYFormatDetector.FormatType) {
        switch url.pathExtension.lowercased() {
        case "ply":
            switch formatType {
            case .compressed:
                self = .compressedPly
            case .standard, .unknown:
                self = .ply
            }
        case "splat":
            self = .dotSplat
        default:
            return nil
        }
    }
}
