#if os(visionOS)

import CompositorServices
import Metal
import MetalSplatter
import os
import SampleBoxRenderer
import simd
import Spatial
import SwiftUI

extension LayerRenderer.Clock.Instant.Duration {
    var timeInterval: TimeInterval {
        let nanoseconds = TimeInterval(components.attoseconds / 1_000_000_000)
        return TimeInterval(components.seconds) + (nanoseconds / TimeInterval(NSEC_PER_SEC))
    }
}

class VisionSceneRenderer {
    private static let log =
        Logger(subsystem: Bundle.main.bundleIdentifier!,
               category: "VisionSceneRenderer")

    let layerRenderer: LayerRenderer
    let device: MTLDevice
    let commandQueue: MTLCommandQueue

    var model: ModelIdentifier?
    var modelRenderer: (any ModelRenderer)?

    let inFlightSemaphore = DispatchSemaphore(value: Constants.maxSimultaneousRenders)

    var lastRotationUpdateTimestamp: Date? = nil
    var rotation: Angle = .zero

    let arSession: ARKitSession
    let worldTracking: WorldTrackingProvider
    
    // Sequence management
    private var sequenceManager: SplatSequenceManager?
    private var isNavigating = false
    private var preloadedRenderer: SplatRenderer?
    private var preloadedFrameIndex: Int = -1
    
    // Renderer pool for reuse to avoid expensive buffer allocations
    private var rendererPool: [SplatRenderer] = []
    private var expectedPointCount: Int = 0

    init(_ layerRenderer: LayerRenderer) {
        self.layerRenderer = layerRenderer
        self.device = layerRenderer.device
        self.commandQueue = self.device.makeCommandQueue()!

        worldTracking = WorldTrackingProvider()
        arSession = ARKitSession()
    }
    
    deinit {
        stopSequence()
        Task { @MainActor in
            SequenceNavigationManager.shared.setVisionRenderer(nil)
            SequenceNavigationManager.shared.shouldShowControls = false
        }
    }

    func load(_ model: ModelIdentifier?) async throws {
        guard model != self.model else { return }
        
        // Clean up previous sequence
        stopSequence()
        self.model = model

        modelRenderer = nil
        switch model {
        case .gaussianSplat(let url):
            let splat = try SplatRenderer(device: device,
                                          colorFormat: layerRenderer.configuration.colorFormat,
                                          depthFormat: layerRenderer.configuration.depthFormat,
                                          sampleCount: 1,
                                          maxViewCount: layerRenderer.properties.viewCount,
                                          maxSimultaneousRenders: Constants.maxSimultaneousRenders)
            try await splat.read(from: url)
            modelRenderer = splat
        case .gaussianSplatSequence(let directoryURL):
            let manager = try SplatSequenceManager(directoryURL: directoryURL)
            self.sequenceManager = manager
            
            // Load the first frame into a new renderer
            if let firstURL = manager.currentFileURL {
                let splat = try getOrCreateRenderer()
                try await splat.read(from: firstURL)
                modelRenderer = splat
                
                // Track expected point count for future pre-allocations
                expectedPointCount = splat.splatCount
                
                // Preload next frame in background
                Task {
                    await preloadNextFrame()
                }
            }
            
            // Register for navigation and show control window
            await MainActor.run {
                SequenceNavigationManager.shared.setVisionRenderer(self)
                SequenceNavigationManager.shared.shouldShowControls = true
            }
        case .compressedPlySequence(let directoryURL):
            // Force compressed format - skip detection
            let manager = try SplatSequenceManager(directoryURL: directoryURL, forceCompressedFormat: true)
            self.sequenceManager = manager
            
            // Load the first frame into a new renderer
            if let firstURL = manager.currentFileURL {
                let splat = try getOrCreateRenderer()
                try await splat.read(from: firstURL)
                modelRenderer = splat
                
                // Track expected point count for future pre-allocations
                expectedPointCount = splat.splatCount
                
                // Preload next frame in background
                Task {
                    await preloadNextFrame()
                }
            }
            
            // Register for navigation and show control window
            await MainActor.run {
                SequenceNavigationManager.shared.setVisionRenderer(self)
                SequenceNavigationManager.shared.shouldShowControls = true
            }
        case .sampleBox:
            modelRenderer = try! SampleBoxRenderer(device: device,
                                                   colorFormat: layerRenderer.configuration.colorFormat,
                                                   depthFormat: layerRenderer.configuration.depthFormat,
                                                   sampleCount: 1,
                                                   maxViewCount: layerRenderer.properties.viewCount,
                                                   maxSimultaneousRenders: Constants.maxSimultaneousRenders)
        case .none:
            break
        }
    }
    
    private func stopSequence() {
        sequenceManager = nil
        preloadedRenderer = nil
        preloadedFrameIndex = -1
        rendererPool.removeAll()
        expectedPointCount = 0
    }
    
    /// Get or create a renderer from the pool to avoid expensive buffer allocations
    private func getOrCreateRenderer() throws -> SplatRenderer {
        if let renderer = rendererPool.popLast() {
            return renderer
        }
        return try SplatRenderer(device: device,
                                colorFormat: layerRenderer.configuration.colorFormat,
                                depthFormat: layerRenderer.configuration.depthFormat,
                                sampleCount: 1,
                                maxViewCount: layerRenderer.properties.viewCount,
                                maxSimultaneousRenders: Constants.maxSimultaneousRenders)
    }
    
    /// Return a renderer to the pool for reuse
    private func returnRendererToPool(_ renderer: SplatRenderer) {
        // Only keep a small pool (2 renderers) to limit memory usage
        if rendererPool.count < 2 {
            rendererPool.append(renderer)
        }
    }
    
    private func preloadNextFrame() async {
        guard let manager = sequenceManager else { return }
        
        let preloadStartTime = Date()
        
        // Calculate next frame index
        let currentIndex = manager.currentFrameNumber - 1
        let nextIndex = (currentIndex + 1) % manager.frameCount
        
        // Skip if already preloaded
        guard preloadedFrameIndex != nextIndex else { return }
        
        // Get next frame URL
        let savedIndex = manager.currentFrameNumber - 1
        manager.advanceToNextFrame()
        guard let nextURL = manager.currentFileURL else {
            // Restore index
            while manager.currentFrameNumber - 1 != savedIndex {
                manager.advanceToPreviousFrame()
            }
            return
        }
        // Restore current index
        while manager.currentFrameNumber - 1 != savedIndex {
            manager.advanceToPreviousFrame()
        }
        
        do {
            // Get file size for logging
            let fileAttributes = try? FileManager.default.attributesOfItem(atPath: nextURL.path)
            let fileSize = (fileAttributes?[.size] as? Int64) ?? 0
            let fileSizeMB = Double(fileSize) / (1024.0 * 1024.0)
            
            let rendererCreateTime = Date()
            let preloaded = try getOrCreateRenderer()
            // Pre-allocate buffers if we know the expected point count
            if expectedPointCount > 0 {
                preloaded.resetAndPrepareForNewFrame(expectedPointCount: expectedPointCount)
            } else {
                preloaded.reset()
            }
            let rendererCreateDuration = -rendererCreateTime.timeIntervalSinceNow
            
            let readStartTime = Date()
            try await preloaded.read(from: nextURL)
            let readDuration = -readStartTime.timeIntervalSinceNow
            
            // Update expected point count if this is the first frame or if it changed
            if expectedPointCount == 0 || abs(preloaded.splatCount - expectedPointCount) > expectedPointCount / 10 {
                expectedPointCount = preloaded.splatCount
            }
            
            preloadedRenderer = preloaded
            preloadedFrameIndex = nextIndex
            
            let totalTime = -preloadStartTime.timeIntervalSinceNow
            Self.log.info("🔄 PRELOAD: \(nextURL.lastPathComponent) | Size: \(String(format: "%.2f", fileSizeMB))MB | Create: \(String(format: "%.3f", rendererCreateDuration))s | Read: \(String(format: "%.3f", readDuration))s | Total: \(String(format: "%.3f", totalTime))s")
        } catch {
            // Preload failed, will load on demand
            preloadedRenderer = nil
            preloadedFrameIndex = -1
            Self.log.warning("⚠️ PRELOAD FAILED: \(nextURL.lastPathComponent) - \(error.localizedDescription)")
        }
    }
    
    func navigateSequenceFrame(forward: Bool) async {
        // Prevent concurrent navigation calls
        guard !isNavigating else {
            Self.log.warning("Navigation already in progress, skipping")
            return
        }
        
        guard let manager = sequenceManager else { 
            Self.log.warning("No sequence manager available")
            return 
        }
        
        isNavigating = true
        defer { isNavigating = false }
        
        let navigationStartTime = Date()
        
        // Advance frame index
        if forward {
            manager.advanceToNextFrame()
        } else {
            manager.advanceToPreviousFrame()
        }
        
        guard let nextURL = manager.currentFileURL else {
            Self.log.warning("No URL found for frame")
            return
        }
        
        let currentFrameIndex = manager.currentFrameNumber - 1
        
        // Check if we have a preloaded renderer for this frame
        if let preloaded = preloadedRenderer, preloadedFrameIndex == currentFrameIndex {
            // Use preloaded renderer - instant swap!
            let swapTime = Date()
            
            // Return old renderer to pool if it exists
            if let oldRenderer = modelRenderer as? SplatRenderer, oldRenderer !== preloaded {
                returnRendererToPool(oldRenderer)
            }
            
            modelRenderer = preloaded
            preloadedRenderer = nil
            preloadedFrameIndex = -1
            let swapDuration = -swapTime.timeIntervalSinceNow
            let totalTime = -navigationStartTime.timeIntervalSinceNow
            
            Self.log.info("⚡ INSTANT: \(nextURL.lastPathComponent) (\(manager.currentFrameNumber)/\(manager.frameCount)) | Swap: \(String(format: "%.3f", swapDuration))s | Total: \(String(format: "%.3f", totalTime))s")
            
            // Preload next frame in background
            Task {
                await preloadNextFrame()
            }
        } else {
            // Load on demand
            let loadStartTime = Date()
            
            do {
                // Get file size for logging
                let fileAttributes = try? FileManager.default.attributesOfItem(atPath: nextURL.path)
                let fileSize = (fileAttributes?[.size] as? Int64) ?? 0
                let fileSizeMB = Double(fileSize) / (1024.0 * 1024.0)
                
                let rendererCreateTime = Date()
                let newSplat = try getOrCreateRenderer()
                // Pre-allocate buffers if we know the expected point count
                if expectedPointCount > 0 {
                    newSplat.resetAndPrepareForNewFrame(expectedPointCount: expectedPointCount)
                } else {
                    newSplat.reset()
                }
                let rendererCreateDuration = -rendererCreateTime.timeIntervalSinceNow
                
                let readStartTime = Date()
                try await newSplat.read(from: nextURL)
                let readDuration = -readStartTime.timeIntervalSinceNow
                
                // Update expected point count if this is the first frame or if it changed
                if expectedPointCount == 0 || abs(newSplat.splatCount - expectedPointCount) > expectedPointCount / 10 {
                    expectedPointCount = newSplat.splatCount
                }
                
                let swapTime = Date()
                // Return old renderer to pool if it exists
                if let oldRenderer = modelRenderer as? SplatRenderer, oldRenderer !== newSplat {
                    returnRendererToPool(oldRenderer)
                }
                modelRenderer = newSplat
                let swapDuration = -swapTime.timeIntervalSinceNow
                
                let totalLoadTime = -loadStartTime.timeIntervalSinceNow
                let totalNavTime = -navigationStartTime.timeIntervalSinceNow
                
                Self.log.info("📦 LOAD: \(nextURL.lastPathComponent) (\(manager.currentFrameNumber)/\(manager.frameCount)) | Size: \(String(format: "%.2f", fileSizeMB))MB | Create: \(String(format: "%.3f", rendererCreateDuration))s | Read: \(String(format: "%.3f", readDuration))s | Swap: \(String(format: "%.3f", swapDuration))s | Load: \(String(format: "%.3f", totalLoadTime))s | Nav: \(String(format: "%.3f", totalNavTime))s")
                
                // Preload next frame in background
                Task {
                    await preloadNextFrame()
                }
            } catch {
                Self.log.error("❌ FAILED: \(nextURL.lastPathComponent) - \(error.localizedDescription)")
            }
        }
    }

    func startRenderLoop() {
        Task {
            do {
                try await arSession.run([worldTracking])
            } catch {
                fatalError("Failed to initialize ARSession")
            }

            let renderThread = Thread {
                self.renderLoop()
            }
            renderThread.name = "Render Thread"
            renderThread.start()
        }
    }

    private func viewports(drawable: LayerRenderer.Drawable, deviceAnchor: DeviceAnchor?) -> [ModelRendererViewportDescriptor] {
        let rotationMatrix = matrix4x4_rotation(radians: Float(rotation.radians),
                                                axis: Constants.rotationAxis)
        let translationMatrix = matrix4x4_translation(0.0, 0.0, Constants.modelCenterZ)
        // Turn common 3D GS PLY files rightside-up. This isn't generally meaningful, it just
        // happens to be a useful default for the most common datasets at the moment.
        let commonUpCalibration = matrix4x4_rotation(radians: .pi, axis: SIMD3<Float>(0, 0, 1))
        // Rotate 180 degrees around Y axis to face the user (model was facing away)
        let faceForwardRotation = matrix4x4_rotation(radians: .pi, axis: SIMD3<Float>(0, 1, 0))
        // Scale down by 2/3
        let scalingMatrix = matrix4x4_scale(2.0/3.0, 2.0/3.0, 2.0/3.0)

        let simdDeviceAnchor = deviceAnchor?.originFromAnchorTransform ?? matrix_identity_float4x4

        return drawable.views.enumerated().map { (index, view) in
            let userViewpointMatrix = (simdDeviceAnchor * view.transform).inverse
            // New method to get the projection matrix (replaces deprecated tangents)
            let projectionMatrix = drawable.computeProjection(viewIndex: index)
            let screenSize = SIMD2(x: Int(view.textureMap.viewport.width),
                                   y: Int(view.textureMap.viewport.height))
            return ModelRendererViewportDescriptor(viewport: view.textureMap.viewport,
                                                   projectionMatrix: projectionMatrix,
                                                   viewMatrix: userViewpointMatrix * translationMatrix * rotationMatrix * faceForwardRotation * scalingMatrix * commonUpCalibration,
                                                   screenSize: screenSize)
        }
    }

    private func updateRotation() {
        let now = Date()
        defer {
            lastRotationUpdateTimestamp = now
        }

        guard let lastRotationUpdateTimestamp else { return }
        rotation += Constants.rotationPerSecond * now.timeIntervalSince(lastRotationUpdateTimestamp)
    }

    func renderFrame() {
        guard let frame = layerRenderer.queryNextFrame() else { return }

        frame.startUpdate()
        frame.endUpdate()

        guard let timing = frame.predictTiming() else { return }
        LayerRenderer.Clock().wait(until: timing.optimalInputTime)

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            fatalError("Failed to create command buffer")
        }

        guard let drawable = frame.queryDrawable() else { return }

        _ = inFlightSemaphore.wait(timeout: DispatchTime.distantFuture)

        frame.startSubmission()

        let time = LayerRenderer.Clock.Instant.epoch.duration(to: drawable.frameTiming.presentationTime).timeInterval
        let deviceAnchor = worldTracking.queryDeviceAnchor(atTimestamp: time)

        drawable.deviceAnchor = deviceAnchor

        let semaphore = inFlightSemaphore
        commandBuffer.addCompletedHandler { (_ commandBuffer)-> Swift.Void in
            semaphore.signal()
        }

        let viewports = self.viewports(drawable: drawable, deviceAnchor: deviceAnchor)

        do {
            try modelRenderer?.render(viewports: viewports,
                                      colorTexture: drawable.colorTextures[0],
                                      colorStoreAction: .store,
                                      depthTexture: drawable.depthTextures[0],
                                      rasterizationRateMap: drawable.rasterizationRateMaps.first,
                                      renderTargetArrayLength: layerRenderer.configuration.layout == .layered ? drawable.views.count : 1,
                                      to: commandBuffer)
        } catch {
            Self.log.error("Unable to render scene: \(error.localizedDescription)")
        }

        drawable.encodePresent(commandBuffer: commandBuffer)

        commandBuffer.commit()

        frame.endSubmission()
    }

    func renderLoop() {
        while true {
            if layerRenderer.state == .invalidated {
                Self.log.warning("Layer is invalidated")
                return
            } else if layerRenderer.state == .paused {
                layerRenderer.waitUntilRunning()
                continue
            } else {
                autoreleasepool {
                    self.renderFrame()
                }
            }
        }
    }
}

#endif // os(visionOS)

