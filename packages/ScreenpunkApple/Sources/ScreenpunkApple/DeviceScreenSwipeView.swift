import SwiftUI
import ScreenpunkCore
#if os(iOS)
import UIKit

/// Three native pages: a live dashboard in the center and inexpensive named
/// cards on either side. Recenter after each committed page to form a loop.
private struct DeviceScreenSwipeView<Content: View>: UIViewControllerRepresentable {
    let content: Content
    let screens: [LANScreenSetEntry]
    let selectedID: String?
    let enabled: Bool
    let onSwipe: (Int) -> Void

    func makeUIViewController(context: Context) -> ScreenSwipeController<Content> {
        ScreenSwipeController(content: content, screens: screens, selectedID: selectedID, enabled: enabled, onSwipe: onSwipe)
    }
    func updateUIViewController(_ controller: ScreenSwipeController<Content>, context: Context) {
        controller.update(content: content, screens: screens, selectedID: selectedID, enabled: enabled, onSwipe: onSwipe)
    }
}

private final class HorizontalPageScrollView: UIScrollView {
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === panGestureRecognizer {
            let velocity = panGestureRecognizer.velocity(in: self)
            guard abs(velocity.x) > abs(velocity.y) * 1.25 else { return false }
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }
}

private final class ScreenSwipeController<Content: View>: UIViewController, UIScrollViewDelegate {
    override var prefersStatusBarHidden: Bool { true }
    private let host: UIHostingController<Content>
    private let scroll = HorizontalPageScrollView()
    private let previous = UIView()
    private let nextCard = UIView()
    private var screens: [LANScreenSetEntry]
    private var selectedID: String?
    private var onSwipe: (Int) -> Void
    private var pageSize = CGSize.zero
    private var recentering = false

    init(content: Content, screens: [LANScreenSetEntry], selectedID: String?, enabled: Bool, onSwipe: @escaping (Int) -> Void) {
        host = UIHostingController(rootView: content)
        self.screens = screens; self.selectedID = selectedID; self.onSwipe = onSwipe
        super.init(nibName: nil, bundle: nil)
        view.backgroundColor = .black
        scroll.isPagingEnabled = true
        scroll.panGestureRecognizer.minimumNumberOfTouches = 2
        scroll.panGestureRecognizer.maximumNumberOfTouches = 2
        scroll.isDirectionalLockEnabled = true
        scroll.bounces = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.showsVerticalScrollIndicator = false
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.delegate = self
        scroll.isScrollEnabled = enabled && screens.count > 1
        view.addSubview(scroll)
        addChild(host)
        scroll.addSubview(previous); scroll.addSubview(host.view); scroll.addSubview(nextCard)
        host.didMove(toParent: self)
        host.view.backgroundColor = .black
        updateCards()
    }
    @MainActor required init?(coder: NSCoder) { fatalError("Use init(content:screens:selectedID:enabled:onSwipe:)") }

    func update(content: Content, screens: [LANScreenSetEntry], selectedID: String?, enabled: Bool, onSwipe: @escaping (Int) -> Void) {
        let changed = self.selectedID != selectedID || self.screens != screens
        self.screens = screens; self.selectedID = selectedID; self.onSwipe = onSwipe
        host.rootView = content
        scroll.isScrollEnabled = enabled && screens.count > 1
        if changed {
            updateCards()
            center()
            UIAccessibility.post(notification: .announcement, argument: screens.first(where: { $0.dashboardId == selectedID })?.name)
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let size = view.bounds.size
        guard size.width > 0, size.height > 0 else { return }
        let resized = pageSize != size
        pageSize = size
        scroll.frame = view.bounds
        scroll.contentSize = CGSize(width: size.width * 3, height: size.height)
        previous.frame = CGRect(origin: .zero, size: size)
        host.view.frame = CGRect(x: size.width, y: 0, width: size.width, height: size.height)
        nextCard.frame = CGRect(x: size.width * 2, y: 0, width: size.width, height: size.height)
        if resized { center() }
    }

    private func center() {
        recentering = true
        scroll.setContentOffset(CGPoint(x: pageSize.width, y: 0), animated: false)
        recentering = false
    }
    private func updateCards() {
        guard let current = screens.firstIndex(where: { $0.dashboardId == selectedID }), !screens.isEmpty else { return }
        if let index = ScreenCarousel.index(from: current, offset: -1, count: screens.count) { configure(previous, index: index) }
        if let index = ScreenCarousel.index(from: current, offset: 1, count: screens.count) { configure(nextCard, index: index) }
    }
    private func configure(_ card: UIView, index: Int) {
        card.subviews.forEach { $0.removeFromSuperview() }
        card.backgroundColor = UIColor(white: 0.06, alpha: 1)
        let stack = UIStackView(); stack.axis = .vertical; stack.alignment = .center; stack.spacing = 18
        let icon = UIImageView(image: UIImage(systemName: "rectangle.stack"))
        icon.tintColor = .white; icon.contentMode = .scaleAspectFit
        icon.heightAnchor.constraint(equalToConstant: 56).isActive = true
        icon.widthAnchor.constraint(equalToConstant: 72).isActive = true
        let title = UILabel(); title.text = screens[index].name; title.textColor = .white
        title.font = .preferredFont(forTextStyle: .title1); title.numberOfLines = 3; title.textAlignment = .center
        let position = UILabel(); position.text = "\(index + 1) of \(screens.count)"
        position.font = .preferredFont(forTextStyle: .subheadline); position.textColor = .lightGray
        stack.addArrangedSubview(icon); stack.addArrangedSubview(title); stack.addArrangedSubview(position)
        stack.translatesAutoresizingMaskIntoConstraints = false; card.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: card.centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: card.widthAnchor, multiplier: 0.8)
        ])
    }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { commitPage() }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { commitPage() }
    }
    private func commitPage() {
        guard !recentering, pageSize.width > 0 else { return }
        let page = Int((scroll.contentOffset.x / pageSize.width).rounded())
        guard page != 1 else { return }
        onSwipe(page < 1 ? -1 : 1)
        // State updates rebuild the selected live page. A failed selection also
        // returns to the current page instead of trapping the user on a card.
        DispatchQueue.main.async { [weak self] in self?.center() }
    }
}
#endif

extension View {
    @ViewBuilder
    func deviceScreenSwipes(screens: [LANScreenSetEntry], selectedID: String?, enabled: Bool,
                            onSwipe: @escaping (Int) -> Void) -> some View {
#if os(iOS)
        DeviceScreenSwipeView(content: self, screens: screens, selectedID: selectedID, enabled: enabled, onSwipe: onSwipe)
#else
        self
#endif
    }
}
