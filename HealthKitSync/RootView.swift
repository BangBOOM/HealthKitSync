import SwiftUI

struct RootView: View {
    @Environment(HealthKitService.self) private var healthKit

    var body: some View {
        NavigationStack {
            Group {
                if healthKit.hasRequestedAuthorization {
                    WorkoutListView()
                } else {
                    AuthorizationView()
                }
            }
        }
    }
}

