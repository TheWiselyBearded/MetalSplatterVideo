import Foundation

public class AutodetectSceneReader: SplatSceneReader {
    public enum Error: Swift.Error {
        case cannotDetermineFormat
    }

    private let reader: SplatSceneReader

    public init(_ url: URL) throws {
        switch SplatFileFormat(for: url) {
        case .ply: 
            reader = try SplatPLYSceneReader(url)
        case .compressedPly:
            // Check if format was explicitly set - if so, don't allow fallback
            // This prevents fallback to standard PLY reader when we know it's compressed
            let isExplicit = PLYFormatCache.shared.isFormatExplicit(for: url)
            print("[AutodetectSceneReader] Detected compressed PLY: \(url.lastPathComponent)")
            print("[AutodetectSceneReader] Format explicitly set: \(isExplicit), allowFallback: \(!isExplicit)")
            reader = try CompressedPLYSceneReader(url, allowFallback: !isExplicit)
        case .dotSplat: 
            reader = try DotSplatSceneReader(url)
        case .none: 
            throw Error.cannotDetermineFormat
        }
    }

    public func read(to delegate: any SplatSceneReaderDelegate) {
        reader.read(to: delegate)
    }
}
