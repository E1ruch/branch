import DesignSystem
import Networking
import Session
import SwiftUI

/// The sign-in sheet: sign in or register, then onboarding for provider
/// sign-ups, then it closes itself.
public struct AuthFlowView: View {
    private let client: APIClient
    private let session: SessionStore
    private let showsSignInWithApple: Bool
    @State private var signIn: SignInModel
    @State private var onboarding: OnboardingModel?
    @Environment(\.dismiss) private var dismiss

    public init(client: APIClient, session: SessionStore, showsSignInWithApple: Bool) {
        self.client = client
        self.session = session
        self.showsSignInWithApple = showsSignInWithApple
        _signIn = State(initialValue: SignInModel(client: client, session: session))
    }

    public var body: some View {
        NavigationStack {
            Group {
                if session.state == .signedIn, let onboarding {
                    OnboardingView(model: onboarding)
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                } else {
                    SignInView(model: signIn, showsSignInWithApple: showsSignInWithApple)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Закрыть") { dismiss() }
                            }
                        }
                }
            }
            .animation(.vetka, value: onboarding == nil)
        }
        .onChange(of: session.state, initial: true) { syncWithSession() }
        .onChange(of: session.needsOnboarding) { syncWithSession() }
    }

    private func syncWithSession() {
        guard session.state == .signedIn else { return }
        if session.needsOnboarding {
            if onboarding == nil {
                onboarding = OnboardingModel(client: client, session: session)
            }
        } else {
            dismiss()
        }
    }
}
