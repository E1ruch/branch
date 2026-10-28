import Core
import DesignSystem
import Stores
import SwiftUI

/// A post with its comments (Route.post) or a continued branch
/// (Route.commentThread). SwiftUI owns the navigation bar; UIKit owns the
/// scrolling list and the comment field, which follows the keyboard itself.
public struct ThreadScreen: View {
    private let mode: ThreadMode
    private let service: any PostService
    private let store: PostStore
    private let isSignedIn: Bool
    private let viewer: AuthorRef?
    private let open: (Route) -> Void
    private let requestSignIn: () -> Void
    private let continueStory: (Post) -> Void
    @State private var title = ""

    /// `continueStory` opens the composer for the next part of the post's
    /// story (the author's "Следующая часть").
    public init(mode: ThreadMode, service: any PostService, store: PostStore, isSignedIn: Bool, viewer: AuthorRef?,
                open: @escaping (Route) -> Void, requestSignIn: @escaping () -> Void,
                continueStory: @escaping (Post) -> Void) {
        self.mode = mode
        self.service = service
        self.store = store
        self.isSignedIn = isSignedIn
        self.viewer = viewer
        self.open = open
        self.requestSignIn = requestSignIn
        self.continueStory = continueStory
    }

    public var body: some View {
        ThreadContainer(mode: mode, service: service, store: store, isSignedIn: isSignedIn, viewer: viewer,
                        open: open, requestSignIn: requestSignIn, continueStory: continueStory,
                        onTitle: { title = $0 })
            // The view controller moves its field with the keyboard; SwiftUI
            // must not shrink it as well.
            .ignoresSafeArea(.keyboard)
            .ignoresSafeArea(.container, edges: .bottom)
            .background(Color.vetkaSurface)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.vetkaSurface, for: .navigationBar)
            // The tab bar stays and the comment field sits above it. Hidden
            // with .toolbar(.hidden, for: .tabBar), SwiftUI brings it back
            // only ~0.6 s after the back animation ends: a visible jump.
    }
}

private struct ThreadContainer: UIViewControllerRepresentable {
    let mode: ThreadMode
    let service: any PostService
    let store: PostStore
    let isSignedIn: Bool
    let viewer: AuthorRef?
    let open: (Route) -> Void
    let requestSignIn: () -> Void
    let continueStory: (Post) -> Void
    let onTitle: (String) -> Void

    func makeUIViewController(context: Context) -> ThreadViewController {
        let model = ThreadModel(mode: mode, service: service, store: store, isSignedIn: isSignedIn, viewer: viewer,
                                requestSignIn: requestSignIn)
        let vc = ThreadViewController(model: model, open: open, requestSignIn: requestSignIn,
                                      continueStory: continueStory)
        vc.onTitle = { title in
            // Never during a SwiftUI update: the title is SwiftUI state.
            DispatchQueue.main.async { onTitle(title) }
        }
        return vc
    }

    func updateUIViewController(_ vc: ThreadViewController, context: Context) {
        if vc.model.isSignedIn != isSignedIn || vc.model.viewer != viewer {
            vc.setSession(signedIn: isSignedIn, viewer: viewer)
        }
    }
}
