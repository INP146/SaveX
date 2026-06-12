# SaveX

[🇨🇳简体中文](README.zh-CN.md)

SaveX is an iOS SwiftUI app for downloading videos from public Twitter/X posts to local storage and attempting to save them to the system Photos library.

## Upstream Reference

SaveX's Twitter/X parsing, format extraction, and format sorting logic are informed by the [yt-dlp](https://github.com/yt-dlp/yt-dlp) project. The current implementation does not run `yt-dlp` directly on iOS; instead, it reimplements the relevant download chain as a native Swift iOS download kernel.

For a deeper walkthrough, see [yt-dlp Twitter/X download chain](docs/yt-dlp-twitter-download-chain.md).

## Current Features

- Parses `x.com` and `twitter.com` Tweet URLs
- Fetches Tweet data through Twitter/X GraphQL, legacy API, and syndication fallback paths
- Extracts video format candidates from Tweet media variants and card data
- Supports direct MP4 downloads
- Supports basic HLS VOD downloads
- Includes Jobs, Logs, Library, and Settings views
- Attempts to save completed downloads to Photos
- Keeps local library records, so downloaded files remain visible in the app even if saving to Photos fails

## Download Routes

The `Auto / MP4 File / HLS Stream` control on the home screen selects the download route, not the final output format.

- `Auto`: automatically selects the best compatible format, using a strategy close to yt-dlp's Twitter/X behavior
- `MP4 File`: prefers a single direct MP4 file exposed by Twitter/X
- `HLS Stream`: prefers the HLS playlist route

If the requested route is not available, SaveX falls back to the best available format and records that fallback in the logs.

## Output Notes

- Direct MP4 downloads are saved as `.mp4`
- HLS VOD downloads are assembled segment by segment, then exported to `.mp4` with AVFoundation
- If an HLS stream cannot be exported to MP4 by the native iOS media stack, the download fails instead of keeping a `.ts` fallback file

## Known Limitations

- Only public, accessible Twitter/X video content is supported
- Twitter/X APIs, fields, and rate limits may change; some links may need fallback paths or may temporarily fail
- HLS support is currently aimed at VOD playlists, not live playlists
- Encrypted HLS segments are not supported
- Low-latency HLS tags are not supported
- Some Settings controls are still UI placeholders and are not fully wired into the download kernel
- The `v0.0.1` release IPA is unsigned and must be sideloaded or re-signed manually

## License

MIT. See [LICENSE](LICENSE).
