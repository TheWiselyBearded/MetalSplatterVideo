import SwiftUI
import RealityKit
import UniformTypeIdentifiers
import CoreML
import CoreImage

struct ContentView: View {
    @State private var isPickingFile = false
    @State private var isPickingDirectory = false
    @State private var isPickingImage = false
    @State private var isProcessing = false
    @State private var sharpModel: MLModel?
    @State private var modelLoadStatus: String?

#if os(macOS)
    @Environment(\.openWindow) private var openWindow
#elseif os(iOS)
    @State private var navigationPath = NavigationPath()

    private func openWindow(value: ModelIdentifier) {
        navigationPath.append(value)
    }
#elseif os(visionOS)
    @Environment(\.openImmersiveSpace) var openImmersiveSpace
    @Environment(\.dismissImmersiveSpace) var dismissImmersiveSpace

    @State var immersiveSpaceIsShown = false

    private func openWindow(value: ModelIdentifier) {
        Task {
            switch await openImmersiveSpace(value: value) {
            case .opened:
                immersiveSpaceIsShown = true
            case .error, .userCancelled:
                break
            @unknown default:
                break
            }
        }
    }
#endif

    var body: some View {
#if os(macOS) || os(visionOS)
        mainView
#elseif os(iOS)
        NavigationStack(path: $navigationPath) {
            mainView
                .navigationDestination(for: ModelIdentifier.self) { modelIdentifier in
                    MetalKitSceneView(modelIdentifier: modelIdentifier)
                        .navigationTitle(modelIdentifier.description)
                }
        }
#endif // os(iOS)
    }

    private func findPLYFiles(in directoryURL: URL) -> [URL] {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: directoryURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants]
        ) else {
            return []
        }
        
        var plyURLs: [URL] = []
        for case let fileURL as URL in enumerator {
            if fileURL.pathExtension.lowercased() == "ply" {
                plyURLs.append(fileURL)
            }
        }
        
        // Sort by filename for consistent ordering
        return plyURLs.sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    private func loadModelIfNeeded() async throws -> MLModel {
        if let model = sharpModel { return model }
        
        guard let modelURL = Bundle.main.url(forResource: "SHARP_VisionPro", withExtension: "mlmodelc") ??
              Bundle.main.url(forResource: "SHARP_VisionPro", withExtension: "mlpackage") else {
            throw NSError(domain: "SHARP", code: 1, userInfo: [NSLocalizedDescriptionKey: "Model not found in bundle"])
        }
        
        let config = MLModelConfiguration()
        config.computeUnits = .all
        let model = try await MLModel.load(contentsOf: modelURL, configuration: config)
        await MainActor.run { sharpModel = model }
        return model
    }
    
    private func processImageWithSHARP(url: URL) {
        isProcessing = true
        modelLoadStatus = "Loading model..."
        
        Task {
            do {
                let model = try await loadModelIfNeeded()
                await MainActor.run { modelLoadStatus = "Processing image..." }
                
                // Load and resize image to 1536x1536
                guard let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil),
                      let cgImage = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
                    throw NSError(domain: "SHARP", code: 2, userInfo: [NSLocalizedDescriptionKey: "Failed to load image"])
                }
                
                let inputSize = 1536
                let ciImage = CIImage(cgImage: cgImage)
                let scale = CGFloat(inputSize) / max(ciImage.extent.width, ciImage.extent.height)
                let scaledImage = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                
                let context = CIContext()
                guard let resizedCGImage = context.createCGImage(scaledImage, from: CGRect(x: 0, y: 0, width: inputSize, height: inputSize)) else {
                    throw NSError(domain: "SHARP", code: 3, userInfo: [NSLocalizedDescriptionKey: "Failed to resize image"])
                }
                
                // Convert to MLMultiArray (1 x 3 x 1536 x 1536)
                let colorImage = try MLMultiArray(shape: [1, 3, NSNumber(value: inputSize), NSNumber(value: inputSize)], dataType: .float32)
                let pixelData = CFDataGetBytePtr(resizedCGImage.dataProvider!.data!)!
                let bytesPerPixel = resizedCGImage.bitsPerPixel / 8
                let bytesPerRow = resizedCGImage.bytesPerRow
                
                for y in 0..<inputSize {
                    for x in 0..<inputSize {
                        let offset = y * bytesPerRow + x * bytesPerPixel
                        let r = Float(pixelData[offset]) / 255.0
                        let g = Float(pixelData[offset + 1]) / 255.0
                        let b = Float(pixelData[offset + 2]) / 255.0
                        
                        colorImage[[0, 0, y, x] as [NSNumber]] = NSNumber(value: r)
                        colorImage[[0, 1, y, x] as [NSNumber]] = NSNumber(value: g)
                        colorImage[[0, 2, y, x] as [NSNumber]] = NSNumber(value: b)
                    }
                }
                
                // Disparity factor (f_px / width) - estimate focal length
                let disparityFactor = try MLMultiArray(shape: [1], dataType: .float32)
                disparityFactor[0] = NSNumber(value: 1.0) // Default focal length ratio
                
                // Run inference
                let inputFeatures = try MLDictionaryFeatureProvider(dictionary: [
                    "color_image": MLFeatureValue(multiArray: colorImage),
                    "disparity_factor": MLFeatureValue(multiArray: disparityFactor)
                ])
                
                await MainActor.run { modelLoadStatus = "Running inference..." }
                let output = try await model.prediction(from: inputFeatures)
                
                // Extract outputs - positions and colors
                guard let positions = output.featureValue(for: "var_5461")?.multiArrayValue,
                      let colors = output.featureValue(for: "var_5465")?.multiArrayValue else {
                    throw NSError(domain: "SHARP", code: 4, userInfo: [NSLocalizedDescriptionKey: "Missing model outputs"])
                }
                
                await MainActor.run { modelLoadStatus = "Generating PLY..." }
                
                // Generate PLY file
                let plyURL = try generatePLY(positions: positions, colors: colors)
                
                await MainActor.run {
                    modelLoadStatus = "✅ Done!"
                    isProcessing = false
                    openWindow(value: ModelIdentifier.gaussianSplat(plyURL))
                }
                
            } catch {
                await MainActor.run {
                    modelLoadStatus = "❌ \(error.localizedDescription)"
                    isProcessing = false
                }
            }
        }
    }
    
    private func generatePLY(positions: MLMultiArray, colors: MLMultiArray) throws -> URL {
        let numPoints = positions.shape[1].intValue
        
        var plyContent = """
ply
format ascii 1.0
element vertex \(numPoints)
property float x
property float y
property float z
property uchar red
property uchar green
property uchar blue
end_header

"""
        
        for i in 0..<numPoints {
            let x = positions[[0, i, 0] as [NSNumber]].floatValue
            let y = positions[[0, i, 1] as [NSNumber]].floatValue
            let z = positions[[0, i, 2] as [NSNumber]].floatValue
            
            let r = min(255, max(0, Int(colors[[0, i, 0] as [NSNumber]].floatValue * 255)))
            let g = min(255, max(0, Int(colors[[0, i, 1] as [NSNumber]].floatValue * 255)))
            let b = min(255, max(0, Int(colors[[0, i, 2] as [NSNumber]].floatValue * 255)))
            
            plyContent += "\(x) \(y) \(z) \(r) \(g) \(b)\n"
        }
        
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent("sharp_output_\(UUID().uuidString).ply")
        try plyContent.write(to: tempURL, atomically: true, encoding: .utf8)
        return tempURL
    }

    @ViewBuilder
    var mainView: some View {
        VStack {
            Spacer()

            Text("MetalSplatter SampleApp")

            Spacer()

            Button("Read Scene File") {
                isPickingFile = true
            }
            .padding()
            .buttonStyle(.borderedProminent)
            .disabled(isPickingFile)
#if os(visionOS)
            .disabled(immersiveSpaceIsShown)
#endif
            .fileImporter(isPresented: $isPickingFile,
                          allowedContentTypes: [
                            UTType(filenameExtension: "ply")!,
                            UTType(filenameExtension: "splat")!,
                          ]) {
                isPickingFile = false
                switch $0 {
                case .success(let url):
                    _ = url.startAccessingSecurityScopedResource()
                    Task {
                        // This is a sample app. In a real app, this should be more tightly scoped, not using a silly timer.
                        try await Task.sleep(for: .seconds(10))
                        url.stopAccessingSecurityScopedResource()
                    }
                    openWindow(value: ModelIdentifier.gaussianSplat(url))
                case .failure:
                    break
                }
            }

            Button("Read PLY Directory (Sequence)") {
                isPickingDirectory = true
            }
            .padding()
            .buttonStyle(.borderedProminent)
            .disabled(isPickingDirectory)
#if os(visionOS)
            .disabled(immersiveSpaceIsShown)
#endif
            .fileImporter(isPresented: $isPickingDirectory,
                          allowedContentTypes: [.folder]) {
                isPickingDirectory = false
                switch $0 {
                case .success(let directoryURL):
                    _ = directoryURL.startAccessingSecurityScopedResource()
                    // Find all PLY files in the directory
                    let plyURLs = findPLYFiles(in: directoryURL)
                    if !plyURLs.isEmpty {
                        // Keep access for a longer time since we're cycling through files
                        Task {
                            try await Task.sleep(for: .seconds(300))
                            directoryURL.stopAccessingSecurityScopedResource()
                        }
                        openWindow(value: ModelIdentifier.gaussianSplatSequence(plyURLs))
                    } else {
                        modelLoadStatus = "❌ No PLY files found in directory"
                    }
                case .failure:
                    break
                }
            }

            Spacer()

        Button("Show Sample Box") {
            openWindow(value: ModelIdentifier.sampleBox)
        }
        .padding()
        .buttonStyle(.borderedProminent)
#if os(visionOS)
        .disabled(immersiveSpaceIsShown)
#endif

        Spacer()

        Button(isProcessing ? "Processing..." : "SHARP: Image → 3D") {
            isPickingImage = true
        }
        .padding()
        .buttonStyle(.borderedProminent)
        .disabled(isProcessing)
#if os(visionOS)
        .disabled(immersiveSpaceIsShown)
#endif
        .fileImporter(isPresented: $isPickingImage,
                      allowedContentTypes: [.png, .jpeg]) { result in
            isPickingImage = false
            if case .success(let url) = result {
                _ = url.startAccessingSecurityScopedResource()
                processImageWithSHARP(url: url)
            }
        }

        if let status = modelLoadStatus {
            Text(status)
                .font(.caption)
                .foregroundColor(status.contains("✅") ? .green : (status.contains("❌") ? .red : .secondary))
                .padding(.horizontal)
        }

        Spacer()

#if os(visionOS)
            Button("Dismiss Immersive Space") {
                Task {
                    await dismissImmersiveSpace()
                    immersiveSpaceIsShown = false
                }
            }
            .disabled(!immersiveSpaceIsShown)

            Spacer()
#endif // os(visionOS)
        }
    }
}
