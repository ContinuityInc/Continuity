import SwiftUI
import Domain
import Ingest
import SwiftData

/// Live ingest queue: every track currently downloading, analysing, or waiting for a slot.
struct DownloadsView: View {
    @Environment(PreparationQueue.self) private var prepQueue
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if prepQueue.ingestJobs.isEmpty {
                    ContentUnavailableView(
                        "Nothing downloading",
                        systemImage: "arrow.down.circle",
                        description: Text("Imported songs show up here until their audio is ready.")
                    )
                } else {
                    List {
                        ForEach(prepQueue.ingestJobs) { job in
                            jobRow(job)
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Downloads")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private func jobRow(_ job: IngestJob) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(job.title).lineLimit(1)
                    if job.isPrioritized {
                        Image(systemName: "arrow.up")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.tint)
                            .accessibilityLabel("Prioritized")
                    }
                }
                Text(job.artist)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                phaseLabel(job)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                if job.phase == .downloading, let fraction = job.fraction {
                    ProgressView(value: fraction)
                        .padding(.top, 2)
                } else if job.phase != .queued {
                    ProgressView()
                        .padding(.top, 2)
                }
            }
            Spacer(minLength: 8)
            if !job.isPrioritized {
                Button {
                    prioritize(job)
                } label: {
                    Image(systemName: "arrow.up.to.line")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Download first")
            }
        }
        .padding(.vertical, 4)
    }

    private func phaseLabel(_ job: IngestJob) -> Text {
        switch job.phase {
        case .queued:
            return Text("Waiting")
        case .downloading:
            if let fraction = job.fraction {
                return Text("Downloading \(Int((fraction * 100).rounded()))%")
            }
            return Text("Downloading")
        case .analyzing:
            return Text("Analyzing")
        }
    }

    private func prioritize(_ job: IngestJob) {
        let jobID = job.id
        var descriptor = FetchDescriptor<Track>(predicate: #Predicate { $0.id == jobID })
        descriptor.fetchLimit = 1
        guard let track = try? modelContext.fetch(descriptor).first else { return }
        prepQueue.prioritize(track, in: modelContext)
    }
}
