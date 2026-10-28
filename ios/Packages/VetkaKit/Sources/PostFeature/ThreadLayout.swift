import Core
import DesignSystem
import Foundation
import UIKit

/// Fonts for one Dynamic Type size, shared by measuring and drawing so the
/// two always agree. Built off the main actor: UIFont is thread-safe.
struct ThreadFonts: @unchecked Sendable {
    let postCommunity: UIFont
    let postMeta: UIFont
    let postTitle: UIFont
    let postBody: UIFont
    let footer: UIFont
    let commentHeader: UIFont
    let commentAuthor: UIFont
    let commentBody: UIFont
    let commentDeleted: UIFont
    let stub: UIFont
    let section: UIFont

    init(category: UIContentSizeCategory) {
        let traits = UITraitCollection(preferredContentSizeCategory: category)
        func size(_ style: UIFont.TextStyle) -> CGFloat {
            UIFont.preferredFont(forTextStyle: style, compatibleWith: traits).pointSize
        }
        postCommunity = .systemFont(ofSize: size(.subheadline), weight: .semibold)
        postMeta = .preferredFont(forTextStyle: .footnote, compatibleWith: traits)
        postTitle = .systemFont(ofSize: size(.title3) + 1, weight: .bold)
        postBody = .preferredFont(forTextStyle: .body, compatibleWith: traits)
        footer = .monospacedDigitSystemFont(ofSize: size(.subheadline), weight: .semibold)
        commentHeader = .preferredFont(forTextStyle: .footnote, compatibleWith: traits)
        commentAuthor = .systemFont(ofSize: size(.footnote), weight: .semibold)
        commentBody = .preferredFont(forTextStyle: .callout, compatibleWith: traits)
        let callout = UIFont.preferredFont(forTextStyle: .callout, compatibleWith: traits)
        commentDeleted = callout.fontDescriptor.withSymbolicTraits(.traitItalic).map { UIFont(descriptor: $0, size: 0) } ?? callout
        stub = .systemFont(ofSize: size(.footnote), weight: .semibold)
        section = .systemFont(ofSize: size(.headline), weight: .bold)
    }
}

enum TextMeasure {
    /// Safe off the main thread: NSString drawing APIs are thread-safe.
    static func height(_ text: String, font: UIFont, width: CGFloat) -> CGFloat {
        let rect = (text as NSString).boundingRect(
            with: CGSize(width: width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font], context: nil)
        return ceil(rect.height)
    }
}

/// The post at the top of its screen: the whole body, no line cap.
struct PostDetailLayout: Sendable, Equatable {
    let width: CGFloat
    /// What was measured, to tell whether a fresher post needs measuring again.
    let title: String
    let body: String
    let avatarFrame: CGRect
    let communityFrame: CGRect
    let metaFrame: CGRect
    let moreFrame: CGRect
    let titleFrame: CGRect
    let bodyFrame: CGRect
    let footerFrame: CGRect
    let contentHeight: CGFloat
    let height: CGFloat

    static let inset = UIEdgeInsets(top: 14, left: 16, bottom: 4, right: 16)
    static let avatarSize: CGFloat = 38
    static let footerHeight: CGFloat = 44
    /// The background strip between the post and its comments.
    static let gap: CGFloat = 8
    /// The row while the post is loading (a deep link): about a short post.
    static let placeholderHeight: CGFloat = 230

    /// A feed preview ends with an ellipsis until the full text arrives.
    static func displayBody(of post: Post) -> String {
        let body = post.body.trimmingCharacters(in: .whitespacesAndNewlines)
        return post.bodyTruncated && !body.isEmpty ? body + "…" : body
    }

    static func make(for post: Post, width: CGFloat, fonts: ThreadFonts) -> PostDetailLayout {
        let contentWidth = max(width - inset.left - inset.right, 1)
        var y = inset.top

        let avatarFrame = CGRect(x: inset.left, y: y, width: avatarSize, height: avatarSize)
        let textX = avatarFrame.maxX + 10
        let moreFrame = CGRect(x: width - inset.right - 36, y: y - 3, width: 44, height: 44)
        let textWidth = max(moreFrame.minX - textX - 4, 1)
        let communityHeight = ceil(fonts.postCommunity.lineHeight)
        let metaHeight = ceil(fonts.postMeta.lineHeight)
        let block = communityHeight + 1 + metaHeight
        let textTop = y + max(0, (avatarSize - block) / 2)
        let communityFrame = CGRect(x: textX, y: textTop, width: textWidth, height: communityHeight)
        let metaFrame = CGRect(x: textX, y: communityFrame.maxY + 1, width: textWidth, height: metaHeight)
        y += max(avatarSize, block) + 12

        let titleHeight = TextMeasure.height(post.title, font: fonts.postTitle, width: contentWidth)
        let titleFrame = CGRect(x: inset.left, y: y, width: contentWidth, height: titleHeight)
        y += titleHeight

        let body = displayBody(of: post)
        var bodyFrame = CGRect.zero
        if !body.isEmpty {
            y += 10
            let bodyHeight = TextMeasure.height(body, font: fonts.postBody, width: contentWidth)
            bodyFrame = CGRect(x: inset.left, y: y, width: contentWidth, height: bodyHeight)
            y += bodyHeight
        }

        y += 8
        let footerFrame = CGRect(x: inset.left - 12, y: y, width: contentWidth + 24, height: footerHeight)
        y += footerHeight + inset.bottom

        return PostDetailLayout(width: width, title: post.title, body: body,
                                avatarFrame: avatarFrame, communityFrame: communityFrame, metaFrame: metaFrame,
                                moreFrame: moreFrame, titleFrame: titleFrame, bodyFrame: bodyFrame,
                                footerFrame: footerFrame, contentHeight: ceil(y), height: ceil(y + gap))
    }
}

/// A comment's frames. Indentation follows depth, counted from the top of
/// the screen's thread so a continued branch starts at the left edge again.
struct CommentLayout: Sendable, Equatable {
    let width: CGFloat
    /// Visual nesting, capped so deep threads keep a readable width.
    let level: Int
    let avatarFrame: CGRect
    let headerFrame: CGRect
    /// The text as drawn: a tombstone says the comment was deleted.
    let body: String
    let bodyFrame: CGRect
    /// .zero for a deleted comment: nothing to vote on or answer.
    let footerFrame: CGRect
    let height: CGFloat
    /// Only the header line: the comment and its replies are folded.
    let collapsedHeight: CGFloat

    static let inset: CGFloat = 16
    static let indentStep: CGFloat = 18
    static let maxLevel = 6
    static let avatarSize: CGFloat = 22
    static let top: CGFloat = 10
    static let footerHeight: CGFloat = 36
    static let deletedText = "Комментарий удалён"

    static func level(depth: Int, baseDepth: Int) -> Int {
        min(max(depth - baseDepth, 0), maxLevel)
    }

    /// Where content starts at a nesting level.
    static func indent(level: Int) -> CGFloat {
        inset + CGFloat(level) * indentStep
    }

    /// The thread line of an ancestor: under the middle of its avatar.
    static func guideX(level: Int) -> CGFloat {
        indent(level: level) + avatarSize / 2
    }

    static func make(for comment: Comment, baseDepth: Int, width: CGFloat, fonts: ThreadFonts) -> CommentLayout {
        let level = level(depth: comment.depth, baseDepth: baseDepth)
        let x = indent(level: level)
        let contentWidth = max(width - x - inset, 1)
        var y = top

        let avatarFrame = CGRect(x: x, y: y, width: avatarSize, height: avatarSize)
        let headerHeight = max(avatarSize, ceil(fonts.commentAuthor.lineHeight))
        let headerFrame = CGRect(x: avatarFrame.maxX + 8, y: y + (avatarSize - headerHeight) / 2,
                                 width: max(width - inset - avatarFrame.maxX - 8, 1), height: headerHeight)
        y += avatarSize
        let collapsedHeight = ceil(y + top)
        y += 6

        let deleted = comment.isDeleted || comment.body == nil
        let body = deleted ? deletedText : (comment.body ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let bodyHeight = TextMeasure.height(body, font: deleted ? fonts.commentDeleted : fonts.commentBody, width: contentWidth)
        let bodyFrame = CGRect(x: x, y: y, width: contentWidth, height: bodyHeight)
        y += bodyHeight

        var footerFrame = CGRect.zero
        if deleted {
            y += top
        } else {
            y += 2
            // Vote arrows sit flush with the text by their glyph, not their tap area.
            footerFrame = CGRect(x: x - 12, y: y, width: contentWidth + 12, height: footerHeight)
            y += footerHeight + 2
        }
        return CommentLayout(width: width, level: level, avatarFrame: avatarFrame, headerFrame: headerFrame,
                             body: body, bodyFrame: bodyFrame, footerFrame: footerFrame,
                             height: ceil(y), collapsedHeight: collapsedHeight)
    }
}
