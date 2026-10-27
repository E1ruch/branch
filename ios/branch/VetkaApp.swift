import AppFeature
import SwiftUI

/// The app target is a thin shell: everything lives in the VetkaKit package
/// (ios/Packages/VetkaKit), which builds and tests on its own.
@main
struct VetkaApp: App {
    @State private var app = AppEnvironment.live()

    var body: some Scene {
        WindowGroup {
            AppRootView(app: app)
        }
    }
}
