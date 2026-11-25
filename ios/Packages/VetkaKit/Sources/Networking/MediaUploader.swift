import Core
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The signed PUT uses its own session, without API cookies, tokens or redirects.
public struct MediaUploader: Sendable {
    private let client: APIClient
    private let session: URLSession

    public init(client: APIClient) {
        self.client = client
        session = Self.uploadSession
    }

    private static let uploadSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 60
        return URLSession(configuration: config, delegate: UploadDelegate(), delegateQueue: nil)
    }()

    public func upload(_ jpeg: Data) async throws(APIError) -> Media {
        let upload = try await client.send(API.mediaUpload(size: jpeg.count))
        var request = URLRequest(url: upload.uploadUrl)
        request.httpMethod = "PUT"
        for (key, value) in upload.headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let response: URLResponse
        do {
            (_, response) = try await session.upload(for: request, from: jpeg)
        } catch let error as URLError {
            if error.code == .cancelled { throw .cancelled }
            throw .transport(error.code)
        } catch {
            throw .transport(.unknown)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw .unexpectedStatus(status) }
        return try await completed(upload.id)
    }

    /// Complete is safe to repeat for an existing upload owned by the caller.
    public func completed(_ id: Int64) async throws(APIError) -> Media {
        try await client.send(API.completeMediaUpload(id))
    }

    private final class UploadDelegate: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                        completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }
}

/// ImageIO applies orientation, downsamples before encoding and strips source metadata.
/// A separate actor keeps pixel work off the main actor and bounds concurrent decoding.
public actor PhotoPreparation {
    public static let shared = PhotoPreparation()

    public enum Failure: Error { case invalidPhoto }

    public func jpeg(from data: Data?) throws -> Data {
        try Task.checkCancellation()
        guard let data,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              let image = thumbnail(from: source, maxPixelSize: 2048) else { throw Failure.invalidPhoto }
        let result = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(result, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw Failure.invalidPhoto }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.84] as CFDictionary)
        guard CGImageDestinationFinalize(destination), result.length <= 10 * 1024 * 1024
        else { throw Failure.invalidPhoto }
        try Task.checkCancellation()
        return result as Data
    }

    public func preview(at url: URL, maxPixelSize: Int) -> CGImage? {
        guard !Task.isCancelled,
              let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        return thumbnail(from: source, maxPixelSize: maxPixelSize)
    }

    public func preview(from jpeg: Data, maxPixelSize: Int) -> CGImage? {
        guard !Task.isCancelled,
              let source = CGImageSourceCreateWithData(jpeg as CFData, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        return thumbnail(from: source, maxPixelSize: maxPixelSize)
    }

    private func thumbnail(from source: CGImageSource, maxPixelSize: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}
