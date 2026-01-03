import Foundation

enum ModelIdentifier: Equatable, Hashable, Codable, CustomStringConvertible {
    case gaussianSplat(URL)
    case gaussianSplatSequence(URL)
    case sampleBox

    var description: String {
        switch self {
        case .gaussianSplat(let url):
            "Gaussian Splat: \(url.path)"
        case .gaussianSplatSequence(let url):
            "Gaussian Splat Sequence: \(url.path)"
        case .sampleBox:
            "Sample Box"
        }
    }
}
