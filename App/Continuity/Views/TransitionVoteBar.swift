import SwiftUI
import SwiftData
import Playback
import Domain

/// Thumbs-up/down for the blend that's playing (or just played). Appears when a transition
/// starts, lingers a few seconds after it completes, then fades; voting collapses it to a brief
/// confirmation. Votes persist per directional track pair and feed `Player`'s adaptation — a
/// downvoted pair blends simpler next time, an upvoted one climbs back toward full settings.
///
/// A leaf on purpose: it observes only `votableTransition` (which changes once per blend), never
/// the 20 Hz `position`/`transitionProgress` writes, so it can't drag parent bodies into the
/// tick churn the playback jetsam RCA banned.
struct TransitionVoteBar: View {
    @Environment(Player.self) private var player
    @Environment(\.modelContext) private var modelContext

    /// Record just voted on — shows the confirmation state before hiding.
    @State private var votedRecordID: UUID?
    /// Records dismissed (auto-hide timeout or post-vote) — keyed by ID so a NEW blend reappears.
    @State private var hiddenRecordID: UUID?

    /// How long the bar stays up after the blend completes (unvoted).
    private static let lingerSeconds: Double = 10
    /// How long the "thanks" state shows before the bar hides.
    private static let confirmSeconds: Double = 1.2

    var body: some View {
        if let record = player.votableTransition, record.id != hiddenRecordID {
            HStack(spacing: 12) {
                if votedRecordID == record.id {
                    Label("Noted", systemImage: "checkmark")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .transition(.opacity)
                } else {
                    Text("Rate blend")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.white.opacity(0.7))
                    thumb("hand.thumbsup.fill", accessibility: "Good transition") {
                        vote(record, isUpvote: true)
                    }
                    thumb("hand.thumbsdown.fill", accessibility: "Bad transition") {
                        vote(record, isUpvote: false)
                    }
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 34)
            .continuityGlass(cornerRadius: 20)
            .transition(.opacity.combined(with: .scale(scale: 0.9)))
            // Restart the linger clock when the blend completes (completedAt flips nil → Date).
            .task(id: record.completedAt) {
                guard record.completedAt != nil else { return }
                try? await Task.sleep(for: .seconds(Self.lingerSeconds))
                withAnimation(.easeOut(duration: 0.4)) { hiddenRecordID = record.id }
            }
            .animation(.easeInOut(duration: 0.25), value: votedRecordID)
        }
    }

    private func thumb(_ system: String, accessibility: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibility)
    }

    private func vote(_ record: TransitionRecord, isUpvote: Bool) {
        let vote = TransitionVote(
            fromTrackID: record.fromTrackID,
            toTrackID: record.toTrackID,
            isUpvote: isUpvote,
            settings: record.settings,
            simplificationLevel: record.simplificationLevel
        )
        modelContext.insert(vote)
        try? modelContext.save()
        // The pair's cached adaptation is stale the moment the vote lands.
        player.invalidateTransitionAdaptation()

        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        votedRecordID = record.id
        Task {
            try? await Task.sleep(for: .seconds(Self.confirmSeconds))
            withAnimation(.easeOut(duration: 0.4)) { hiddenRecordID = record.id }
        }
    }
}
