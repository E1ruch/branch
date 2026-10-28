import Core
import DesignSystem
import Networking

/// Optimistic voting for anything with a score: posts and comments.
///
/// A tap changes the screen at once (the caller applies the returned state)
/// and the request goes out once the taps settle, carrying only the final
/// state. The response reconciles the score; an error rolls back to what the
/// server last confirmed.
@MainActor
public final class VoteSync {
    public typealias Send = @Sendable (_ id: Int64, _ value: Int) async throws(APIError) -> VoteResult

    public enum Outcome: Equatable {
        /// The server's state: its score includes everyone's votes, ours too.
        case confirmed(myVote: Int, score: Int)
        /// The request failed: back to the last confirmed state.
        case rolledBack(myVote: Int, score: Int, error: APIError)
    }

    /// Called when a vote settles, for the caller to store and redraw.
    public var onOutcome: ((Int64, Outcome) -> Void)?

    private let send: Send
    private let debounce: Duration
    /// The state to roll back to, per id with a vote on its way.
    private var confirmed: [Int64: (myVote: Int, score: Int)] = [:]
    /// The latest tap per id; only its response is applied. One counter for
    /// all ids, so a reset never lets an old request pass as a new one.
    private var latest: [Int64: Int] = [:]
    private var counter = 0

    public init(debounce: Duration = .milliseconds(300), send: @escaping Send) {
        self.debounce = debounce
        self.send = send
    }

    /// A vote is waiting or in flight: a reload must not overwrite it.
    public func isPending(_ id: Int64) -> Bool {
        latest[id] != nil
    }

    /// A tap on ▲ (direction 1) or ▼ (-1); tapping the active arrow again
    /// clears the vote. Returns the state to show now.
    public func tap(_ id: Int64, myVote: Int, score: Int, direction: Int) -> (myVote: Int, score: Int) {
        let value = myVote == direction ? 0 : direction
        if latest[id] == nil {
            confirmed[id] = (myVote, score)
        }
        counter += 1
        let generation = counter
        latest[id] = generation
        Haptics.tap()

        Task { [weak self, debounce] in
            try? await Task.sleep(for: debounce)
            await self?.flush(id, value: value, generation: generation)
        }
        return (value, score - myVote + value)
    }

    /// Signing in or out: votes on their way belong to the old account.
    public func reset() {
        confirmed = [:]
        latest = [:]
    }

    private func flush(_ id: Int64, value: Int, generation: Int) async {
        guard latest[id] == generation else { return } // a newer tap took over
        do {
            let result = try await send(id, value)
            guard latest[id] == generation else { return }
            settle(id)
            onOutcome?(id, .confirmed(myVote: result.myVote, score: result.score))
        } catch {
            guard latest[id] == generation else { return }
            let old = confirmed[id]
            settle(id)
            Haptics.error()
            if let old {
                onOutcome?(id, .rolledBack(myVote: old.myVote, score: old.score, error: error))
            }
        }
    }

    private func settle(_ id: Int64) {
        latest[id] = nil
        confirmed[id] = nil
    }
}
