import Core
import Foundation
import Networking
import Stores
import Testing
@testable import SettingsFeature

func makeMe(username: String = "ivan", displayName: String? = "Иван", bio: String? = nil,
            changeableAt: String? = nil) throws -> Me {
    let json = """
    {"id": 1, "username": "\(username)", "display_name": \(displayName.map { "\"\($0)\"" } ?? "null"),
     "bio": \(bio.map { "\"\($0)\"" } ?? "null"), "post_karma": 0, "comment_karma": 0,
     "created_at": "2026-10-01T12:00:00Z", "posts_count": 0, "followers_count": 0, "following_count": 0,
     "username_changeable_at": \(changeableAt.map { "\"\($0)\"" } ?? "null")}
    """
    return try JSON.decoder().decode(Me.self, from: Data(json.utf8))
}

actor SaveRecorder {
    var calls: [(String?, String?, String?)] = []
    var error: APIError?

    func fail(with error: APIError) { self.error = error }

    func save(_ username: String?, _ name: String?, _ bio: String?) throws(APIError) -> Me {
        calls.append((username, name, bio))
        if let error { throw error }
        return try! makeMe(username: username ?? "ivan", displayName: name, bio: bio)
    }
}

@MainActor
@Suite(.serialized) struct EditProfileModelTests {
    func model(_ me: Me, _ recorder: SaveRecorder, taken: Bool = false) -> EditProfileModel {
        let check = UsernameCheck(original: me.username, debounce: .zero) { name throws(APIError) in
            UsernameAvailability(username: name, available: !taken, reason: taken ? "taken" : nil, message: nil)
        }
        return EditProfileModel(me: me, usernameCheck: check, now: { Date(timeIntervalSince1970: 1_800_000_000) }) {
            username, name, bio throws(APIError) in
            try await recorder.save(username, name, bio)
        }
    }

    @Test func sendsOnlyWhatChanged() async throws {
        let recorder = SaveRecorder()
        let m = model(try makeMe(), recorder)
        #expect(!m.canSave) // nothing changed yet

        m.bio = "  Люблю котиков \n"
        #expect(m.canSave)
        let saved = await m.submit()
        let calls = await recorder.calls
        #expect(calls.count == 1)
        #expect(calls[0].0 == nil && calls[0].1 == nil && calls[0].2 == "Люблю котиков") // trimmed
        #expect(saved?.bio == "Люблю котиков")
    }

    @Test func clearingTheNameSendsEmpty() async throws {
        let recorder = SaveRecorder()
        let m = model(try makeMe(), recorder)
        m.displayName = "   "
        _ = await m.submit()
        #expect(await recorder.calls.first?.1 == "")
    }

    @Test func takenUsernameBlocksSaving() async throws {
        let m = model(try makeMe(), SaveRecorder(), taken: true)
        m.username = "petr"
        await m.checkUsername()
        #expect(m.usernameStatus == .taken && !m.canSave)

        m.username = "ab"
        await m.checkUsername()
        #expect(m.usernameStatus == .invalid(UsernameRule.hint) && !m.canSave)
    }

    @Test func tooLongBioBlocksSaving() throws {
        let m = model(try makeMe(), SaveRecorder())
        m.bio = String(repeating: "я", count: 301)
        #expect(!m.canSave)
        m.bio = String(repeating: "я", count: 300)
        #expect(m.canSave)
    }

    @Test func usernameLockedForThirtyDays() throws {
        // now is 2027-01-15; changeable from 2027-02-01.
        let m = model(try makeMe(changeableAt: "2027-02-01T00:00:00Z"), SaveRecorder())
        #expect(m.usernameLockedUntil != nil)
        let open = model(try makeMe(changeableAt: "2026-12-01T00:00:00Z"), SaveRecorder())
        #expect(open.usernameLockedUntil == nil)
    }

    @Test func serverErrorIsShownAndMarksTaken() async throws {
        let recorder = SaveRecorder()
        await recorder.fail(with: .server(status: 409, code: "username_taken", message: "", field: "username"))
        let m = model(try makeMe(), recorder)
        m.username = "petr"
        await m.checkUsername()
        #expect(await m.submit() == nil)
        #expect(m.error == "Этот ник уже занят" && m.usernameStatus == .taken)
    }
}
