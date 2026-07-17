import UIKit
import UniformTypeIdentifiers

/// Sheet-less share extension: grabs the shared URL, stashes it in the app group for the main
/// app to import on next foreground, flashes a confirmation, and dismisses.
final class ShareViewController: UIViewController {

    /// Handoff channel — must match the app-side reader (RootView) and both entitlements files.
    private static let appGroupID = "group.com.sanylax.continuity"
    private static let pendingURLKey = "pendingSharedURL.v1"

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        extractSharedURL()
    }

    /// Walks the attachments for the first public.url payload.
    private func extractSharedURL() {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem])?
            .compactMap(\.attachments)
            .flatMap { $0 } ?? []
        guard let provider = providers.first(where: {
            $0.hasItemConformingToTypeIdentifier(UTType.url.identifier)
        }) else { return cancel() }

        provider.loadItem(forTypeIdentifier: UTType.url.identifier) { [weak self] item, _ in
            DispatchQueue.main.async {
                guard let self else { return }
                // Some hosts hand the URL over as bookmark-style Data rather than NSURL.
                let url = (item as? URL)
                    ?? (item as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) }
                guard let url else { return self.cancel() }
                self.stash(url)
            }
        }
    }

    /// Writes the URL + timestamp to group defaults; the app reads and clears it on foreground.
    private func stash(_ url: URL) {
        guard let defaults = UserDefaults(suiteName: Self.appGroupID) else { return cancel() }
        defaults.set(
            ["url": url.absoluteString, "sharedAt": Date().timeIntervalSince1970],
            forKey: Self.pendingURLKey
        )
        showConfirmationThenFinish()
    }

    /// Brief "Added to Continuity" pill in place of a compose sheet, then completes.
    private func showConfirmationThenFinish() {
        let label = UILabel()
        label.text = "Added to Continuity"
        label.font = .preferredFont(forTextStyle: .headline)
        label.textColor = .label
        label.textAlignment = .center
        label.backgroundColor = .secondarySystemBackground
        label.layer.cornerRadius = 14
        label.layer.masksToBounds = true
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            label.widthAnchor.constraint(equalToConstant: 240),
            label.heightAnchor.constraint(equalToConstant: 56)
        ])

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: nil)
        }
    }

    private func cancel() {
        extensionContext?.cancelRequest(
            withError: NSError(domain: "com.sanylax.continuity.share", code: 1)
        )
    }
}
