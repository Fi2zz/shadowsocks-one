import SwiftUI

extension View {
    @ViewBuilder
    func liquidGlassCapsule() -> some View {
        if #available(iOS 26.0, *) {
            glassEffect(.regular, in: .capsule)
        } else {
            background(Color(uiColor: .secondarySystemBackground), in: Capsule())
        }
    }
}
