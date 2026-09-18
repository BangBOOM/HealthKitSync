import SwiftUI

/// A side-on, bent-arm push-up so it cannot be confused with a standing exercise.
struct RecordKindIcon: View {
    let kind: RecordKind
    @ScaledMetric(relativeTo: .subheadline) private var size = 22.0

    var body: some View {
        Group {
            if kind == .pushups {
                Image("Pushup").resizable().scaledToFit()
            } else {
                Image(systemName: "timer").resizable().scaledToFit()
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
