import SwiftUI
import UIKit

/// Window safe-area insets measured by `MainPagerView`, threaded into Library / Up Next
/// so each `NavigationStack` can restore them onto its own `UINavigationController`.
private struct PagerSafeAreaInsetsKey: EnvironmentKey {
    static let defaultValue: EdgeInsets = EdgeInsets()
}

extension EnvironmentValues {
    var pagerSafeAreaInsets: EdgeInsets {
        get { self[PagerSafeAreaInsetsKey.self] }
        set { self[PagerSafeAreaInsetsKey.self] = newValue }
    }
}

/// Re-introduces the window's safe-area insets for a pager page whose ancestor
/// `ScrollView` called `ignoresSafeArea()`.
///
/// Without this, `NavigationStack` is laid out in a zero-inset world, so its bar
/// cannot extend under the status bar — and the only workaround (hard
/// `.padding(.top, insets.top)` around the whole page) leaves a dead band above
/// the bar that reads as a seam. Applying the insets as `additionalSafeAreaInsets`
/// on that page's `UINavigationController` lets the bar background run
/// edge-to-edge while title and buttons still clear the status icons.
///
/// Scoped to `UINavigationController` on purpose: all three pager pages live in
/// the view tree at once, and writing insets onto the shared root hosting
/// controller would double-inset Now Playing (which still uses hard padding).
struct PagerSafeAreaRestorer: UIViewRepresentable {
    var insets: EdgeInsets

    func makeUIView(context: Context) -> ProbeView {
        ProbeView()
    }

    func updateUIView(_ view: ProbeView, context: Context) {
        view.targetInsets = UIEdgeInsets(
            top: insets.top,
            left: insets.leading,
            bottom: insets.bottom,
            right: insets.trailing
        )
    }

    final class ProbeView: UIView {
        var targetInsets: UIEdgeInsets = .zero {
            didSet { applyIfNeeded() }
        }

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            backgroundColor = .clear
            isOpaque = false
        }

        required init?(coder: NSCoder) { nil }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            applyIfNeeded()
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            applyIfNeeded()
        }

        private func applyIfNeeded() {
            guard let navigation = nearestNavigationController() else { return }
            // Only write when the value changes — layoutSubviews is hot during paging.
            if navigation.additionalSafeAreaInsets != targetInsets {
                navigation.additionalSafeAreaInsets = targetInsets
            }
            // NavigationStack hosts an opaque grouped fill by default, which covers the
            // shared pager backdrop and creates a hard wall at every page boundary.
            clearOpaqueBackgrounds(in: navigation)
        }

        /// Walks the responder / superview chain. This probe is attached *inside*
        /// the NavigationStack's root content, so the chain reaches that stack's
        /// `UINavigationController` without crossing into a sibling page.
        private func nearestNavigationController() -> UINavigationController? {
            var responder: UIResponder? = self
            while let current = responder {
                if let nav = current as? UINavigationController {
                    return nav
                }
                if let viewController = current as? UIViewController {
                    if let nav = viewController.navigationController { return nav }
                }
                responder = current.next
            }
            var view: UIView? = superview
            while let current = view {
                if let nav = current.next as? UINavigationController {
                    return nav
                }
                if let viewController = current.next as? UIViewController {
                    if let nav = viewController as? UINavigationController { return nav }
                    if let nav = viewController.navigationController { return nav }
                }
                view = current.superview
            }
            return nil
        }

        private func clearOpaqueBackgrounds(in navigation: UINavigationController) {
            navigation.view.backgroundColor = .clear
            navigation.view.isOpaque = false
            for child in navigation.children {
                child.view.backgroundColor = .clear
                child.view.isOpaque = false
            }
        }
    }
}

extension View {
    /// Full-bleed pager page sized to one screen, with measured insets available to
    /// the NavigationStack inside via `pagerSafeAreaInsets`.
    func pagerNavigationPage(insets: EdgeInsets) -> some View {
        self
            .environment(\.pagerSafeAreaInsets, insets)
            .containerRelativeFrame(.vertical)
    }

    /// Attach inside a pager `NavigationStack` so the bar extends under the status
    /// bar and opaque UIKit fills don't cover the shared backdrop bleed.
    func restorePagerSafeArea() -> some View {
        modifier(RestorePagerSafeAreaModifier())
    }
}

private struct RestorePagerSafeAreaModifier: ViewModifier {
    @Environment(\.pagerSafeAreaInsets) private var insets

    func body(content: Content) -> some View {
        content.background { PagerSafeAreaRestorer(insets: insets) }
    }
}
