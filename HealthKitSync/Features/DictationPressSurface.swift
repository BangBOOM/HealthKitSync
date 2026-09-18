import SwiftUI
import UIKit

/// Track the initial touch directly, without waiting for a drag recognizer.
struct DictationPressSurface: UIViewRepresentable {
    var begin: () -> Bool
    var move: (CGFloat) -> Void
    var end: (Bool) -> Void

    func makeUIView(context: Context) -> PressControl { PressControl() }

    func updateUIView(_ view: PressControl, context: Context) {
        view.begin = begin
        view.move = move
        view.end = end
    }

    final class PressControl: UIControl {
        var begin: (() -> Bool)?
        var move: ((CGFloat) -> Void)?
        var end: ((Bool) -> Void)?
        private var originY: CGFloat = 0
        private var accepted = false

        override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
            originY = touch.location(in: window).y
            accepted = begin?() ?? false
            return accepted
        }

        override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
            move?(touch.location(in: window).y - originY)
            return accepted
        }

        override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
            if let touch { move?(touch.location(in: window).y - originY) }
            finish(cancelled: false)
        }

        override func cancelTracking(with event: UIEvent?) { finish(cancelled: true) }

        private func finish(cancelled: Bool) {
            guard accepted else { return }
            accepted = false
            end?(cancelled)
        }
    }
}
