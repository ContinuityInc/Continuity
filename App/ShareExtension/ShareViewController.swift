import UIKit
import UniformTypeIdentifiers
import ContinuityCore

/// Sheet-less share extension: grabs the shared URL, stashes it in the app group for the main
/// app to import on next foreground, flashes a confirmation, and dismisses.
final class ShareViewController: UIViewController {

    /// Handoff channel — must match the app-side reader (RootView) and both entitlements files.
    private static let appGroupID = "group.com.sanylax.continuity"
    private static let pendingURLKey = "pendingSharedURL.v1"

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        // External TestFlight / App Store builds do not import YouTube or Spotify audio.
        finish(message: "Import not available in this build", succeed: false)
    }

    /// Walks attachments for a URL (or a plain-text string that parses as one).
    private func extractSharedURL() {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem])?
            .compactMap(\.attachments)
            .flatMap { $0 } ?? []

        if let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.url.identifier)
        }) {
            provider.loadItem(forTypeIdentifier: UTType.url.identifier) { [weak self] item, _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    // Some hosts hand the URL over as bookmark-style Data rather than NSURL.
                    let url = (item as? URL)
                        ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                    guard let url else { return self.finishUnsupported() }
                    self.acceptIfImportable(url)
                }
            }
            return
        }

        // Spotify (and some browsers) share the link as plain text alongside/instead of public.url.
        if let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier)
        }) {
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) { [weak self] item, _ in
                DispatchQueue.main.async {
                    guard let self else { return }
                    let raw = (item as? String)
                        ?? (item as? Data).flatMap { String(data: $0, encoding: .utf8) }
                    guard let raw, let url = Self.firstURL(in: raw) else {
                        return self.finishUnsupported()
                    }
                    self.acceptIfImportable(url)
                }
            }
            return
        }

        finishUnsupported()
    }

    /// Only stash + cheer when ContinuityCore can classify the link — otherwise the main app
    /// would silently drop it after we already told the user it worked.
    private func acceptIfImportable(_ url: URL) {
        let raw = url.absoluteString
        let importable = SpotifyURL.parse(raw) != nil || YouTubeURL.parse(raw) != nil
        guard importable else { return finishUnsupported() }
        stash(url)
    }

    /// Writes the URL + timestamp to group defaults; the app reads and clears it on foreground.
    private func stash(_ url: URL) {
        guard let defaults = UserDefaults(suiteName: Self.appGroupID) else {
            return finish(message: "Couldn't hand off to Continuity", succeed: false)
        }
        defaults.set(
            ["url": url.absoluteString, "sharedAt": Date().timeIntervalSince1970],
            forKey: Self.pendingURLKey
        )
        finish(message: "Added to Continuity", succeed: true)
    }

    private func finishUnsupported() {
        finish(message: "Can't import this link", succeed: false)
    }

    /// Brief status pill, then complete or cancel the share request.
    private func finish(message: String, succeed: Bool) {
        let label = UILabel()
        label.text = message
        label.font = .preferredFont(forTextStyle: .headline)
        label.textColor = .label
        label.textAlignment = .center
        label.backgroundColor = .secondarySystemBackground
        label.layer.cornerRadius = 14
        label.layer.masksToBounds = true
        label.translatesAutoresizingMaskIntoConstraints = false
        label.isAccessibilityElement = true
        label.accessibilityTraits = .staticText
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            label.widthAnchor.constraint(greaterThanOrEqualToConstant: 240),
            label.widthAnchor.constraint(lessThanOrEqualToConstant: 300),
            label.heightAnchor.constraint(equalToConstant: 56)
        ])
        UIAccessibility.post(notification: .announcement, argument: message)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in
            guard let self else { return }
            if succeed {
                self.extensionContext?.completeRequest(returningItems: nil)
            } else {
                self.extensionContext?.cancelRequest(
                    withError: NSError(domain: "com.sanylax.continuity.share", code: 1)
                )
            }
        }
    }

    /// First http(s) URL token in a shared text blob, if any.
    private static func firstURL(in raw: String) -> URL? {
        let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        let range = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        guard let match = detector?.firstMatch(in: raw, options: [], range: range),
              let url = match.url else { return nil }
        return url
    }
}
