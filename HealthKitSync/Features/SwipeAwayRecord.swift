import SwiftUI

/// A direct manipulation gesture: no action tray or hidden delete button.
struct SwipeAwayRecord: ViewModifier {
    let enabled: Bool
    let delete: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @GestureState private var drag = SwipeState()
    @State private var width: CGFloat = 320
    @State private var isDismissing = false

    private func dismissRow() {
        guard enabled, !isDismissing else { return }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.22)) {
            isDismissing = true
        } completion: {
            delete()
        }
    }

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
            .offset(x: reduceMotion ? 0 : isDismissing ? -width - 40 : drag.offset)
            .opacity(isDismissing ? 0 : 1)
            .animation(drag.offset == 0 && !isDismissing && !reduceMotion ? .spring(response: 0.3, dampingFraction: 0.85) : nil, value: drag.offset)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.22), value: isDismissing)
            .allowsHitTesting(!isDismissing)
            .onChange(of: enabled) { _, canInteract in
                // A failed/rejected deletion can leave this same row identity alive.
                if canInteract {
                    withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.22)) {
                        isDismissing = false
                    }
                }
            }
            .simultaneousGesture(
                DragGesture(minimumDistance: 24)
                    .updating($drag) { value, state, _ in
                        guard enabled, !isDismissing else { return }
                        if state.horizontal == nil {
                            state.horizontal = abs(value.translation.width) > abs(value.translation.height) * 1.5
                        }
                        guard state.horizontal == true else { return }
                        state.offset = min(0, value.translation.width)
                    }
                    .onEnded { value in
                        // GestureState may already be resetting when onEnded runs.
                        // Use the final gesture value to decide whether to commit.
                        guard enabled, abs(value.translation.width) > abs(value.translation.height) * 1.5,
                              value.translation.width < -threshold else { return }
                        dismissRow()
                    }
            )
            .accessibilityHint(enabled ? "向左滑过半行可删除，也可使用删除操作" : "")
            .accessibilityActions {
                if enabled { Button("删除这条记录", action: dismissRow) }
            }
    }
}
