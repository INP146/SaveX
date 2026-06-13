<div align="center">

<img src="docs/design/savex-iOS-Default-1024x1024@1x.png" alt="SaveX app icon" width="140" />

<h1 align="center">SaveX - Twitter Video Downloader</h1>

<p><a href="README.zh-CN.md">🇨🇳 简体中文</a></p>

<p>SaveX is an iOS SwiftUI app for downloading videos from public Twitter/X posts to local storage and attempting to save them to the system Photos library.</p>

<p>
  <img src="https://img.shields.io/badge/iOS-26.0%2B-000000?logo=apple&logoColor=white" alt="iOS 26.0+" />
  <img src="https://img.shields.io/badge/Swift-5.0%2B-F05138?logo=swift&logoColor=white" alt="Swift 5.0+" />
  <img src="https://img.shields.io/badge/SwiftUI-native-0D96F6?logo=swift&logoColor=white" alt="SwiftUI native" />
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-green.svg" alt="License: MIT" /></a>
</p>

<p>
  <a href="https://INP146.github.io/AltSource/install/altstore/io.github.inp146.savex.html"><img src="docs/badges/DownloadBadge_dark.png" alt="Download on AltStore" height="45" /></a>
  <a href="https://INP146.github.io/AltSource/install/sidestore/io.github.inp146.savex.html"><img src="docs/badges/add-source-to-sidestore.png" alt="Add Source to SideStore" height="45" /></a>
</p>

</div>

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
