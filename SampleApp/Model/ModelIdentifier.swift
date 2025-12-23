import Foundation

enum ModelIdentifier: Equatable, Hashable, Codable, CustomStringConvertible {
    case gaussianSplat(URL)
    case gaussianSplatSequence([URL])
    case deltaEncodedSequence(URL)  // Directory containing keyframe_*.ply.gz and deltas.npz
    case sampleBox

    var description: String {
        switch self {
        case .gaussianSplat(let url):
            "Gaussian Splat: \(url.path)"
        case .gaussianSplatSequence(let urls):
            "Gaussian Splat Sequence: \(urls.count) files"
        case .deltaEncodedSequence(let url):
            "Delta-Encoded Sequence: \(url.lastPathComponent)"
        case .sampleBox:
            "Sample Box"
        }
    }
}
