import SwiftUI

@main
struct JotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        // All real surfaces (HUD panel, History, Settings, Onboarding) are
        // AppKit-managed windows owned by AppDelegate; SwiftUI scenes would
        // steal focus and fight the accessory activation policy.
        Settings { EmptyView() }
    }
}
