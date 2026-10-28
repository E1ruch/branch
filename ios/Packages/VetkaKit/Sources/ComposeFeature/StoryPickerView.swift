import Core
import DesignSystem
import Networking
import SwiftUI

/// The user's recent posts, to pick the story a new post continues. A post
/// already in a story shows its part: continuing it adds after the last one.
struct StoryPickerView: View {
    private let service: any ComposeService
    private let selected: Int64?
    private let onPick: (Post) -> Void
    @State private var posts: [Post]?
    @State private var failed = false

    init(service: any ComposeService, selected: Int64?, onPick: @escaping (Post) -> Void) {
        self.service = service
        self.selected = selected
        self.onPick = onPick
    }

    var body: some View {
        content
            .navigationTitle("Продолжение истории")
            .navigationBarTitleDisplayMode(.inline)
            .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if let posts {
            if posts.isEmpty {
                ContentUnavailableView("Пока нечего продолжать", systemImage: "book.pages",
                                       description: Text("Опубликуйте первую часть — потом сюда можно будет добавить следующую."))
            } else {
                List {
                    Section {
                        ForEach(posts) { row($0) }
                    } footer: {
                        Text("Новый пост станет следующей частью, а читатели смогут листать историю по частям.")
                    }
                }
                .listStyle(.plain)
            }
        } else if failed {
            ContentUnavailableView {
                Label("Не удалось загрузить", systemImage: "wifi.exclamationmark")
            } actions: {
                Button("Повторить") { Task { await load() } }
                    .buttonStyle(.vetkaPrimary(fullWidth: false))
            }
        } else {
            List(0..<6, id: \.self) { _ in
                VStack(alignment: .leading, spacing: Spacing.s) {
                    SkeletonBar(width: 220, height: 14)
                    SkeletonBar(width: 120, height: 10)
                }
                .padding(.vertical, Spacing.xs)
                .listRowSeparator(.hidden)
            }
            .listStyle(.plain)
            .shimmer()
            .allowsHitTesting(false)
        }
    }

    private func row(_ post: Post) -> some View {
        Button {
            onPick(post)
        } label: {
            HStack(spacing: Spacing.m) {
                VStack(alignment: .leading, spacing: Spacing.xxs) {
                    Text(post.title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.vetkaTextPrimary)
                        .lineLimit(2)
                    Text(subtitle(post))
                        .font(.footnote)
                        .foregroundStyle(Color.vetkaSecondaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                if post.id == selected {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(Color.vetkaBrand)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(post.id == selected ? .isSelected : [])
    }

    private func subtitle(_ post: Post) -> String {
        var parts = [post.community.title, RelativeAge.text(from: post.createdAt, now: Date())]
        if let story = post.story {
            parts.insert("История из \(story.parts) \(story.parts.ru("части", "частей", "частей"))", at: 0)
        }
        return parts.joined(separator: " · ")
    }

    private func load() async {
        failed = false
        do {
            posts = try await service.myPosts()
        } catch {
            if posts == nil { failed = true }
        }
    }
}
