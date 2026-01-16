import Foundation
import SplatIO

class SplatSequenceManager {
    private let directoryURL: URL
    private let fileURLs: [URL]
    private var currentIndex: Int = 0
    private let forceCompressedFormat: Bool
    
    var currentFileURL: URL? {
        guard !fileURLs.isEmpty else { return nil }
        return fileURLs[currentIndex]
    }
    
    var frameCount: Int {
        fileURLs.count
    }
    
    var currentFrameNumber: Int {
        currentIndex + 1
    }
    
    init(directoryURL: URL, forceCompressedFormat: Bool = false) throws {
        self.directoryURL = directoryURL
        self.forceCompressedFormat = forceCompressedFormat
        
        // Get all PLY and splat files from the directory (non-recursive)
        let fileManager = FileManager.default
        let resourceKeys: [URLResourceKey] = [.isRegularFileKey]
        
        guard let contents = try? fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: resourceKeys,
            options: [.skipsHiddenFiles]
        ) else {
            throw Error.cannotReadDirectory
        }
        
        var urls: [URL] = []
        for url in contents {
            guard let resourceValues = try? url.resourceValues(forKeys: Set(resourceKeys)),
                  resourceValues.isRegularFile == true else {
                continue
            }
            
            // Check if it's a PLY or splat file
            if SplatFileFormat(for: url) != nil {
                urls.append(url)
            }
        }
        
        // Sort files alphabetically by filename
        self.fileURLs = urls.sorted { $0.lastPathComponent < $1.lastPathComponent }
        
        guard !self.fileURLs.isEmpty else {
            throw Error.noValidFilesFound
        }
        
        // Detect and cache format for the entire directory
        // Assumes all files in directory share the same format
        if forceCompressedFormat {
            // Explicitly set format as compressed for ALL PLY files in the directory
            for plyFile in fileURLs where plyFile.pathExtension.lowercased() == "ply" {
                PLYFormatCache.shared.setFormat(
                    for: plyFile,
                    formatType: .compressed,
                    shDegree: nil
                )
            }
        } else if let firstPLYFile = fileURLs.first(where: { $0.pathExtension.lowercased() == "ply" }) {
            // Auto-detect format from first file
            let detection = PLYFormatCache.shared.getFormat(for: firstPLYFile)
            // Format is now cached for the entire directory, avoiding redundant detection
        }
    }
    
    func advanceToNextFrame() {
        guard !fileURLs.isEmpty else { return }
        currentIndex = (currentIndex + 1) % fileURLs.count
    }
    
    func advanceToPreviousFrame() {
        guard !fileURLs.isEmpty else { return }
        currentIndex = (currentIndex - 1 + fileURLs.count) % fileURLs.count
    }
    
    func reset() {
        currentIndex = 0
    }
    
    enum Error: LocalizedError {
        case cannotReadDirectory
        case noValidFilesFound
        
        var errorDescription: String? {
            switch self {
            case .cannotReadDirectory:
                "Cannot read directory"
            case .noValidFilesFound:
                "No valid PLY or splat files found in directory"
            }
        }
    }
}

