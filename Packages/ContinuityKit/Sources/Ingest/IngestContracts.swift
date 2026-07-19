import Foundation
import ContinuityCore

/// Errors surfaced by the local-file ingest pipeline (import → analyse → ready).
public enum IngestError: Error, Sendable {
    case decodeFailed(String)
}
