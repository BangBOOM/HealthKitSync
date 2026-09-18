import SwiftUI

/// A direct manipulation gesture: no action tray or hidden delete button.
struct SwipeAwayRecord: ViewModifier {
    let enabled: Bool
    let delete: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @GestureState private var drag = SwipeState()
    @State private var width: CGFloat = 320

    private struct SwipeState {
        var horizontal: Bool?
        var offset: CGFloat = 0
    }

    func body(content: Content) -> some View {
        let threshold = max(100, width * 0.45)
        content
            .contentShape(Rectangle())
            .background {
                GeometryReader { geometry in
                    Color.clear
                        .onAppear { width = geometry.size.width }
                        .onChange(of: geometry.size.width) { _, value in width = value }
                }
            }
            .offset(x: reduceMotion ? 0 : drag.offset)
            .opacity(1 - min(abs(drag.offset) / max(width, 1), 1) * 0.65)
            .animation(drag.offset == 0 && !reduceMotion ? .spring(response: 0.3, dampingFraction: 0.85) : nil, value: drag.offset)
            .simultaneousGesture(
                DragGesture(minimumDistance: 24)
                    .updating($drag) { value, state, _ in
                        guard enabled else { return }
                        if state.horizontal == nil {
                            state.horizontal = abs(value.translation.width) > abs(value.translation.height) * 1.5
                        }
                        guard state.horizontal == true else { return }
                        state.offset = min(0, value.translation.width)
                    }
                    .onEnded { value in
                        guard enabled, drag.horizontal == true,
                              value.translation.width < -threshold else { return }
                        delete()
                    }
            )
            .accessibilityHint(enabled ? "向左滑过半行可删除，也可使用删除操作" : "")
            .accessibilityActions {
                if enabled { Button("删除这条记录", action: delete) }
            }
    }
}
