#if os(visionOS)

import SwiftUI

struct SequenceWindowOpener: View {
    @Environment(\.openWindow) private var openWindow
    @ObservedObject var manager = SequenceNavigationManager.shared
    @State private var hasOpened = false
    
    var body: some View {
        Color.clear
            .frame(width: 1, height: 1)
            .onChange(of: manager.shouldShowControls) { shouldShow in
                if shouldShow && !hasOpened {
                    hasOpened = true
                    openWindow(id: "sequence-controls")
                } else if !shouldShow {
                    hasOpened = false
                }
            }
    }
}

#endif // os(visionOS)

