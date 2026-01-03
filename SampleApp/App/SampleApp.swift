#if os(visionOS)
import CompositorServices
#endif
import SwiftUI

@main
struct SampleApp: App {
    var body: some Scene {
#if os(macOS) || os(iOS)
        WindowGroup("MetalSplatter Sample App", id: "main") {
            ContentView()
        }
#endif

#if os(macOS)
        WindowGroup(for: ModelIdentifier.self) { modelIdentifier in
            MetalKitSceneView(modelIdentifier: modelIdentifier.wrappedValue)
                .navigationTitle(modelIdentifier.wrappedValue?.description ?? "No Model")
                .focusable()
                .onKeyPress(.rightArrow) {
                    SequenceNavigationManager.shared.navigateForward()
                    return .handled
                }
                .onKeyPress(.leftArrow) {
                    SequenceNavigationManager.shared.navigateBackward()
                    return .handled
                }
        }
#endif // os(macOS)

#if os(visionOS)
        ImmersiveSpace(for: ModelIdentifier.self) { modelIdentifier in
            CompositorLayer(configuration: ContentStageConfiguration()) { layerRenderer in
                let renderer = VisionSceneRenderer(layerRenderer)
                Task {
                    do {
                        try await renderer.load(modelIdentifier.wrappedValue)
                    } catch {
                        print("Error loading model: \(error.localizedDescription)")
                    }
                    renderer.startRenderLoop()
                }
            }
        }
        .immersionStyle(selection: .constant(immersionStyle), in: immersionStyle)
        
        WindowGroup("MetalSplatter Sample App", id: "main") {
            ContentView()
        }
        
        WindowGroup(id: "sequence-controls") {
            SequenceControlView()
        }
        .windowStyle(.plain)
        .defaultSize(width: 320, height: 180)
#endif // os(visionOS)
    }

#if os(visionOS)
    var immersionStyle: ImmersionStyle {
        if #available(visionOS 2, *) {
            .mixed
        } else {
            .full
        }
    }
#endif // os(visionOS)
}

