import Core
import DesignSystem
import SwiftUI

/// A community in a list: avatar, title, description, subscribers and the
/// one-tap subscribe button. The communities tab and search both show it.
public struct CommunityRow: View {
    let community: Community
    let toggle: () -> Void

    public init(community: Community, toggle: @escaping () -> Void) {
        self.community = community
        self.toggle = toggle
    }

    public var body: some View {
        HStack(spacing: Spacing.m) {
            AvatarView(name: community.title, size: 44)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(community.title)
                    .font(.headline)
                    .foregroundStyle(Color.vetkaTextPrimary)
                    .lineLimit(1)
                if !community.description.isEmpty {
                    Text(community.description)
                        .font(.subheadline)
                        .foregroundStyle(Color.vetkaTextPrimary)
                        .lineLimit(1)
                }
                Text(subscribers)
                    .font(.footnote)
                    .foregroundStyle(Color.vetkaSecondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            // Subscribed: grey and says what a tap does.
            Button(community.isSubscribed ? "Отписаться" : "Подписаться", action: toggle)
                .buttonStyle(.pill(community.isSubscribed ? .muted : .filled))
            .animation(.vetkaSnappy, value: community.isSubscribed)
        }
        .padding(.vertical, Spacing.xs)
    }

    private var subscribers: String {
        let count = community.subscribersCount
        return "\(count.compactFormatted) \(count.ru("подписчик", "подписчика", "подписчиков"))"
    }
}

public struct CommunityRowSkeleton: View {
    public init() {}

    public var body: some View {
        HStack(spacing: Spacing.m) {
            Circle().fill(Color.vetkaSkeleton).frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: Spacing.s) {
                SkeletonBar(width: 160, height: 14)
                SkeletonBar(width: 110, height: 11)
            }
            Spacer()
            Capsule().fill(Color.vetkaSkeleton).frame(width: 104, height: 32)
        }
        .padding(.vertical, Spacing.xs)
        .listRowSeparator(.hidden)
        .listRowBackground(Color.vetkaSurface)
    }
}
