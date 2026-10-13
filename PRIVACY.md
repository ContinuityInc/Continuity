# Privacy Policy — Continuity

**Last updated:** 13 October 2026

Continuity is a personal music player made by ContinuityInc. It does not have accounts, analytics, advertising, or any Continuity-operated server that stores your library.

## What stays on your device

- Audio you import from the Files app, and audio Continuity caches after you choose to add a track or playlist
- Artwork extracted from those files or fetched as public thumbnails for catalog results
- Playback position, skip history, and transition settings
- On-device analysis (tempo, key, loudness) and stem-separated audio used for blends

None of that is uploaded to Continuity. Continuity does not have user accounts, so it never asks for a name, email, or password.

## Network use

Continuity makes outbound HTTPS requests only to provide the features you invoke:

- **YouTube** — resolve playlists/search results and download the audio stream for tracks you add (via InnerTube / stream URLs)
- **Spotify** — read public/embed playlist metadata (track titles and artists only; Spotify audio is DRM-locked and is not downloaded)
- **Apple Music** — if you grant Media Library access, Continuity reads playlist titles/artists on-device so you can re-source those songs; it does not upload your library
- **iTunes Search API** — catalog song/album search (no API key)
- **Artwork CDNs** — public cover art / YouTube thumbnails (`i.ytimg.com`, Apple `mzstatic` artwork URLs from search results)
- **Hugging Face** — one-time download of the on-device stem-separation model (~158 MB, MIT-licensed HT-Demucs weights) the first time vocal-aware blends need it. The download is integrity-checked (SHA-256); it is a model file, not your music

Continuity does not send your library, listening history, or personal identifiers to ContinuityInc.

## Data we do not collect

Continuity does not collect names, emails, advertising identifiers, location, contacts, or usage analytics for ContinuityInc. There is no Continuity tracking SDK. Third-party hosts above see only the requests needed for the feature you used (standard HTTPS connection metadata).

## Contact

Questions and support: [github.com/ContinuityInc/Continuity/issues](https://github.com/ContinuityInc/Continuity/issues)
