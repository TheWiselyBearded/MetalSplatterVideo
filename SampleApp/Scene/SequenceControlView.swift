#if os(visionOS)

import SwiftUI

struct SequenceControlView: View {
    @ObservedObject var manager = SequenceNavigationManager.shared
    @Environment(\.openWindow) private var openWindow
    
    var body: some View {
        VStack(spacing: 15) {
            HStack(spacing: 20) {
                Button(action: {
                    SequenceNavigationManager.shared.navigateBackward()
                }) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 24))
                        .frame(width: 60, height: 60)
                }
                .buttonStyle(.borderedProminent)
                
                Button(action: {
                    SequenceNavigationManager.shared.navigateForward()
                }) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 24))
                        .frame(width: 60, height: 60)
                }
                .buttonStyle(.borderedProminent)
            }
            
            Button(action: {
                SequenceNavigationManager.shared.toggleAutoPlay()
            }) {
                HStack {
                    Image(systemName: manager.isAutoPlaying ? "pause.circle.fill" : "play.circle.fill")
                        .font(.system(size: 20))
                    Text(manager.isAutoPlaying ? "Stop Auto Play" : "Start Auto Play")
                        .font(.system(size: 16, weight: .medium))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding()
        .background(.ultraThinMaterial)
        .cornerRadius(16)
    }
}

#endif // os(visionOS)

