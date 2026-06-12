<div align="center">

<img src="docs/design/savex-iOS-Default-1024x1024@1x.png" alt="SaveX app icon" width="140" />

<h1 align="center">SaveX - Twitter Video Downloader</h1>

<p><a href="README.md">🇺🇸 English</a></p>

<p>SaveX 是一个 iOS SwiftUI 应用，用来把公开 Twitter/X 帖子里的视频下载到本地，并尝试保存到系统相册。</p>

<p>
  <img src="https://img.shields.io/badge/iOS-26.0%2B-000000?logo=apple&logoColor=white" alt="iOS 26.0+" />
  <img src="https://img.shields.io/badge/Swift-5.0%2B-F05138?logo=swift&logoColor=white" alt="Swift 5.0+" />
  <img src="https://img.shields.io/badge/SwiftUI-native-0D96F6?logo=swift&logoColor=white" alt="SwiftUI native" />
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-green.svg" alt="License: MIT" /></a>
</p>

<p>
  <a href="altstore://source?url=https%3A%2F%2FINP146.github.io%2FAltSource%2Fsource.json&app=com.savex"><img src="docs/badges/DownloadBadge_dark.png" alt="Download on AltStore" height="45" /></a>
  <a href="sidestore://source?url=https%3A%2F%2FINP146.github.io%2FAltSource%2Fsource.json"><img src="docs/badges/add-source-to-sidestore.png" alt="Add Source to SideStore" height="45" /></a>
</p>

</div>

## 上游参考

SaveX 的 Twitter/X 解析、格式提取和格式排序思路参考了 [yt-dlp](https://github.com/yt-dlp/yt-dlp) 项目。当前实现不是直接在 iOS 内运行 `yt-dlp`，而是基于相关下载链路，用 Swift 实现本地 iOS 下载内核。

更详细的链路分析见 [yt-dlp Twitter/X download chain](docs/yt-dlp-twitter-download-chain.md)。

## 当前能力

- 解析 `x.com` / `twitter.com` Tweet URL
- 通过 Twitter/X GraphQL、legacy API 和 syndication fallback 获取 Tweet 数据
- 从 Tweet media variants 和 card 数据中提取视频候选格式
- 支持直链 MP4 下载
- 支持基础 HLS VOD 下载
- 支持任务列表、下载日志、本地媒体库和设置页面
- 下载完成后尝试写入 Photos
- 保留本地媒体库记录，Photos 保存失败时也能在应用内查看已下载文件

## 下载路线

首页的 `Auto / MP4 File / HLS Stream` 是下载路线选择，不是最终输出格式选择。

- `Auto`: 自动选择最合适的可下载格式，排序策略接近 yt-dlp 对 Twitter/X 的处理
- `MP4 File`: 优先选择 Twitter/X 暴露的单文件 MP4 直链
- `HLS Stream`: 优先选择 HLS playlist 路线

如果用户选择的路线不可用，SaveX 会回退到当前可用的最佳格式，并把 fallback 写入日志。

## 输出说明

- MP4 直链会保存为 `.mp4`
- HLS VOD 会下载并按顺序拼接 segment，然后通过 AVFoundation 导出为 `.mp4`
- 如果某条 HLS 流无法被 iOS 原生媒体栈导出为 MP4，任务会失败，不保留 `.ts` 兜底文件

## 已知限制

- 只支持公开、可访问的 Twitter/X 视频内容
- Twitter/X API、字段和限流策略可能变化，部分链接可能需要 fallback，或暂时不可用
- 当前 HLS 支持面向 VOD，不支持 live playlist
- 不支持加密 HLS segment
- 不支持 low-latency HLS 标签
- Settings 页面里的部分策略项仍是 UI 占位，尚未全部接入下载内核
- `v0.0.1` release IPA 是未签名构建，需自行侧载

## License

MIT. See [LICENSE](LICENSE).
