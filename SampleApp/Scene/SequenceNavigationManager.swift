import Foundation
import SwiftUI

#if os(visionOS)
import CompositorServices
#endif

#if os(iOS) || os(macOS)
typealias MetalKitRendererType = MetalKitSceneRenderer
#endif

protocol SequenceNavigable {
    func navigateSequenceFrame(forward: Bool) async
}

#if os(visionOS)
extension VisionSceneRenderer: SequenceNavigable {}
#endif

#if os(iOS) || os(macOS)
extension MetalKitSceneRenderer: SequenceNavigable {}
#endif

@MainActor
class SequenceNavigationManager: ObservableObject {
    static let shared = SequenceNavigationManager()
    
    @Published var isAutoPlaying = false
    @Published var shouldShowControls = false
    
    #if os(visionOS)
    private var visionRenderer: VisionSceneRenderer?
    private var autoPlayTask: Task<Void, Never>?
    #endif
    
    #if os(iOS) || os(macOS)
    private var metalKitRenderer: MetalKitSceneRenderer?
    #endif
    
    #if os(visionOS)
    func setVisionRenderer(_ renderer: VisionSceneRenderer?) {
        visionRenderer = renderer
        if renderer == nil {
            stopAutoPlay()
        }
    }
    #endif
    
    #if os(iOS) || os(macOS)
    func setMetalKitRenderer(_ renderer: MetalKitSceneRenderer?) {
        metalKitRenderer = renderer
    }
    #endif
    
    func navigateForward() {
        Task {
            #if os(visionOS)
            await visionRenderer?.navigateSequenceFrame(forward: true)
            #endif
            #if os(iOS) || os(macOS)
            await metalKitRenderer?.navigateSequenceFrame(forward: true)
            #endif
        }
    }
    
    func navigateBackward() {
        Task {
            #if os(visionOS)
            await visionRenderer?.navigateSequenceFrame(forward: false)
            #endif
            #if os(iOS) || os(macOS)
            await metalKitRenderer?.navigateSequenceFrame(forward: false)
            #endif
        }
    }
    
    #if os(visionOS)
    func toggleAutoPlay() {
        isAutoPlaying.toggle()
        if isAutoPlaying {
            startAutoPlay()
        } else {
            stopAutoPlay()
        }
    }
    
    private func startAutoPlay() {
        stopAutoPlay()
        guard visionRenderer != nil else { return }
        
        autoPlayTask = Task {
            while !Task.isCancelled && isAutoPlaying {
                // Reduced delay - with preloading, frames should be ready quickly
                // If preloaded, navigation is instant, so we can go much faster
                try? await Task.sleep(for: .seconds(0.15))
                guard !Task.isCancelled && isAutoPlaying else { break }
                
                // Navigate forward directly instead of calling navigateForward() to avoid nested Tasks
                #if os(visionOS)
                await visionRenderer?.navigateSequenceFrame(forward: true)
                #endif
            }
        }
    }
    
    private func stopAutoPlay() {
        autoPlayTask?.cancel()
        autoPlayTask = nil
    }
    #endif
}

