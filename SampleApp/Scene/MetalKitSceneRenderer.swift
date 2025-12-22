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
    var sequenceInterval: TimeInterval = 0.5  // Time between frames (seconds)

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
            try await loadSequenceFrame(at: 0)
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
        
        // Time renderer initialization
        let initStartTime = CFAbsoluteTimeGetCurrent()
        let splat = try await SplatRenderer(device: device,
                                            colorFormat: metalKitView.colorPixelFormat,
                                            depthFormat: metalKitView.depthStencilPixelFormat,
                                            sampleCount: metalKitView.sampleCount,
                                            maxViewCount: 1,
                                            maxSimultaneousRenders: Constants.maxSimultaneousRenders)
        let initTime = (CFAbsoluteTimeGetCurrent() - initStartTime) * 1000
        
        // Time file reading/parsing
        let readStartTime = CFAbsoluteTimeGetCurrent()
        try await splat.read(from: url)
        let readTime = (CFAbsoluteTimeGetCurrent() - readStartTime) * 1000
        
        let totalTime = (CFAbsoluteTimeGetCurrent() - totalStartTime) * 1000
        
        // Get file size for context
        let fileSize = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        let fileSizeMB = Double(fileSize) / (1024 * 1024)
        
        modelRenderer = splat
        currentSequenceIndex = index
        
        Self.log.info("""
            📊 Splat [\(index + 1)/\(self.sequenceURLs.count)] \(url.lastPathComponent)
               File: \(String(format: "%.2f", fileSizeMB)) MB
               Init: \(String(format: "%.1f", initTime)) ms
               Read: \(String(format: "%.1f", readTime)) ms
               Total: \(String(format: "%.1f", totalTime)) ms
            """)
    }

    private func updateSequence() {
        guard !sequenceURLs.isEmpty else { return }
        
        let now = Date()
        guard let lastChange = lastSequenceChangeTimestamp else {
            lastSequenceChangeTimestamp = now
            return
        }
        
        if now.timeIntervalSince(lastChange) >= sequenceInterval {
            lastSequenceChangeTimestamp = now
            let nextIndex = (currentSequenceIndex + 1) % sequenceURLs.count
            Task {
                do {
                    try await loadSequenceFrame(at: nextIndex)
                } catch {
                    Self.log.error("Failed to load sequence frame: \(error.localizedDescription)")
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
