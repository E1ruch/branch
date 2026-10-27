import Core
import Foundation
import UIKit

/// Fonts for one Dynamic Type size. Built off the main actor (UIFont is
/// thread-safe) and shared by measuring and rendering, so measured and drawn
/// text always agree.
struct FeedFonts: @unchecked Sendable {
    let author: UIFont
    let meta: UIFont
    let title: UIFont
    let body: UIFont
    let footer: UIFont

    init(category: UIContentSizeCategory) {
        let traits = UITraitCollection(preferredContentSizeCategory: category)
        func size(_ style: UIFont.TextStyle) -> CGFloat {
            UIFont.preferredFont(forTextStyle: style, compatibleWith: traits).pointSize
        }
        author = .systemFont(ofSize: size(.subheadline), weight: .semibold)
        meta = .preferredFont(forTextStyle: .footnote, compatibleWith: traits)
        title = .systemFont(ofSize: size(.headline) + 1, weight: .bold)
        body = .preferredFont(forTextStyle: .subheadline, compatibleWith: traits)
        footer = .monospacedDigitSystemFont(ofSize: size(.subheadline), weight: .semibold)
    }
}

/// Everything a cell needs to place its subviews: frames and texts, computed
/// once per post and width. Cells do no measuring and no Auto Layout, so
/// scrolling only assigns frames.
struct PostLayout: Sendable, Equatable {
    let width: CGFloat
    let author: String
    /// "2 ч назад · Котики".
    let meta: String
    let avatarFrame: CGRect
    let authorFrame: CGRect
    let metaFrame: CGRect
    let moreFrame: CGRect
    let titleFrame: CGRect
    /// The preview as drawn: the server cuts long bodies at 600 characters,
    /// so a cut one ends with an ellipsis instead of mid-word silence.
    let bodyText: String
    let bodyFrame: CGRect
    let bodyLines: Int
    let footerFrame: CGRect
    /// Where the post ends and the gap to the next one begins.
    let contentHeight: CGFloat
    let height: CGFloat

    static let inset = UIEdgeInsets(top: 14, left: 16, bottom: 6, right: 16)
    static let avatarSize: CGFloat = 36
    static let spacing: CGFloat = 8
    static let footerHeight: CGFloat = 40
    static let gap: CGFloat = 8
    static let maxBodyLines = 5

    /// Safe to call from any thread: pure measuring with thread-safe text APIs.
    static func make(for post: Post, width: CGFloat, fonts: FeedFonts, now: Date = Date()) -> PostLayout {
        let contentWidth = max(width - inset.left - inset.right, 1)
        var y = inset.top

        let avatarFrame = CGRect(x: inset.left, y: y, width: avatarSize, height: avatarSize)
        let textX = avatarFrame.maxX + 10
        let moreFrame = CGRect(x: width - inset.right - 36, y: y - 4, width: 44, height: 44)
        let textWidth = max(moreFrame.minX - textX - 4, 1)
        let authorHeight = ceil(fonts.author.lineHeight)
        let metaHeight = ceil(fonts.meta.lineHeight)
        let textBlock = authorHeight + 1 + metaHeight
        let textTop = y + max(0, (avatarSize - textBlock) / 2)
        let authorFrame = CGRect(x: textX, y: textTop, width: textWidth, height: authorHeight)
        let metaFrame = CGRect(x: textX, y: authorFrame.maxY + 1, width: textWidth, height: metaHeight)
        y += max(avatarSize, textBlock) + 10

        let titleHeight = measure(post.title, font: fonts.title, width: contentWidth)
        let titleFrame = CGRect(x: inset.left, y: y, width: contentWidth, height: titleHeight)
        y += titleHeight

        var body = post.body.trimmingCharacters(in: .whitespacesAndNewlines)
        if post.bodyTruncated && !body.isEmpty {
            body += "…"
        }
        var bodyFrame = CGRect.zero
        var bodyLines = 0
        if !body.isEmpty {
            y += 6
            let full = measure(body, font: fonts.body, width: contentWidth)
            let capped = ceil(fonts.body.lineHeight * CGFloat(maxBodyLines))
            let bodyHeight = min(full, capped)
            bodyLines = full > capped ? maxBodyLines : 0
            bodyFrame = CGRect(x: inset.left, y: y, width: contentWidth, height: bodyHeight)
            y += bodyHeight
        }

        y += 6
        // The vote buttons sit flush with the text's left edge by their glyph,
        // not by their larger tap area.
        let footerFrame = CGRect(x: inset.left - 12, y: y, width: contentWidth + 24, height: footerHeight)
        y += footerHeight + inset.bottom

        return PostLayout(width: width, author: post.author?.username ?? "удалённый аккаунт",
                          meta: metaText(for: post, now: now),
                          avatarFrame: avatarFrame, authorFrame: authorFrame, metaFrame: metaFrame,
                          moreFrame: moreFrame, titleFrame: titleFrame,
                          bodyText: body, bodyFrame: bodyFrame, bodyLines: bodyLines,
                          footerFrame: footerFrame, contentHeight: ceil(y), height: ceil(y + gap))
    }

    static func measure(_ text: String, font: UIFont, width: CGFloat) -> CGFloat {
        let rect = (text as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font], context: nil)
        return ceil(rect.height)
    }

    /// The time is fixed when the page is laid out; a refresh recomputes it.
    static func metaText(for post: Post, now: Date) -> String {
        var parts = [relativeAge(from: post.createdAt, now: now), post.community.title]
        if post.isNsfw { parts.append("18+") }
        return parts.joined(separator: " · ")
    }

    static func relativeAge(from date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        switch seconds {
        case ..<60: return "только что"
        case ..<3600: return "\(seconds / 60) мин назад"
        case ..<86400: return "\(seconds / 3600) ч назад"
        case ..<(86400 * 30): return "\(seconds / 86400) д назад"
        default: return date.formatted(.dateTime.day().month(.abbreviated))
        }
    }
}
