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
    @State private var title = ""

    public init(mode: ThreadMode, service: any PostService, store: PostStore, isSignedIn: Bool, viewer: AuthorRef?,
                open: @escaping (Route) -> Void, requestSignIn: @escaping () -> Void) {
        self.mode = mode
        self.service = service
        self.store = store
        self.isSignedIn = isSignedIn
        self.viewer = viewer
        self.open = open
        self.requestSignIn = requestSignIn
    }

    public var body: some View {
        ThreadContainer(mode: mode, service: service, store: store, isSignedIn: isSignedIn, viewer: viewer,
                        open: open, requestSignIn: requestSignIn, onTitle: { title = $0 })
            // The view controller moves its field with the keyboard; SwiftUI
            // must not shrink it as well.
            .ignoresSafeArea(.keyboard)
            .ignoresSafeArea(.container, edges: .bottom)
            .background(Color.vetkaSurface)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.vetkaSurface, for: .navigationBar)
            // The comment field takes the tab bar's place, like a chat.
            .toolbar(.hidden, for: .tabBar)
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
    let onTitle: (String) -> Void

    func makeUIViewController(context: Context) -> ThreadViewController {
        let model = ThreadModel(mode: mode, service: service, store: store, isSignedIn: isSignedIn, viewer: viewer,
                                requestSignIn: requestSignIn)
        let vc = ThreadViewController(model: model, open: open, requestSignIn: requestSignIn)
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
