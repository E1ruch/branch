import Foundation

public enum JSON {
    /// Decoder for API responses. Made per use: JSONDecoder is a class with
    /// mutable configuration, and a fresh one costs nothing next to a request.
    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let string = try container.decode(String.self)
            guard let date = parseDate(string) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "not an RFC 3339 date: \(string)")
            }
            return date
        }
        return d
    }

    public static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.dateEncodingStrategy = .iso8601
        return e
    }

    /// Go writes RFC 3339 with fractional seconds only when they are non-zero
    /// ("…T16:48:15.137461+03:00" or "…T16:48:15Z"), so both forms parse.
    static func parseDate(_ string: String) -> Date? {
        if let date = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(string) {
            return date
        }
        return try? Date.ISO8601FormatStyle().parse(string)
    }
}
