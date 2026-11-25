import DesignSystem
import Networking
import Session
import SwiftUI

/// The sign-in sheet also hosts the first username selection.
public struct AuthFlowView: View {
    private let client: APIClient
    private let session: SessionStore
    private let showsSignInWithApple: Bool
    @State private var signIn: SignInModel
    @State private var onboarding: OnboardingModel?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(client: APIClient, session: SessionStore, showsSignInWithApple: Bool) {
        self.client = client
        self.session = session
        self.showsSignInWithApple = showsSignInWithApple
        _signIn = State(initialValue: SignInModel(client: client, session: session))
    }

    public var body: some View {
        NavigationStack {
            Group {
                if let onboarding {
                    OnboardingView(model: onboarding)
                        .transition(reduceMotion ? .opacity : .asymmetric(
                            insertion: .offset(x: 24).combined(with: .opacity), removal: .opacity))
                } else {
                    SignInView(model: signIn, showsSignInWithApple: showsSignInWithApple)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button("Закрыть") { dismiss() }
                                    .disabled(signIn.isWorking)
                            }
                        }
                }
            }
            .animation(reduceMotion ? .easeOut(duration: 0.15) : .vetka, value: onboarding == nil)
        }
        .interactiveDismissDisabled(session.requiresUsername || signIn.isWorking)
        .onChange(of: session.state, initial: true) { syncWithSession() }
        .onChange(of: session.needsOnboarding) { syncWithSession() }
    }

    private func syncWithSession() {
        guard session.state == .signedIn else {
            if onboarding != nil {
                signIn.mode = .login
                onboarding = nil
            }
            return
        }
        if session.needsOnboarding {
            if onboarding == nil {
                onboarding = OnboardingModel(client: client, session: session)
            }
        } else {
            dismiss()
        }
    }
}
