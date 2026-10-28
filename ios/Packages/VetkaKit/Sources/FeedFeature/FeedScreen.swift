import Core
import DesignSystem
import Stores
import SwiftUI

/// The feed tab: the logo header and the pill switcher over the UIKit feeds.
/// SwiftUI owns navigation and chrome; UIKit owns the scrolling.
public struct FeedScreen: View {
    private let service: any FeedService
    private let store: PostStore
    private let isSignedIn: Bool
    private let myName: String?
    private let open: (Route) -> Void
    private let requestSignIn: () -> Void
    private let openSearch: () -> Void
    private let openProfile: () -> Void
    @State private var kind: FeedKind = .hot

    public init(service: any FeedService, store: PostStore, isSignedIn: Bool, myName: String?,
                open: @escaping (Route) -> Void, requestSignIn: @escaping () -> Void,
                openSearch: @escaping () -> Void, openProfile: @escaping () -> Void) {
        self.service = service
        self.store = store
        self.isSignedIn = isSignedIn
        self.myName = myName
        self.open = open
        self.requestSignIn = requestSignIn
        self.openSearch = openSearch
        self.openProfile = openProfile
    }

    public var body: some View {
        FeedContainer(kind: kind, service: service, store: store, isSignedIn: isSignedIn, open: open, requestSignIn: requestSignIn)
            .ignoresSafeArea(.container, edges: .bottom)
            .safeAreaInset(edge: .top, spacing: 0) {
                PillPicker(FeedKind.allCases.map { ($0, $0.title) }, selection: $kind)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Spacing.l)
                    .padding(.bottom, Spacing.s)
                    .background(Color.vetkaSurface)
            }
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Color.vetkaSurface, for: .navigationBar)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    LogoView()
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button(action: openSearch) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 17, weight: .semibold))
                            .foregroundStyle(Color(uiColor: Palette.iconPrimary))
                    }
                    .accessibilityLabel("Поиск")

                    Button(action: isSignedIn ? openProfile : requestSignIn) {
                        if let myName {
                            AvatarView(name: myName, size: 30)
                        } else {
                            Image(systemName: "person.crop.circle")
                                .font(.system(size: 22))
                                .foregroundStyle(Color.vetkaSecondaryText)
                        }
                    }
                    .accessibilityLabel(isSignedIn ? "Профиль" : "Войти")
                }
            }
    }
}

private struct FeedContainer: UIViewControllerRepresentable {
    let kind: FeedKind
    let service: any FeedService
    let store: PostStore
    let isSignedIn: Bool
    let open: (Route) -> Void
    let requestSignIn: () -> Void

    func makeUIViewController(context: Context) -> FeedContainerViewController {
        let vc = FeedContainerViewController(service: service, store: store, isSignedIn: isSignedIn,
                                             open: open, requestSignIn: requestSignIn)
        vc.show(kind)
        return vc
    }

    func updateUIViewController(_ vc: FeedContainerViewController, context: Context) {
        vc.show(kind)
        vc.setSignedIn(isSignedIn)
    }
}
