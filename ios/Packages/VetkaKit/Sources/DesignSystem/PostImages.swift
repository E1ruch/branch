import UIKit

/// Geometry is computed from metadata with the rest of the cell layout.
public enum PostImages {
    public static func frames(aspectRatios: [CGFloat], in area: CGRect, isPreview: Bool) -> [CGRect] {
        guard let first = aspectRatios.first else { return [] }
        let gap = min(4, area.width / 3)
        if isPreview, aspectRatios.count > 1 {
            let width = (area.width - gap) / 2
            let height = width * 0.8
            return aspectRatios.indices.map { index in
                let isLastSingle = index == aspectRatios.count - 1 && index.isMultiple(of: 2)
                return CGRect(x: area.minX + CGFloat(index % 2) * (width + gap),
                              y: area.minY + CGFloat(index / 2) * (height + gap),
                              width: isLastSingle ? area.width : width, height: height)
            }
        }

        let minRatio: CGFloat = isPreview ? 0.85 : 0.6
        var y = area.minY
        return (isPreview ? [first] : aspectRatios).map { ratio in
            let height = ceil(area.width / min(3, max(minRatio, ratio)))
            let frame = CGRect(x: area.minX, y: y, width: area.width, height: height)
            y += height + gap
            return frame
        }
    }
}

public final class PostImagesView: UIView {
    private var images: [RemoteImageView] = []

    public func configure(_ items: [(url: URL?, thumbhash: String)], isPreview: Bool) {
        while images.count < items.count {
            let view = RemoteImageView()
            view.clipsToBounds = true
            view.layer.cornerRadius = 8
            view.isAccessibilityElement = true
            view.accessibilityTraits = .image
            addSubview(view)
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
    }

    public func place(in bounds: CGRect, frames: [CGRect]) {
        frame = bounds
        for (image, frame) in zip(images, frames) { image.frame = frame }
    }
}
