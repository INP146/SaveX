<div align="center">

<img src="docs/design/composed/savex-iOS-Default-512x512@1x.png" alt="SaveX app icon" width="120" />

<h1 align="center">SaveX - Twitter Video Downloader</h1>

<p><b>English</b> | <a href="README.zh-CN.md">简体中文</a></p>

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

For a deeper walkthrough, see [yt-dlp Twitter/X download chain](docs/agent/yt-dlp-twitter-download-chain.md).

## Current Features

- Parses `x.com` and `twitter.com` Tweet URLs
- Fetches Tweet data through Twitter/X GraphQL, legacy API, and syndication fallback paths
- Supports optional Twitter/X Cookie header storage in Keychain for content available to that session
- Extracts video format candidates from Tweet media variants and card data
- Supports choosing one video or queueing all videos from multi-video Tweets, with an option to download all Tweet videos by default
- Supports direct MP4 downloads and basic HLS VOD downloads
- Supports resumable/background MP4 downloads, pause/resume, retry, and launch recovery for persisted jobs
- Includes Jobs, Logs, Library, and Settings views
- Supports appearance customization, including interface style, preset themes, and custom theme colors
- Provides a local Library with playback, detail views, sharing, deletion, generated covers, and multiple layouts
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

- Public Twitter/X video content and content accessible to the configured Twitter/X Cookie session are supported
- Twitter/X APIs, fields, and rate limits may change; some links may need fallback paths or may temporarily fail
- HLS support is currently aimed at VOD playlists, not live playlists
- Encrypted HLS segments are not supported
- Low-latency HLS tags are not supported
- Release IPAs are unsigned and must be sideloaded or re-signed manually

## License

MIT. See [LICENSE](LICENSE).
