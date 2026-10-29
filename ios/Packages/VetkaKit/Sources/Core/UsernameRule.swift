/// The server's username rule, checked locally first so typing gets instant
/// feedback and malformed names never reach the network.
public enum UsernameRule {
    public static let hint = "3–24 латинские буквы, цифры или _"

    public static func isValid(_ name: String) -> Bool {
        name.wholeMatch(of: /[A-Za-z0-9_]{3,24}/) != nil
    }
}
