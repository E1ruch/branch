import ImageIO
import SwiftUI
import UIKit

/// Shared decoded thumbnails and HTTP caching for images served by imgproxy.
private actor ImagePipeline {
    static let shared = ImagePipeline()

    private struct Download {
        let id = UUID()
        let task: Task<CGImage?, Never>
        var consumers: Set<UUID>
    }

    private let cache = NSCache<NSString, CGImage>()
    private var requests: [String: Download] = [:]

    init() {
        cache.totalCostLimit = 48 * 1024 * 1024
    }

    func image(at url: URL, maxPixelSize: Int) async -> CGImage? {
        guard !Task.isCancelled else { return nil }
        let key = "\(maxPixelSize):\(url.absoluteString)"
        if let image = cache.object(forKey: key as NSString) { return image }
        let consumer = UUID()
        var download: Download
        if let existing = requests[key] {
            download = existing
            download.consumers.insert(consumer)
        } else {
            let task = Task.detached(priority: .utility) {
                await Self.download(url, maxPixelSize: maxPixelSize)
            }
            download = Download(task: task, consumers: [consumer])
        }
        requests[key] = download
        let id = download.id
        return await withTaskCancellationHandler {
            let image = await download.task.value
            if requests[key]?.id == id {
                requests[key] = nil
                if let image {
                    cache.setObject(image, forKey: key as NSString, cost: image.bytesPerRow * image.height)
                }
            }
            return Task.isCancelled ? nil : image
        } onCancel: {
            Task { await self.cancel(key, downloadID: id, consumer: consumer) }
        }
    }

    private func cancel(_ key: String, downloadID: UUID, consumer: UUID) {
        guard var download = requests[key], download.id == downloadID else { return }
        download.consumers.remove(consumer)
        if download.consumers.isEmpty {
            requests[key] = nil
            download.task.cancel()
        } else {
            requests[key] = download
        }
    }

    private static func download(_ url: URL, maxPixelSize: Int) async -> CGImage? {
        guard let (data, response) = try? await URLSession.shared.data(from: url),
              !Task.isCancelled, let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let source = CGImageSourceCreateWithData(data as CFData, [
                kCGImageSourceShouldCache: false,
              ] as CFDictionary) else { return nil }

        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ] as CFDictionary)
    }
}

public final class RemoteImageView: UIImageView {
    private struct Request: Equatable {
        let url: URL
        let thumbhash: String?
        let maxPixelSize: Int
    }

    private var request: Request?
    private var loadTask: Task<Void, Never>?

    public override var intrinsicContentSize: CGSize {
        CGSize(width: UIView.noIntrinsicMetric, height: UIView.noIntrinsicMetric)
    }

    public func setImage(url: URL?, thumbhash: String? = nil, maxPixelSize: Int = 1440) {
        let next = url.map { Request(url: $0, thumbhash: thumbhash, maxPixelSize: maxPixelSize) }
        guard request != next else { return }
        loadTask?.cancel()
        request = next
        image = nil
        guard let next else { return }

        loadTask = Task { [weak self] in
            async let fetched = ImagePipeline.shared.image(at: next.url, maxPixelSize: next.maxPixelSize)
            if let thumbhash = next.thumbhash {
                let preview = await Task.detached(priority: .utility) { ThumbHash.image(from: thumbhash) }.value
                if let preview, !Task.isCancelled { self?.image = UIImage(cgImage: preview) }
            }
            let full = await fetched
            guard !Task.isCancelled else { return }
            if let full {
                self?.image = UIImage(cgImage: full)
            } else {
                self?.request = nil
            }
        }
    }
}

public struct RemoteImage: UIViewRepresentable {
    private let url: URL?
    private let contentMode: ContentMode

    public init(url: URL?, contentMode: ContentMode = .fill) {
        self.url = url
        self.contentMode = contentMode
    }

    public func makeUIView(context: Context) -> RemoteImageView {
        let view = RemoteImageView()
        view.clipsToBounds = true
        return view
    }

    public func updateUIView(_ view: RemoteImageView, context: Context) {
        view.contentMode = contentMode == .fill ? .scaleAspectFill : .scaleAspectFit
        view.setImage(url: url)
    }

    public static func dismantleUIView(_ view: RemoteImageView, coordinator: ()) {
        view.setImage(url: nil)
    }
}
