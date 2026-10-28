import DesignSystem
import UIKit

/// A page of HeaderPagerViewController: anything that scrolls.
@MainActor
public protocol ScrollPage: UIViewController {
    var scrollView: UIScrollView { get }
}

/// The header a pager scrolls away.
@MainActor
public protocol PagerHeader: UIView {
    /// Where the header's title ends. Once it has scrolled under the
    /// navigation bar, the screen shows the title there instead.
    var titleMaxY: CGFloat { get }
}

/// A header, pill tabs under it and one page per tab: the community page
/// and the profile. The header scrolls away with the page and the tabs pin
/// to the top.
///
/// The header is laid over the pages, not inside them: every page keeps its
/// own list (and scroll position), and raising the pages' safe area makes
/// room for the header, so a feed does not need to know it has one. Touches
/// on the header that miss its buttons fall through to the page below, so
/// a drag that starts on the header still scrolls.
///
/// Switching tabs keeps the header where it was: a page scrolled less than
/// the header follows the current one, a page further down stays put.
public final class HeaderPagerViewController: UIViewController {
    public private(set) var selectedIndex: Int
    /// The header's title went under the navigation bar (true) or came back.
    public var onTitleHidden: ((Bool) -> Void)?

    private let header: any PagerHeader
    private let pages: [any ScrollPage]
    private let overlay = PassthroughView()
    private let tabBar = UIView()
    private let tabs: PillTabs
    private let hairline = UIView()
    private var observations: [NSKeyValueObservation] = []
    private var headerHeight: CGFloat = 0
    private var measuredWidth: CGFloat = 0
    private var isTitleHidden = false

    private static let tabBarPadding = UIEdgeInsets(top: Spacing.xs, left: Spacing.l, bottom: Spacing.s, right: Spacing.l)

    public init(header: any PagerHeader, titles: [String], pages: [any ScrollPage], selectedIndex: Int = 0) {
        precondition(titles.count == pages.count, "one title per page")
        self.header = header
        self.pages = pages
        self.selectedIndex = selectedIndex
        tabs = PillTabs(titles: titles, selectedIndex: selectedIndex)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = Palette.background
        for (index, page) in pages.enumerated() {
            addChild(page)
            view.addSubview(page.view)
            page.didMove(toParent: self)
            setVisible(index == selectedIndex, page)
            observe(page)
        }

        overlay.clipsToBounds = true
        view.addSubview(overlay)
        header.backgroundColor = Palette.surface
        overlay.addSubview(header)
        tabBar.backgroundColor = Palette.surface
        hairline.backgroundColor = Palette.border
        tabBar.addSubview(tabs)
        tabBar.addSubview(hairline)
        overlay.addSubview(tabBar)
        tabs.onSelect = { [weak self] in self?.show($0) }
    }

    /// The header's content changed (loaded, longer description): measure
    /// it again on the next layout.
    public func headerDidChange() {
        measuredWidth = 0
        view.setNeedsLayout()
    }

    public override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let width = view.bounds.width
        if width != measuredWidth {
            measuredWidth = width
            headerHeight = ceil(header.systemLayoutSizeFitting(
                CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
                withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel).height)
        }
        let tabsSize = tabs.sizeThatFits(view.bounds.size)
        let padding = Self.tabBarPadding
        let tabBarHeight = tabsSize.height + padding.top + padding.bottom
        tabs.frame = CGRect(origin: CGPoint(x: padding.left, y: padding.top), size: tabsSize)
        let pixel = 1 / max(traitCollection.displayScale, 1)
        hairline.frame = CGRect(x: 0, y: tabBarHeight - pixel, width: width, height: pixel)
        overlay.frame = view.bounds
        header.frame.size = CGSize(width: width, height: headerHeight)
        tabBar.frame.size = CGSize(width: width, height: tabBarHeight)

        let top = headerHeight + tabBarHeight
        for page in pages {
            page.view.frame = view.bounds
            guard page.additionalSafeAreaInsets.top != top else { continue }
            // Keep each page where it was relative to the header, whatever
            // the scroll view does with its offset when the inset grows.
            let scroll = page.scrollView
            let position = scroll.contentOffset.y + scroll.adjustedContentInset.top
            page.additionalSafeAreaInsets.top = top
            page.view.layoutIfNeeded()
            scroll.contentOffset.y = max(position, 0) - scroll.adjustedContentInset.top
        }
        pages.forEach(padBottom)
        layoutOverlay()
    }

    // MARK: Scrolling

    private func observe(_ page: any ScrollPage) {
        let scroll = page.scrollView
        observations.append(scroll.observe(\.contentOffset) { [weak self, weak page] _, _ in
            MainActor.assumeIsolated {
                guard let self, let page, page === self.pages[self.selectedIndex] else { return }
                self.layoutOverlay()
            }
        })
        observations.append(scroll.observe(\.contentSize) { [weak self, weak page] _, _ in
            MainActor.assumeIsolated {
                guard let self, let page else { return }
                self.padBottom(page)
            }
        })
    }

    /// How far the page has scrolled from its resting top (negative while
    /// pulled down for a refresh).
    private func position(of page: any ScrollPage) -> CGFloat {
        page.scrollView.contentOffset.y + page.scrollView.adjustedContentInset.top
    }

    private func setPosition(_ position: CGFloat, of page: any ScrollPage) {
        page.scrollView.contentOffset.y = position - page.scrollView.adjustedContentInset.top
    }

    private func layoutOverlay() {
        guard headerHeight > 0 || measuredWidth > 0 else { return }
        // Pulled down, the header stays: the refresh spinner shows between
        // the tabs and the list.
        let collapse = min(max(position(of: pages[selectedIndex]), 0), headerHeight)
        header.frame.origin = CGPoint(x: 0, y: -collapse)
        tabBar.frame.origin = CGPoint(x: 0, y: headerHeight - collapse)

        let hidden = collapse >= header.titleMaxY && header.titleMaxY > 0
        if hidden != isTitleHidden {
            isTitleHidden = hidden
            onTitleHidden?(hidden)
        }
    }

    /// A short page still scrolls far enough to tuck the header away, so
    /// switching to it from a scrolled page does not drop the header back.
    private func padBottom(_ page: any ScrollPage) {
        let scroll = page.scrollView
        let base = scroll.adjustedContentInset.bottom - scroll.contentInset.bottom
        let visible = scroll.bounds.height - scroll.adjustedContentInset.top - base
        let needed = max(0, ceil(headerHeight + visible - scroll.contentSize.height))
        if scroll.contentInset.bottom != needed {
            scroll.contentInset.bottom = needed
        }
    }

    // MARK: Tabs

    private func show(_ index: Int) {
        guard index != selectedIndex else { return }
        let current = pages[selectedIndex], next = pages[index]
        let collapse = min(max(position(of: current), 0), headerHeight)
        if collapse < headerHeight {
            setPosition(collapse, of: next)
        } else if position(of: next) < headerHeight {
            setPosition(headerHeight, of: next)
        }
        setVisible(false, current)
        setVisible(true, next)
        selectedIndex = index
        layoutOverlay()
    }

    private func setVisible(_ visible: Bool, _ page: any ScrollPage) {
        page.view.isHidden = !visible
        page.scrollView.scrollsToTop = visible
    }

    /// Re-taps of the tab bar item and status bar taps.
    public func scrollToTop() {
        let scroll = pages[selectedIndex].scrollView
        scroll.setContentOffset(CGPoint(x: 0, y: -scroll.adjustedContentInset.top), animated: true)
    }
}

/// Lets touches through except on controls: a drag on the header's text
/// scrolls the page under it, a tap on its button still lands.
private final class PassthroughView: UIView {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard let hit = super.hitTest(point, with: event) else { return nil }
        var view: UIView? = hit
        while let current = view, current !== self {
            if current is UIControl || current.gestureRecognizers?.isEmpty == false {
                return hit
            }
            view = current.superview
        }
        return nil
    }
}
