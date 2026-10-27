import Core
import Foundation
import UIKit

/// Fonts for one Dynamic Type size. Built off the main actor (UIFont is
/// thread-safe) and shared by measuring and rendering, so measured and drawn
/// text always agree.
struct FeedFonts: @unchecked Sendable {
    let header: UIFont
    let title: UIFont
    let body: UIFont
    let footer: UIFont

    init(category: UIContentSizeCategory) {
        let traits = UITraitCollection(preferredContentSizeCategory: category)
        header = UIFont.preferredFont(forTextStyle: .footnote, compatibleWith: traits)
        let title = UIFont.preferredFont(forTextStyle: .headline, compatibleWith: traits)
        self.title = UIFont.systemFont(ofSize: title.pointSize + 1, weight: .semibold)
        body = UIFont.preferredFont(forTextStyle: .subheadline, compatibleWith: traits)
        footer = UIFont.monospacedDigitSystemFont(
            ofSize: UIFont.preferredFont(forTextStyle: .subheadline, compatibleWith: traits).pointSize, weight: .semibold)
    }
}

/// Everything a cell needs to place its subviews: frames and texts, computed
/// once per post and width. Cells do no measuring and no Auto Layout, so
/// scrolling only assigns frames.
struct PostLayout: Sendable, Equatable {
    let width: CGFloat
    let header: String
    let headerFrame: CGRect
    let titleFrame: CGRect
    /// The preview as drawn: the server cuts long bodies at 600 characters,
    /// so a cut one ends with an ellipsis instead of mid-word silence.
    let bodyText: String
    let bodyFrame: CGRect
    let bodyLines: Int
    let footerFrame: CGRect
    let height: CGFloat

    static let inset = UIEdgeInsets(top: 14, left: 16, bottom: 10, right: 16)
    static let spacing: CGFloat = 6
    static let footerHeight: CGFloat = 36
    static let maxBodyLines = 5

    /// Safe to call from any thread: pure measuring with thread-safe text APIs.
    static func make(for post: Post, width: CGFloat, fonts: FeedFonts, now: Date = Date()) -> PostLayout {
        let contentWidth = max(width - inset.left - inset.right, 1)
        let header = headerText(for: post, now: now)
        var y = inset.top

        let headerHeight = ceil(fonts.header.lineHeight)
        let headerFrame = CGRect(x: inset.left, y: y, width: contentWidth, height: headerHeight)
        y += headerHeight + spacing

        let titleHeight = measure(post.title, font: fonts.title, width: contentWidth, maxLines: 0)
        let titleFrame = CGRect(x: inset.left, y: y, width: contentWidth, height: titleHeight)
        y += titleHeight

        var bodyFrame = CGRect.zero
        var bodyLines = 0
        var body = post.body.trimmingCharacters(in: .whitespacesAndNewlines)
        if post.bodyTruncated && !body.isEmpty {
            body += "…"
        }
        if !body.isEmpty {
            y += spacing
            let full = measure(body, font: fonts.body, width: contentWidth, maxLines: 0)
            let capped = ceil(fonts.body.lineHeight * CGFloat(maxBodyLines))
            let bodyHeight = min(full, capped)
            bodyLines = full > capped ? maxBodyLines : 0
            bodyFrame = CGRect(x: inset.left, y: y, width: contentWidth, height: bodyHeight)
            y += bodyHeight
        }

        y += 4
        let footerFrame = CGRect(x: inset.left - 8, y: y, width: contentWidth + 16, height: footerHeight)
        y += footerHeight + inset.bottom

        return PostLayout(width: width, header: header, headerFrame: headerFrame, titleFrame: titleFrame,
                          bodyText: body, bodyFrame: bodyFrame, bodyLines: bodyLines,
                          footerFrame: footerFrame, height: ceil(y))
    }

    static func measure(_ text: String, font: UIFont, width: CGFloat, maxLines: Int) -> CGFloat {
        let rect = (text as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font], context: nil)
        return ceil(rect.height)
    }

    /// "Котики · ivan · 5 ч". The time is fixed when the page is laid out;
    /// a refresh recomputes it.
    static func headerText(for post: Post, now: Date) -> String {
        var parts = [post.community.title]
        parts.append(post.author?.username ?? "удалённый аккаунт")
        parts.append(relativeAge(from: post.createdAt, now: now))
        if post.isNsfw { parts.append("18+") }
        return parts.joined(separator: " · ")
    }

    static func relativeAge(from date: Date, now: Date) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        switch seconds {
        case ..<60: return "сейчас"
        case ..<3600: return "\(seconds / 60) мин"
        case ..<86400: return "\(seconds / 3600) ч"
        case ..<(86400 * 30): return "\(seconds / 86400) д"
        default: return date.formatted(.dateTime.day().month(.abbreviated))
        }
    }
}
