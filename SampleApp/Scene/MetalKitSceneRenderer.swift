#if os(iOS) || os(macOS)

import Metal
import MetalKit
import MetalSplatter
import os
import SampleBoxRenderer
import simd
import SwiftUI

class MetalKitSceneRenderer: NSObject, MTKViewDelegate {
    private static let log =
        Logger(subsystem: Bundle.main.bundleIdentifier!,
               category: "MetalKitSceneRenderer")

    let metalKitView: MTKView
    let device: MTLDevice
    let commandQueue: MTLCommandQueue

    var model: ModelIdentifier?
    var modelRenderer: (any ModelRenderer)?

    let inFlightSemaphore = DispatchSemaphore(value: Constants.maxSimultaneousRenders)

    var lastRotationUpdateTimestamp: Date? = nil
    var rotation: Angle = .zero

    var drawableSize: CGSize = .zero

    // Sequence playback properties
    var sequenceURLs: [URL] = []
    var currentSequenceIndex: Int = 0
    var lastSequenceChangeTimestamp: Date? = nil
    var sequenceInterval: TimeInterval = 1.0 / 30.0  // 30 FPS
    
    // Performance optimizations: renderer reuse and preloading
    private var splatRenderer: SplatRenderer?
    private var nextFrameRenderer: SplatRenderer?
    private var loadingNextFrame = false
    
    // Preload-all frames option
    var preloadAllFrames: Bool = false
    private var preloadedFrames: [Int: SplatRenderer] = [:]
    private var preloadingAllTask: Task<Void, Never>?
    private var preloadProgress: (current: Int, total: Int) = (0, 0)
    var onPreloadProgress: ((Int, Int) -> Void)?  // Callback for progress updates

    init?(_ metalKitView: MTKView) {
        self.device = metalKitView.device!
        guard let queue = self.device.makeCommandQueue() else { return nil }
        self.commandQueue = queue
        self.metalKitView = metalKitView
        metalKitView.colorPixelFormat = MTLPixelFormat.bgra8Unorm_srgb
        metalKitView.depthStencilPixelFormat = MTLPixelFormat.depth32Float
        metalKitView.sampleCount = 1
        metalKitView.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
    }

    func load(_ model: ModelIdentifier?) async throws {
        guard model != self.model else { return }
        self.model = model

        modelRenderer = nil
        sequenceURLs = []
        currentSequenceIndex = 0
        lastSequenceChangeTimestamp = nil
        
        // Clean up preloading
        nextFrameRenderer = nil
        loadingNextFrame = false
        splatRenderer = nil
        preloadedFrames.removeAll()
        preloadingAllTask?.cancel()
        preloadingAllTask = nil
        preloadProgress = (0, 0)
        
        switch model {
        case .gaussianSplat(let url):
            let splat = try await SplatRenderer(device: device,
                                                colorFormat: metalKitView.colorPixelFormat,
                                                depthFormat: metalKitView.depthStencilPixelFormat,
                                                sampleCount: metalKitView.sampleCount,
                                                maxViewCount: 1,
                                                maxSimultaneousRenders: Constants.maxSimultaneousRenders)
            try await splat.read(from: url)
            modelRenderer = splat
        case .gaussianSplatSequence(let urls):
            guard !urls.isEmpty else { break }
            sequenceURLs = urls
            currentSequenceIndex = 0
            lastSequenceChangeTimestamp = Date()
            
            if preloadAllFrames {
                // Load first frame synchronously, then preload all others
                try await loadSequenceFrame(at: 0)
                // Add frame 0 to preloaded cache immediately
                if let renderer = splatRenderer {
                    preloadedFrames[0] = renderer
                }
                preloadingAllTask = Task { [weak self] in
                    await self?.preloadAllFrames()
                }
            } else {
                // Original behavior: load first frame, then preload next
                try await loadSequenceFrame(at: 0)
                loadNextFrameInBackground()
            }
        case .sampleBox:
            modelRenderer = try! await SampleBoxRenderer(device: device,
                                                         colorFormat: metalKitView.colorPixelFormat,
                                                         depthFormat: metalKitView.depthStencilPixelFormat,
                                                         sampleCount: metalKitView.sampleCount,
                                                         maxViewCount: 1,
                                                         maxSimultaneousRenders: Constants.maxSimultaneousRenders)
        case .none:
            break
        }
    }

    private func loadSequenceFrame(at index: Int) async throws {
        guard index < sequenceURLs.count else { return }
        let url = sequenceURLs[index]
        
        let totalStartTime = CFAbsoluteTimeGetCurrent()
        
        // Reuse existing renderer or create once
        let initStartTime = CFAbsoluteTimeGetCurrent()
        if splatRenderer == nil {
            splatRenderer = try await SplatRenderer(device: device,
                                                    colorFormat: metalKitView.colorPixelFormat,
                                                    depthFormat: metalKitView.depthStencilPixelFormat,
                                                    sampleCount: metalKitView.sampleCount,
                                                    maxViewCount: 1,
                                                    maxSimultaneousRenders: Constants.maxSimultaneousRenders)
        }
        let initTime = (CFAbsoluteTimeGetCurrent() - initStartTime) * 1000
        
        // Time file reading/parsing
        let readStartTime = CFAbsoluteTimeGetCurrent()
        try await splatRenderer?.load(from: url)
        let readTime = (CFAbsoluteTimeGetCurrent() - readStartTime) * 1000
        
        let totalTime = (CFAbsoluteTimeGetCurrent() - totalStartTime) * 1000
        
        // Get file size for context
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        let fileSizeMB = Double(fileSize) / (1024 * 1024)
        
        modelRenderer = splatRenderer
        currentSequenceIndex = index
        
        let logMessage = """
            📊 Splat [\(index + 1)/\(self.sequenceURLs.count)] \(url.lastPathComponent)
               File: \(String(format: "%.2f", fileSizeMB)) MB
               Init: \(String(format: "%.1f", initTime)) ms
               Read: \(String(format: "%.1f", readTime)) ms
               Total: \(String(format: "%.1f", totalTime)) ms
            """
        print(logMessage)
        Self.log.info("\(logMessage)")
    }

    private func updateSequence() {
        guard !sequenceURLs.isEmpty else { return }
        
        let now = Date()
        guard let lastChange = lastSequenceChangeTimestamp else {
            lastSequenceChangeTimestamp = now
            // Start loading next frame immediately
            loadNextFrameInBackground()
            return
        }
        
        if now.timeIntervalSince(lastChange) >= sequenceInterval {
            lastSequenceChangeTimestamp = now
            let nextIndex = (currentSequenceIndex + 1) % sequenceURLs.count
            
            // Check if we have all frames preloaded
            if let preloaded = preloadedFrames[nextIndex] {
                // Use preloaded frame from memory
                let url = sequenceURLs[nextIndex]
                let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
                let fileSizeMB = Double(fileSize) / (1024 * 1024)
                
                // Swap renderers (don't reset old one since it's in the preloaded cache)
                splatRenderer = preloaded
                modelRenderer = preloaded
                currentSequenceIndex = nextIndex
                
                let logMessage = """
                    📊 Splat [\(nextIndex + 1)/\(self.sequenceURLs.count)] \(url.lastPathComponent) (preloaded)
                       File: \(String(format: "%.2f", fileSizeMB)) MB
                       Total: 0.0 ms
                    """
                print(logMessage)
                Self.log.info("\(logMessage)")
                
                // Don't need to load next frame - it's already in memory!
            } else if preloadAllFrames {
                // Preload mode is on but frame isn't ready yet - skip this frame change
                // Don't fall back to synchronous loading as it causes race conditions
                return
            } else if let preloaded = nextFrameRenderer {
                // Fallback to single-frame preloading
                let url = sequenceURLs[nextIndex]
                let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
                let fileSizeMB = Double(fileSize) / (1024 * 1024)
                
                // Swap renderers
                let oldRenderer = splatRenderer
                splatRenderer = preloaded
                modelRenderer = preloaded
                currentSequenceIndex = nextIndex
                nextFrameRenderer = nil
                loadingNextFrame = false
                
                // Log the swap - use print to ensure it shows up
                let logMessage = """
                    📊 Splat [\(nextIndex + 1)/\(self.sequenceURLs.count)] \(url.lastPathComponent) (preloaded)
                       File: \(String(format: "%.2f", fileSizeMB)) MB
                       Total: 0.0 ms
                    """
                print(logMessage)
                Self.log.info("\(logMessage)")
                
                // Clean up old renderer and start loading next frame
                oldRenderer?.reset()
                loadNextFrameInBackground()
            } else {
                // Fallback to synchronous load
                Task {
                    do {
                        try await loadSequenceFrame(at: nextIndex)
                        loadNextFrameInBackground()
                    } catch {
                        Self.log.error("Failed to load sequence frame: \(error.localizedDescription)")
                    }
                }
            }
        }
    }
    
    private func loadNextFrameInBackground() {
        guard !loadingNextFrame else { return }
        guard !sequenceURLs.isEmpty else { return }
        
        loadingNextFrame = true
        let nextIndex = (currentSequenceIndex + 1) % sequenceURLs.count
        let url = sequenceURLs[nextIndex]
        
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            do {
                // Create a new renderer for background loading to avoid conflicts with active rendering
                let renderer = try await SplatRenderer(device: self.device,
                                                      colorFormat: self.metalKitView.colorPixelFormat,
                                                      depthFormat: self.metalKitView.depthStencilPixelFormat,
                                                      sampleCount: self.metalKitView.sampleCount,
                                                      maxViewCount: 1,
                                                      maxSimultaneousRenders: Constants.maxSimultaneousRenders)
                
                try await renderer.load(from: url)
                
                await MainActor.run {
                    self.nextFrameRenderer = renderer
                    self.loadingNextFrame = false
                }
            } catch {
                await MainActor.run {
                    self.loadingNextFrame = false
                    Self.log.error("Failed to preload next frame: \(error.localizedDescription)")
                }
            }
        }
    }
    
    private func preloadAllFrames() async {
        guard !sequenceURLs.isEmpty else { return }
        // Only preload if we haven't loaded all frames yet (frame 0 is already loaded)
        guard preloadedFrames.count < sequenceURLs.count else { return }
        
        let totalFrames = sequenceURLs.count
        preloadProgress = (0, totalFrames)
        
        Self.log.info("🔄 Preloading all \(totalFrames) frames into memory...")
        print("🔄 Preloading all \(totalFrames) frames into memory...")
        let startTime = CFAbsoluteTimeGetCurrent()
        
        // Load all frames in parallel
        await withTaskGroup(of: (Int, SplatRenderer?).self) { group in
            for index in 0..<totalFrames {
                // Skip index 0 since it's already loaded
                guard index != 0 else { continue }
                
                group.addTask { [weak self] in
                    guard let self = self else { return (index, nil) }
                    do {
                        let renderer = try await SplatRenderer(
                            device: self.device,
                            colorFormat: self.metalKitView.colorPixelFormat,
                            depthFormat: self.metalKitView.depthStencilPixelFormat,
                            sampleCount: self.metalKitView.sampleCount,
                            maxViewCount: 1,
                            maxSimultaneousRenders: Constants.maxSimultaneousRenders
                        )
                        try await renderer.load(from: self.sequenceURLs[index])
                        
                        await MainActor.run {
                            self.preloadedFrames[index] = renderer
                            self.preloadProgress.current += 1
                            self.onPreloadProgress?(self.preloadProgress.current, self.preloadProgress.total)
                        }
                        
                        return (index, renderer)
                    } catch {
                        Self.log.error("Failed to preload frame \(index): \(error.localizedDescription)")
                        return (index, nil)
                    }
                }
            }
            
            // Wait for all to complete
            for await (index, renderer) in group {
                if renderer != nil {
                    // Already stored in the task
                }
            }
        }
        
        let totalTime = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        let loadedCount = preloadedFrames.count
        Self.log.info("✅ Preloaded all \(loadedCount)/\(totalFrames) frames in \(String(format: "%.1f", totalTime)) ms")
        print("✅ Preloaded all \(loadedCount)/\(totalFrames) frames in \(String(format: "%.1f", totalTime)) ms")
    }

    private var viewport: ModelRendererViewportDescriptor {
        let projectionMatrix = matrix_perspective_right_hand(fovyRadians: Float(Constants.fovy.radians),
                                                             aspectRatio: Float(drawableSize.width / drawableSize.height),
                                                             nearZ: 0.1,
                                                             farZ: 100.0)

        let rotationMatrix = matrix4x4_rotation(radians: Float(rotation.radians),
                                                axis: Constants.rotationAxis)
        let translationMatrix = matrix4x4_translation(0.0, 0.0, Constants.modelCenterZ)
        // Turn common 3D GS PLY files rightside-up. This isn't generally meaningful, it just
        // happens to be a useful default for the most common datasets at the moment.
        let commonUpCalibration = matrix4x4_rotation(radians: .pi, axis: SIMD3<Float>(0, 0, 1))

        let viewport = MTLViewport(originX: 0, originY: 0, width: drawableSize.width, height: drawableSize.height, znear: 0, zfar: 1)

        return ModelRendererViewportDescriptor(viewport: viewport,
                                               projectionMatrix: projectionMatrix,
                                               viewMatrix: translationMatrix * rotationMatrix * commonUpCalibration,
                                               screenSize: SIMD2(x: Int(drawableSize.width), y: Int(drawableSize.height)))
    }

    private func updateRotation() {
        let now = Date()
        defer {
            lastRotationUpdateTimestamp = now
        }

        guard let lastRotationUpdateTimestamp else { return }
        rotation += Constants.rotationPerSecond * now.timeIntervalSince(lastRotationUpdateTimestamp)
    }

    func draw(in view: MTKView) {
        // Update sequence if we're playing a sequence
        updateSequence()
        
        guard let modelRenderer else { return }
        guard let drawable = view.currentDrawable else { return }

        _ = inFlightSemaphore.wait(timeout: DispatchTime.distantFuture)

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            inFlightSemaphore.signal()
            return
        }

        let semaphore = inFlightSemaphore
        commandBuffer.addCompletedHandler { (_ commandBuffer)-> Swift.Void in
            semaphore.signal()
        }

        do {
            try modelRenderer.render(viewports: [viewport],
                                     colorTexture: view.multisampleColorTexture ?? drawable.texture,
                                     colorStoreAction: view.multisampleColorTexture == nil ? .store : .multisampleResolve,
                                     depthTexture: view.depthStencilTexture,
                                     rasterizationRateMap: nil,
                                     renderTargetArrayLength: 0,
                                     to: commandBuffer)
        } catch {
            Self.log.error("Unable to render scene: \(error.localizedDescription)")
        }

        commandBuffer.present(drawable)

        commandBuffer.commit()
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        drawableSize = size
    }
}

#endif // os(iOS) || os(macOS)
