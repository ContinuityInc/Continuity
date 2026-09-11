import SwiftUI
import Ingest

/// Live ingest affordance: arrow + remaining-job count in one glass capsule.
///
/// Isolated so `ingestJobs` updates (byte progress included) only invalidate this control,
/// not the library grid or Now Playing chrome. The count is a single token (`19`, not
/// `4/4 19`) with `lineLimit(1)` + `fixedSize` so a toolbar or island-adjacent slot
/// cannot wrap it onto two lines.
struct DownloadQueueButton: View {
    @Environment(PreparationQueue.self) private var prepQueue
    @Binding var showingDownloads: Bool
    /// Library toolbar stays visible so Downloads is always reachable. Now Playing hides
    /// the control when the queue is empty so it doesn't sit under the Dynamic Island.
    var showsWhenEmpty: Bool = true

    var body: some View {
        let count = prepQueue.ingestJobs.count
        if showsWhenEmpty || count > 0 {
            Button {
                showingDownloads = true
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: count == 0 ? "arrow.down.circle" : "arrow.down.circle.fill")
                    if count > 0 {
                        Text("\(count)")
                            .font(.caption.weight(.bold).monospacedDigit())
                            .lineLimit(1)
                            .minimumScaleFactor(1)
                    }
                }
                .padding(.horizontal, count > 0 ? 10 : 8)
                .padding(.vertical, 6)
                .continuityGlassCapsule(interactive: true)
                // Grow with the digits; never compress into a square that wraps `419` as `4/4`/`19`.
                .fixedSize(horizontal: true, vertical: true)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(count == 0 ? "Downloads" : "\(count) downloads in progress")
        }
    }
}
