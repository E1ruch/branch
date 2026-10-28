import FeedUI

/// The three feeds of the feed tab.
public enum FeedKind: String, CaseIterable, Hashable, Sendable {
    case hot, new, subscriptions

    public var title: String {
        switch self {
        case .hot: "Горячее"
        case .new: "Новое"
        case .subscriptions: "Подписки"
        }
    }

    var source: FeedSource {
        switch self {
        case .hot: .all(.hot)
        case .new: .all(.new)
        case .subscriptions: .subscriptions
        }
    }
}
