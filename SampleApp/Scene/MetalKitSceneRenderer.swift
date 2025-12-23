#if os(iOS) || os(macOS)

import Metal
import MetalKit
import MetalSplatter
import os
import SampleBoxRenderer
import simd
import SplatIO
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
    
    // Delta sequence decoder
    private var deltaDecoder: DeltaSequenceDecoder?
    private var deltaFrameIndices: [Int] = []
    private var currentDeltaFrameIndex: Int = 0
    
    // GPU timing tracking
    private var gpuFrameCount: Int = 0
    private var totalGPUTime: TimeInterval = 0

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
        
        // Clean up delta sequence
        deltaDecoder = nil
        deltaFrameIndices = []
        currentDeltaFrameIndex = 0
        
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
                       Swap: 0.0 ms (GPU render time measured separately)
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
                       Swap: 0.0 ms (GPU render time measured separately)
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
    
    // MARK: - Delta Sequence Support
    
    private func loadDeltaFrame(at index: Int) async throws {
        guard let decoder = deltaDecoder else { return }
        guard index < deltaFrameIndices.count else { return }
        
        let frameIndex = deltaFrameIndices[index]
        let totalStartTime = CFAbsoluteTimeGetCurrent()
        
        // Get decoded points from delta decoder
        let decodeStartTime = CFAbsoluteTimeGetCurrent()
        let points = try await decoder.getFrame(at: frameIndex)
        let decodeTime = (CFAbsoluteTimeGetCurrent() - decodeStartTime) * 1000
        
        // Create or reuse renderer
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
        
        // Load points into renderer
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
                // Decode the frame
                let points = try await decoder.getFrame(at: frameIndex)
                
                // Create a new renderer for background loading
                let renderer = try await SplatRenderer(device: self.device,
                                                      colorFormat: self.metalKitView.colorPixelFormat,
                                                      depthFormat: self.metalKitView.depthStencilPixelFormat,
                                                      sampleCount: self.metalKitView.sampleCount,
                                                      maxViewCount: 1,
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
        
        // Load all frames in parallel
        await withTaskGroup(of: (Int, SplatRenderer?, Int, TimeInterval, TimeInterval).self) { group in
            for index in 0..<totalFrames {
                // Skip index 0 since it's already loaded
                guard index != 0 else { continue }
                
                group.addTask { [weak self] in
                    guard let self = self else { return (index, nil, 0, 0, 0) }
                    do {
                        let frameIndex = self.deltaFrameIndices[index]
                        
                        let decodeStart = CFAbsoluteTimeGetCurrent()
                        let points = try await decoder.getFrame(at: frameIndex)
                        let decodeTime = (CFAbsoluteTimeGetCurrent() - decodeStart) * 1000
                        
                        let loadStart = CFAbsoluteTimeGetCurrent()
                        let renderer = try await SplatRenderer(
                            device: self.device,
                            colorFormat: self.metalKitView.colorPixelFormat,
                            depthFormat: self.metalKitView.depthStencilPixelFormat,
                            sampleCount: self.metalKitView.sampleCount,
                            maxViewCount: 1,
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
            
            // Check if we have all frames preloaded
            if let preloaded = preloadedFrames[nextIndex] {
                // Use preloaded frame from memory
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
                // Preload mode is on but frame isn't ready yet - skip this frame change
                return
            } else if let preloaded = nextFrameRenderer {
                // Fallback to single-frame preloading
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
                       Swap: 0.0 ms (GPU render time measured separately)
                    """
                print(logMessage)
                Self.log.info("\(logMessage)")
                
                oldRenderer?.reset()
                loadNextDeltaFrameInBackground()
            } else {
                // Fallback to synchronous load
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
        
        // Update delta sequence if we're playing a delta-encoded sequence
        updateDeltaSequence()
        
        guard let modelRenderer else { return }
        guard let drawable = view.currentDrawable else { return }

        _ = inFlightSemaphore.wait(timeout: DispatchTime.distantFuture)

        guard let commandBuffer = commandQueue.makeCommandBuffer() else {
            inFlightSemaphore.signal()
            return
        }

        // Measure GPU rendering time
        let renderStartTime = CFAbsoluteTimeGetCurrent()
        
        let semaphore = inFlightSemaphore
        commandBuffer.addCompletedHandler { [weak self] (_ commandBuffer)-> Swift.Void in
            guard let self = self else {
                semaphore.signal()
                return
            }
            let gpuTime = (CFAbsoluteTimeGetCurrent() - renderStartTime) * 1000
            self.totalGPUTime += gpuTime
            self.gpuFrameCount += 1
            
            // Log GPU time periodically (every 30 frames) or if it's unusually high
            if self.gpuFrameCount % 30 == 0 || gpuTime > 16.67 { // 16.67ms = 60fps threshold
                let avgGPUTime = self.totalGPUTime / Double(self.gpuFrameCount)
                Self.log.debug("GPU render: \(String(format: "%.2f", gpuTime)) ms (avg: \(String(format: "%.2f", avgGPUTime)) ms)")
                if gpuTime > 16.67 {
                    print("⚠️ High GPU render time: \(String(format: "%.2f", gpuTime)) ms")
                }
                self.totalGPUTime = 0
                self.gpuFrameCount = 0
            }
            
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
