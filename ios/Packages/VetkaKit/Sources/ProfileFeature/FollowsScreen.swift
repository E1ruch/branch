import Core
import DesignSystem
import Networking
import Stores
import SwiftUI

/// Подписчики · Подписки of one person, opened from the counters on the
/// profile. Pills with counts switch the lists; both stay alive, so each
/// keeps its scroll position. Rows open the person's profile and carry a
/// follow button, optimistic like everywhere.
public struct FollowsScreen: View {
    private let username: String
    private let profiles: ProfileStore
    private let myUsername: String?
    @State private var selected: FollowList
    @State private var followers: FollowListModel
    @State private var following: FollowListModel

    public init(username: String, list: FollowList, profiles: ProfileStore, client: APIClient, myUsername: String?) {
        self.username = username
        self.profiles = profiles
        self.myUsername = myUsername
        _selected = State(initialValue: list)
        _followers = State(initialValue: FollowListModel(username: username, list: .followers,
                                                         profiles: profiles, client: client))
        _following = State(initialValue: FollowListModel(username: username, list: .following,
                                                         profiles: profiles, client: client))
    }

    public var body: some View {
        let profile = profiles[username]
        VStack(spacing: 0) {
            PillPicker([(FollowList.followers, "Подписчики", profile.map { $0.followersCount.compactFormatted }),
                        (FollowList.following, "Подписки", profile.map { $0.followingCount.compactFormatted })],
                       selection: $selected)
                .padding(.top, Spacing.xs)
                .padding(.bottom, Spacing.s)
            ZStack {
                FollowListView(model: followers, profiles: profiles, myUsername: myUsername, isMine: isMine)
                    .opacity(selected == .followers ? 1 : 0)
                    .allowsHitTesting(selected == .followers)
                FollowListView(model: following, profiles: profiles, myUsername: myUsername, isMine: isMine)
                    .opacity(selected == .following ? 1 : 0)
                    .allowsHitTesting(selected == .following)
            }
        }
        .background(Color.vetkaBackground)
        .navigationTitle(profile?.name ?? "@" + username)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.vetkaBackground, for: .navigationBar)
        .toolbarBackground(.visible, for: .tabBar)
    }

    private var isMine: Bool {
        username.lowercased() == myUsername?.lowercased()
    }
}

private struct FollowListView: View {
    let model: FollowListModel
    let profiles: ProfileStore
    let myUsername: String?
    let isMine: Bool

    var body: some View {
        List {
            switch model.phase {
            case .loading:
                Section {
                    ForEach(0..<8, id: \.self) { _ in SkeletonPersonRow().groupedRow() }
                }
                .shimmer()
            case .failed:
                ContentUnavailableView {
                    Label("Не удалось загрузить", systemImage: "wifi.exclamationmark")
                } description: {
                    Text("Проверьте соединение и попробуйте ещё раз.")
                } actions: {
                    Button("Повторить") { Task { await model.load() } }
                        .buttonStyle(.vetkaPrimary(fullWidth: false))
                }
                .listRowBackground(Color.clear)
            case .loaded where model.usernames.isEmpty:
                empty
                    .listRowBackground(Color.clear)
            case .loaded:
                Section {
                    ForEach(model.usernames, id: \.self) { name in
                        if let person = profiles[name] {
                            PersonRow(profile: person, isMe: name.lowercased() == myUsername?.lowercased()) {
                                profiles.toggleFollow(name)
                            }
                            .groupedRow()
                            .task { await model.loadMoreIfNeeded(showing: name) }
                        }
                    }
                    if model.isLoadingMore {
                        SkeletonPersonRow().groupedRow().shimmer()
                    }
                }
            }
        }
        .groupedListStyle()
        .contentMargins(.top, 0, for: .scrollContent)
        .animation(.vetkaSnappy, value: model.phase)
        .refreshable { await model.load() }
        // Once, not on every return from a profile: the store keeps the
        // buttons fresh, pull-to-refresh reloads the list.
        .task { if model.usernames.isEmpty { await model.load() } }
    }

    private var empty: some View {
        let (image, title, text): (String, String, String) = switch (model.list, isMine) {
        case (.followers, true): ("person.2", "Подписчиков пока нет", "Здесь появятся те, кто на вас подпишется.")
        case (.followers, false): ("person.2", "Подписчиков пока нет", "Станьте первым.")
        case (.following, true): ("person.badge.plus", "Подписок пока нет", "Подписывайтесь на интересных людей — из их профилей.")
        case (.following, false): ("person.badge.plus", "Подписок пока нет", "")
        }
        return ContentUnavailableView(title, systemImage: image, description: text.isEmpty ? nil : Text(text))
            .padding(.top, Spacing.xl)
    }
}

/// Avatar, name and @username; on the right, the follow button. The row
/// opens the profile; the button only follows.
private struct PersonRow: View {
    let profile: Profile
    let isMe: Bool
    let toggleFollow: () -> Void

    var body: some View {
        HStack(spacing: Spacing.m) {
            AvatarView(name: profile.username, size: 44)
            VStack(alignment: .leading, spacing: Spacing.xxs) {
                Text(profile.name)
                    .font(.headline)
                    .foregroundStyle(Color.vetkaTextPrimary)
                    .lineLimit(1)
                Text("@" + profile.username)
                    .font(.footnote)
                    .foregroundStyle(Color.vetkaSecondaryText)
                    .lineLimit(1)
            }
            Spacer(minLength: Spacing.s)
            if isMe {
                Text("Вы")
                    .font(.subheadline)
                    .foregroundStyle(Color.vetkaSecondaryText)
            } else {
                Button(profile.isFollowing ? "Отписаться" : "Подписаться", action: toggleFollow)
                    .buttonStyle(.pill(profile.isFollowing ? .muted : .filled))
                    .contentTransition(.interpolate)
                    .animation(.vetka, value: profile.isFollowing)
                    .accessibilityIdentifier("follows.follow.\(profile.username)")
            }
        }
        .padding(.vertical, Spacing.xxs)
        // The whole row opens the profile; a NavigationLink in the
        // background keeps the button its own tap and no chevron takes room.
        .background {
            NavigationLink(value: Route.user(username: profile.username)) { EmptyView() }
                .opacity(0)
        }
        .contentShape(Rectangle())
    }
}

private struct SkeletonPersonRow: View {
    var body: some View {
        HStack(spacing: Spacing.m) {
            Circle().fill(Color.vetkaSkeleton).frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: Spacing.s) {
                SkeletonBar(width: 130, height: 13)
                SkeletonBar(width: 80, height: 10)
            }
            Spacer()
            Capsule().fill(Color.vetkaSkeleton).frame(width: 96, height: 30)
        }
        .padding(.vertical, Spacing.xxs)
    }
}
