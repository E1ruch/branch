import UIKit

/// The gallery's frame in the cell and the photos' frames in its scroll view.
public struct PostImagesLayout: Sendable, Equatable {
    public let frame: CGRect
    let imageFrames: [CGRect]

    public static func make(aspectRatios: [CGFloat], origin: CGPoint, width: CGFloat, isPreview: Bool) -> Self? {
        guard let first = aspectRatios.first else { return nil }
        if aspectRatios.count == 1 {
            let minRatio: CGFloat = isPreview ? 0.85 : 0.6
            let height = ceil(width / min(3, max(minRatio, first)))
            let frame = CGRect(origin: origin, size: CGSize(width: width, height: height))
            return Self(frame: frame, imageFrames: [CGRect(origin: .zero, size: frame.size)])
        }

        let height = min(230, ceil(width * 0.65))
        let gap = min(6, width * 0.04)
        // Leave part of the next photo visible even after a wide first photo.
        let maxPhotoWidth = width - gap - min(40, width * 0.16)
        let frame = CGRect(origin: origin, size: CGSize(width: width, height: height))
        var x: CGFloat = 0
        let imageFrames = aspectRatios.map { ratio in
            let photoWidth = min(maxPhotoWidth, ceil(height * max(0.65, ratio)))
            let photo = CGRect(x: x, y: 0, width: photoWidth, height: height)
            x = photo.maxX + gap
            return photo
        }
        return Self(frame: frame, imageFrames: imageFrames)
    }
}

private final class PostImagesScrollView: UIScrollView {
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === panGestureRecognizer {
            let velocity = panGestureRecognizer.velocity(in: self)
            guard abs(velocity.x) > abs(velocity.y) else { return false }
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }
}

public final class PostImagesView: UIView {
    private let scrollView = PostImagesScrollView()
    private var images: [RemoteImageView] = []

    public var isScrollable: Bool { scrollView.isScrollEnabled }

    public override init(frame: CGRect) {
        super.init(frame: frame)
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.delaysContentTouches = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.scrollsToTop = false
        scrollView.isDirectionalLockEnabled = true
        scrollView.accessibilityIdentifier = "post.gallery"
        addSubview(scrollView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    public func configure(_ items: [(url: URL?, thumbhash: String)], isPreview: Bool) {
        while images.count < items.count {
            let view = RemoteImageView()
            view.clipsToBounds = true
            view.layer.cornerRadius = 8
            view.isAccessibilityElement = true
            view.accessibilityTraits = .image
            scrollView.addSubview(view)
            images.append(view)
        }
        for (index, view) in images.enumerated() {
            let item = index < items.count ? items[index] : nil
            view.isHidden = item == nil
            view.accessibilityLabel = "Фото \(index + 1) из \(items.count)"
            view.contentMode = isPreview ? .scaleAspectFill : .scaleAspectFit
            view.backgroundColor = Palette.surfaceTertiary
            view.setImage(url: item?.url, thumbhash: item?.thumbhash, maxPixelSize: isPreview ? 1080 : 1440)
        }
        isHidden = items.isEmpty
        if items.count < 2 { scrollView.contentOffset = .zero }
    }

    public func place(_ layout: PostImagesLayout?) {
        frame = layout?.frame ?? .zero
        scrollView.frame = bounds
        let imageFrames = layout?.imageFrames ?? []
        for (image, frame) in zip(images, imageFrames) { image.frame = frame }
        let contentWidth = imageFrames.last?.maxX ?? 0
        scrollView.contentSize = CGSize(width: contentWidth, height: bounds.height)
        let maxOffset = max(0, contentWidth - bounds.width)
        scrollView.isScrollEnabled = maxOffset > 0
        isUserInteractionEnabled = isScrollable
        if !scrollView.isDragging, !scrollView.isDecelerating, scrollView.contentOffset.x > maxOffset {
            scrollView.contentOffset = CGPoint(x: maxOffset, y: 0)
        }
    }
}
