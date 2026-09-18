import SwiftUI

/// One shared surface for the text field and its actions, without a second footer panel.
struct RecordComposerSurface: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(6)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 26, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
                    .strokeBorder(.primary.opacity(0.07), lineWidth: 0.5)
                    .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(0.04), radius: 8, y: 2)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
    }
}
