import Foundation

/// Errors from the local-file import pipeline. (The YouTube/Spotify resolve → download
/// contracts lived here on the personal prototype; this App Store cut imports audio from
/// Files only.)
public enum IngestError: Error, Sendable {
    case invalidURL
    case decodeFailed(String)
}
