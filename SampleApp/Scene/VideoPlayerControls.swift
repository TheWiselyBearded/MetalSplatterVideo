#if os(visionOS)

import SwiftUI

/// Modular video player controls component for 4D video scrubbing
struct VideoPlayerControls: View {
    @AppStorage("isPlaying") private var isPlaying: Bool = true
    @AppStorage("currentFrameIndex") private var currentFrameIndex: Int = 0
    @AppStorage("totalFrames") private var totalFrames: Int = 0
    @AppStorage("playbackSpeed") private var playbackSpeed: Double = 1.0
    
    var onSeek: ((Int) -> Void)?
    
    var body: some View {
        VStack(spacing: 12) {
            // Frame info
            if totalFrames > 0 {
                Text("Frame \(currentFrameIndex + 1) / \(totalFrames)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            // Scrubber
            if totalFrames > 1 {
                HStack(spacing: 12) {
                    Button(action: {
                        let newIndex = max(0, currentFrameIndex - 1)
                        currentFrameIndex = newIndex
                        onSeek?(newIndex)
                    }) {
                        Image(systemName: "backward.frame.fill")
                    }
                    .disabled(currentFrameIndex == 0)
                    
                    Slider(
                        value: Binding(
                            get: { Double(currentFrameIndex) },
                            set: { newValue in
                                let newIndex = Int(newValue.rounded())
                                currentFrameIndex = newIndex
                                onSeek?(newIndex)
                            }
                        ),
                        in: 0...Double(max(0, totalFrames - 1)),
                        step: 1
                    )
                    
                    Button(action: {
                        let newIndex = min(totalFrames - 1, currentFrameIndex + 1)
                        currentFrameIndex = newIndex
                        onSeek?(newIndex)
                    }) {
                        Image(systemName: "forward.frame.fill")
                    }
                    .disabled(currentFrameIndex >= totalFrames - 1)
                }
            }
            
            // Playback controls
            HStack(spacing: 16) {
                Button(action: {
                    isPlaying.toggle()
                }) {
                    Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                }
                
                // Speed control
                Menu {
                    Button("0.5x") { playbackSpeed = 0.5 }
                    Button("1x") { playbackSpeed = 1.0 }
                    Button("1.5x") { playbackSpeed = 1.5 }
                    Button("2x") { playbackSpeed = 2.0 }
                } label: {
                    Text("\(playbackSpeed, specifier: "%.1f")x")
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(Color.secondary.opacity(0.2))
                        .cornerRadius(6)
                }
            }
        }
        .padding()
        .background(Color.black.opacity(0.3))
        .cornerRadius(12)
    }
}

#endif // os(visionOS)

