import Core
import DesignSystem
import SwiftUI

/// The feed tab: a segmented picker in the navigation bar over the UIKit
/// feeds. SwiftUI owns navigation and chrome; UIKit owns the scrolling.
public struct FeedScreen: View {
    private let service: any FeedService
    private let isSignedIn: Bool
    private let open: (Route) -> Void
    private let requestSignIn: () -> Void
    @State private var kind: FeedKind = .hot

    public init(service: any FeedService, isSignedIn: Bool,
                open: @escaping (Route) -> Void, requestSignIn: @escaping () -> Void) {
        self.service = service
        self.isSignedIn = isSignedIn
        self.open = open
        self.requestSignIn = requestSignIn
    }

    public var body: some View {
        FeedContainer(kind: kind, service: service, isSignedIn: isSignedIn, open: open, requestSignIn: requestSignIn)
            .ignoresSafeArea(.container, edges: .bottom)
            .navigationTitle("Ветка")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("Лента", selection: $kind) {
                        ForEach(FeedKind.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 300)
                }
            }
            .onChange(of: kind) { Haptics.selection() }
    }
}

private struct FeedContainer: UIViewControllerRepresentable {
    let kind: FeedKind
    let service: any FeedService
    let isSignedIn: Bool
    let open: (Route) -> Void
    let requestSignIn: () -> Void

    func makeUIViewController(context: Context) -> FeedContainerViewController {
        let vc = FeedContainerViewController(service: service, isSignedIn: isSignedIn,
                                             open: open, requestSignIn: requestSignIn)
        vc.show(kind)
        return vc
    }

    func updateUIViewController(_ vc: FeedContainerViewController, context: Context) {
        vc.show(kind)
        vc.setSignedIn(isSignedIn)
    }
}
