import Core
import DesignSystem
import Observation
import SwiftUI

enum Tab: Hashable, CaseIterable {
    /// `create` is the green "+" in the middle: it opens the composer and
    /// never becomes the selected tab.
    case feed, search, create, activity, profile
}

/// Navigation state: the selected tab and one stack of routes per tab, so
/// switching tabs keeps each tab where the user left it.
@MainActor
@Observable
final class AppRouter {
    var selectedTab: Tab = .feed
    var paths: [Tab: [Route]] = [:]
    /// The sign-in sheet. Any screen that needs an account raises it.
    var isAuthPresented = false
    var isComposePresented = false
    /// The post whose story the composer continues, when opened for that.
    var composeContinuing: Post?
    /// Set by AppEnvironment: posting needs an account.
    var isSignedIn: () -> Bool = { false }

    func path(for tab: Tab) -> Binding<[Route]> {
        Binding(get: { self.paths[tab, default: []] },
                set: { self.paths[tab] = $0 })
    }

    /// Tab bar selection with the Telegram behaviour: tapping the current
    /// tab again pops it to its root.
    var tabSelection: Binding<Tab> {
        Binding(get: { self.selectedTab },
                set: { tab in
                    if tab == .create { // VoiceOver can still pick the item itself
                        self.compose()
                        return
                    }
                    if tab == self.selectedTab {
                        if !self.paths[tab, default: []].isEmpty {
                            self.paths[tab] = []
                        }
                    } else {
                        Haptics.selection()
                    }
                    self.selectedTab = tab
                })
    }

    /// The green "+". A button laid over the tab bar calls this: letting
    /// TabView select the "create" item, even for the instant before the
    /// binding refuses it, re-attaches the feed's stack and leaves screens
    /// pushed later with no safe area (lists under the bars).
    func compose(continuing post: Post? = nil) {
        Haptics.tap()
        if isSignedIn() {
            composeContinuing = post
            isComposePresented = true
        } else {
            isAuthPresented = true
        }
    }

    /// The post and branch screens hide the tab bar for their comment
    /// field; the "+" laid over it must go too.
    var isTabBarHidden: Bool {
        switch paths[selectedTab]?.last {
        case .post, .commentThread: true
        default: false
        }
    }

    func push(_ route: Route) {
        paths[selectedTab, default: []].append(route)
    }

    /// Opens a deep link on top of the current tab. Returns false for URLs
    /// that are not screens (auth callbacks are handled elsewhere).
    @discardableResult
    func open(_ url: URL) -> Bool {
        guard let route = Route(url: url) else { return false }
        push(route)
        return true
    }
}
