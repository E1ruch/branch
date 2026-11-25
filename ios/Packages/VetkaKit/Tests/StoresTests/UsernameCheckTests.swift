import Core
import Networking
import Stores
import Testing

@MainActor
@Suite struct UsernameCheckTests {
    @Test func lateResponseCannotOverwriteTheCurrentNickname() async {
        let (requests, requested) = AsyncStream<Void>.makeStream()
        let (releases, release) = AsyncStream<Void>.makeStream()
        let firstNameAttempts = Attempts()
        let check = UsernameCheck(original: "", debounce: .zero) { name in
            if name == "first", await firstNameAttempts.next() == 1 {
                requested.yield(())
                for await _ in releases { break }
                return UsernameAvailability(username: name, available: true, reason: nil, message: nil)
            }
            return UsernameAvailability(username: name, available: false, reason: "taken", message: nil)
        }

        var events = requests.makeAsyncIterator()
        let first = Task { await check.run("first") }
        await events.next()
        #expect(check.status(for: "second") == .checking)
        await check.run("second")
        #expect(check.status(for: "second") == .taken)
        await check.run("first")
        #expect(check.status(for: "first") == .taken)

        release.yield(())
        release.finish()
        await first.value
        #expect(check.status(for: "first") == .taken)
    }

    @Test func retriesTheSameNicknameAfterANetworkFailure() async {
        let attempts = Attempts()
        let check = UsernameCheck(original: "", debounce: .zero) { name throws(APIError) in
            if await attempts.next() == 1 { throw .transport(.notConnectedToInternet) }
            return UsernameAvailability(username: name, available: true, reason: nil, message: nil)
        }

        await check.run("nickname")
        #expect(check.status(for: "nickname") == .unknown)
        await check.run("nickname")
        #expect(check.status(for: "nickname") == .available)
    }

    private actor Attempts {
        private var count = 0

        func next() -> Int {
            count += 1
            return count
        }
    }
}
