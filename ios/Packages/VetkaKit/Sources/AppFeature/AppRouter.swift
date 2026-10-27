import Core
import DesignSystem
import Observation
import SwiftUI

enum Tab: Hashable, CaseIterable {
    case feed, communities, profile
}

/// Navigation state: the selected tab and one stack of routes per tab, so
/// switching tabs keeps each tab where the user left it.
@MainActor
@Observable
final class AppRouter {
    var selectedTab: Tab = .feed
    var paths: [Tab: [Route]] = [:]

    func path(for tab: Tab) -> Binding<[Route]> {
        Binding(get: { self.paths[tab, default: []] },
                set: { self.paths[tab] = $0 })
    }

    /// Tab bar selection with the Telegram behaviour: tapping the current
    /// tab again pops it to its root.
    var tabSelection: Binding<Tab> {
        Binding(get: { self.selectedTab },
                set: { tab in
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
