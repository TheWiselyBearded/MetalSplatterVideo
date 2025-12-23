#if os(visionOS)

import CompositorServices
import Metal
import MetalSplatter
import os
import SampleBoxRenderer
import simd
import Spatial
import SplatIO
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
    
    // Delta sequence decoder
    private var deltaDecoder: DeltaSequenceDecoder?
    private var deltaFrameIndices: [Int] = []
    private var currentDeltaFrameIndex: Int = 0

    init(_ layerRenderer: LayerRenderer) {
        self.layerRenderer = layerRenderer
        self.device = layerRenderer.device
        self.commandQueue = self.device.makeCommandQueue()!

        worldTracking = WorldTrackingProvider()
        arSession = ARKitSession()
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
        
        // Clean up delta sequence
        deltaDecoder = nil
        deltaFrameIndices = []
        currentDeltaFrameIndex = 0
        
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
        case .deltaEncodedSequence(let directoryURL):
            let decoder = DeltaSequenceDecoder(directoryURL: directoryURL)
            try await decoder.load()
            
            deltaDecoder = decoder
            deltaFrameIndices = decoder.frameIndices
            currentDeltaFrameIndex = 0
            lastSequenceChangeTimestamp = Date()
            
            Self.log.info("📦 Loaded delta sequence metadata: \(decoder.frameCount) frames")
            print("📦 Loaded delta sequence metadata: \(decoder.frameCount) frames")
            
            if preloadAllFrames {
                // Preload all decoded frames
                try await loadDeltaFrame(at: 0)
                // Add frame 0 to preloaded cache immediately
                if let renderer = splatRenderer {
                    preloadedFrames[0] = renderer
                }
                preloadingAllTask = Task { [weak self] in
                    await self?.preloadAllDeltaFrames()
                }
            } else {
                // Load first frame, then preload next
                try await loadDeltaFrame(at: 0)
                loadNextDeltaFrameInBackground()
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

    private func loadSequenceFrame(at index: Int) async throws {
        guard index < sequenceURLs.count else { return }
        let url = sequenceURLs[index]
        
        let totalStartTime = CFAbsoluteTimeGetCurrent()
        
        // Reuse existing renderer or create once
        let initStartTime = CFAbsoluteTimeGetCurrent()
        if splatRenderer == nil {
            splatRenderer = try SplatRenderer(device: device,
                                              colorFormat: layerRenderer.configuration.colorFormat,
                                              depthFormat: layerRenderer.configuration.depthFormat,
                                              sampleCount: 1,
                                              maxViewCount: layerRenderer.properties.viewCount,
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
                // Create a new renderer for background loading to avoid conflicts
                let renderer = try SplatRenderer(device: self.device,
                                                colorFormat: self.layerRenderer.configuration.colorFormat,
                                                depthFormat: self.layerRenderer.configuration.depthFormat,
                                                sampleCount: 1,
                                                maxViewCount: self.layerRenderer.properties.viewCount,
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
                        let renderer = try SplatRenderer(
                            device: self.device,
                            colorFormat: self.layerRenderer.configuration.colorFormat,
                            depthFormat: self.layerRenderer.configuration.depthFormat,
                            sampleCount: 1,
                            maxViewCount: self.layerRenderer.properties.viewCount,
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
    
    // MARK: - Delta Sequence Support
    
    private func loadDeltaFrame(at index: Int) async throws {
        guard let decoder = deltaDecoder else { return }
        guard index < deltaFrameIndices.count else { return }
        
        let frameIndex = deltaFrameIndices[index]
        let totalStartTime = CFAbsoluteTimeGetCurrent()
        
        let decodeStartTime = CFAbsoluteTimeGetCurrent()
        let points = try await decoder.getFrame(at: frameIndex)
        let decodeTime = (CFAbsoluteTimeGetCurrent() - decodeStartTime) * 1000
        
        let initStartTime = CFAbsoluteTimeGetCurrent()
        if splatRenderer == nil {
            splatRenderer = try SplatRenderer(device: device,
                                              colorFormat: layerRenderer.configuration.colorFormat,
                                              depthFormat: layerRenderer.configuration.depthFormat,
                                              sampleCount: 1,
                                              maxViewCount: layerRenderer.properties.viewCount,
                                              maxSimultaneousRenders: Constants.maxSimultaneousRenders)
        }
        let initTime = (CFAbsoluteTimeGetCurrent() - initStartTime) * 1000
        
        let loadStartTime = CFAbsoluteTimeGetCurrent()
        try splatRenderer?.load(points: points)
        let loadTime = (CFAbsoluteTimeGetCurrent() - loadStartTime) * 1000
        
        modelRenderer = splatRenderer
        currentDeltaFrameIndex = index
        
        let totalTime = (CFAbsoluteTimeGetCurrent() - totalStartTime) * 1000
        
        // Estimate memory size (approximate: ~32 bytes per point for renderer buffers)
        let estimatedSizeMB = Double(points.count * 32) / (1024 * 1024)
        
        let logMessage = """
            📊 Delta Frame [\(index + 1)/\(deltaFrameIndices.count)] frame_\(frameIndex)
               Points: \(points.count) (~\(String(format: "%.2f", estimatedSizeMB)) MB)
               Decode: \(String(format: "%.1f", decodeTime)) ms
               Init: \(String(format: "%.1f", initTime)) ms
               Load: \(String(format: "%.1f", loadTime)) ms
               Total: \(String(format: "%.1f", totalTime)) ms
            """
        print(logMessage)
        Self.log.info("\(logMessage)")
    }
    
    private func loadNextDeltaFrameInBackground() {
        guard !loadingNextFrame else { return }
        guard !deltaFrameIndices.isEmpty else { return }
        guard let decoder = deltaDecoder else { return }
        
        loadingNextFrame = true
        let nextIndex = (currentDeltaFrameIndex + 1) % deltaFrameIndices.count
        let frameIndex = deltaFrameIndices[nextIndex]
        
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            do {
                let points = try await decoder.getFrame(at: frameIndex)
                
                let renderer = try SplatRenderer(device: self.device,
                                                colorFormat: self.layerRenderer.configuration.colorFormat,
                                                depthFormat: self.layerRenderer.configuration.depthFormat,
                                                sampleCount: 1,
                                                maxViewCount: self.layerRenderer.properties.viewCount,
                                                maxSimultaneousRenders: Constants.maxSimultaneousRenders)
                
                try renderer.load(points: points)
                
                await MainActor.run {
                    self.nextFrameRenderer = renderer
                    self.loadingNextFrame = false
                }
            } catch {
                await MainActor.run {
                    self.loadingNextFrame = false
                    Self.log.error("Failed to preload next delta frame: \(error.localizedDescription)")
                }
            }
        }
    }
    
    private func preloadAllDeltaFrames() async {
        guard !deltaFrameIndices.isEmpty else { return }
        guard let decoder = deltaDecoder else { return }
        guard preloadedFrames.count < deltaFrameIndices.count else { return }
        
        let totalFrames = deltaFrameIndices.count
        preloadProgress = (0, totalFrames)
        
        Self.log.info("🔄 Preloading all \(totalFrames) delta frames into memory...")
        print("🔄 Preloading all \(totalFrames) delta frames into memory...")
        let startTime = CFAbsoluteTimeGetCurrent()
        
        var totalPoints = 0
        var decodeTimes: [TimeInterval] = []
        var loadTimes: [TimeInterval] = []
        
        await withTaskGroup(of: (Int, SplatRenderer?, Int, TimeInterval, TimeInterval).self) { group in
            for index in 0..<totalFrames {
                guard index != 0 else { continue }
                
                group.addTask { [weak self] in
                    guard let self = self else { return (index, nil, 0, 0, 0) }
                    do {
                        let frameIndex = self.deltaFrameIndices[index]
                        
                        let decodeStart = CFAbsoluteTimeGetCurrent()
                        let points = try await decoder.getFrame(at: frameIndex)
                        let decodeTime = (CFAbsoluteTimeGetCurrent() - decodeStart) * 1000
                        
                        let loadStart = CFAbsoluteTimeGetCurrent()
                        let renderer = try SplatRenderer(
                            device: self.device,
                            colorFormat: self.layerRenderer.configuration.colorFormat,
                            depthFormat: self.layerRenderer.configuration.depthFormat,
                            sampleCount: 1,
                            maxViewCount: self.layerRenderer.properties.viewCount,
                            maxSimultaneousRenders: Constants.maxSimultaneousRenders
                        )
                        try renderer.load(points: points)
                        let loadTime = (CFAbsoluteTimeGetCurrent() - loadStart) * 1000
                        
                        await MainActor.run {
                            self.preloadedFrames[index] = renderer
                            self.preloadProgress.current += 1
                            self.onPreloadProgress?(self.preloadProgress.current, self.preloadProgress.total)
                        }
                        
                        return (index, renderer, points.count, decodeTime, loadTime)
                    } catch {
                        Self.log.error("Failed to preload delta frame \(index): \(error.localizedDescription)")
                        return (index, nil, 0, 0, 0)
                    }
                }
            }
            
            // Collect stats
            for await (index, renderer, pointCount, decodeTime, loadTime) in group {
                if renderer != nil {
                    totalPoints += pointCount
                    decodeTimes.append(decodeTime)
                    loadTimes.append(loadTime)
                }
            }
        }
        
        let totalTime = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
        let loadedCount = preloadedFrames.count
        let avgDecodeTime = decodeTimes.isEmpty ? 0 : decodeTimes.reduce(0, +) / Double(decodeTimes.count)
        let avgLoadTime = loadTimes.isEmpty ? 0 : loadTimes.reduce(0, +) / Double(loadTimes.count)
        let estimatedSizeMB = Double(totalPoints * 32) / (1024 * 1024)
        
        Self.log.info("✅ Preloaded all \(loadedCount)/\(totalFrames) delta frames in \(String(format: "%.1f", totalTime)) ms")
        print("✅ Preloaded all \(loadedCount)/\(totalFrames) delta frames in \(String(format: "%.1f", totalTime)) ms")
        print("   Total points: \(totalPoints) (~\(String(format: "%.2f", estimatedSizeMB)) MB)")
        print("   Avg decode: \(String(format: "%.1f", avgDecodeTime)) ms, Avg load: \(String(format: "%.1f", avgLoadTime)) ms")
    }
    
    private func updateDeltaSequence() {
        guard !deltaFrameIndices.isEmpty else { return }
        
        let now = Date()
        guard let lastChange = lastSequenceChangeTimestamp else {
            lastSequenceChangeTimestamp = now
            loadNextDeltaFrameInBackground()
            return
        }
        
        if now.timeIntervalSince(lastChange) >= sequenceInterval {
            lastSequenceChangeTimestamp = now
            let nextIndex = (currentDeltaFrameIndex + 1) % deltaFrameIndices.count
            
            if let preloaded = preloadedFrames[nextIndex] {
                let frameIndex = deltaFrameIndices[nextIndex]
                let pointCount = preloaded.splatCount
                let estimatedSizeMB = Double(pointCount * 32) / (1024 * 1024)
                
                splatRenderer = preloaded
                modelRenderer = preloaded
                currentDeltaFrameIndex = nextIndex
                
                let logMessage = """
                    📊 Delta Frame [\(nextIndex + 1)/\(deltaFrameIndices.count)] frame_\(frameIndex) (preloaded)
                       Points: \(pointCount) (~\(String(format: "%.2f", estimatedSizeMB)) MB)
                       Total: 0.0 ms
                    """
                print(logMessage)
                Self.log.info("\(logMessage)")
                
            } else if preloadAllFrames {
                return
            } else if let preloaded = nextFrameRenderer {
                let frameIndex = deltaFrameIndices[nextIndex]
                let pointCount = preloaded.splatCount
                let estimatedSizeMB = Double(pointCount * 32) / (1024 * 1024)
                
                let oldRenderer = splatRenderer
                splatRenderer = preloaded
                modelRenderer = preloaded
                currentDeltaFrameIndex = nextIndex
                nextFrameRenderer = nil
                loadingNextFrame = false
                
                let logMessage = """
                    📊 Delta Frame [\(nextIndex + 1)/\(deltaFrameIndices.count)] frame_\(frameIndex) (preloaded)
                       Points: \(pointCount) (~\(String(format: "%.2f", estimatedSizeMB)) MB)
                       Total: 0.0 ms
                    """
                print(logMessage)
                Self.log.info("\(logMessage)")
                
                oldRenderer?.reset()
                loadNextDeltaFrameInBackground()
            } else {
                Task {
                    do {
                        try await loadDeltaFrame(at: nextIndex)
                        loadNextDeltaFrameInBackground()
                    } catch {
                        Self.log.error("Failed to load delta frame: \(error.localizedDescription)")
                    }
                }
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
            
            let commonUpCalibration = matrix4x4_rotation(radians: .pi, axis: SIMD3<Float>(0, 0, 1))

            let simdDeviceAnchor = deviceAnchor?.originFromAnchorTransform ?? matrix_identity_float4x4

            // CHANGE 1: Use enumerated() to get the index (i) and the view
            return drawable.views.enumerated().map { (i, view) in
                let userViewpointMatrix = (simdDeviceAnchor * view.transform).inverse
                
                // CHANGE 2: Use the new API to compute projection instead of using tangents manually
                // This replaces the entire ProjectiveTransform3D(...) block that is crashing.
                let projectionMatrix = drawable.computeProjection(viewIndex: i)
                
                let screenSize = SIMD2(x: Int(view.textureMap.viewport.width),
                                       y: Int(view.textureMap.viewport.height))
                
                return ModelRendererViewportDescriptor(viewport: view.textureMap.viewport,
                                                       projectionMatrix: .init(projectionMatrix),
                                                       viewMatrix: userViewpointMatrix * translationMatrix * rotationMatrix * commonUpCalibration,
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
        // Update sequence if we're playing a sequence
        updateSequence()
        
        // Update delta sequence if we're playing a delta-encoded sequence
        updateDeltaSequence()
        
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

