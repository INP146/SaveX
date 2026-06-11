# SaveX iOS App 架构设计

这版方案基于一个前提：

- 不走服务端解析和下载
- 不直接嵌入 Python 跑 `yt-dlp`
- 要在 iOS 本地用 Swift 重写 `yt-dlp` 里和 Twitter/X 下载相关的主链路

也就是说，目标不是“包一层 UI 调 `yt-dlp`”，而是把这条链路原生化：

```text
Tweet URL
  -> Twitter extractor
  -> info model / formats
  -> format selector
  -> downloader planner
  -> MP4 / HLS downloader
  -> local file assembly
  -> library
```

## 1. 先定边界

本地重写可行，但要接受 iOS 的真实约束：

- 不能依赖外部进程模型去跑 `ffmpeg` / Python CLI
- 不能假设 app 被挂后台后还能长期自由跑自定义分片下载
- `background URLSession` 适合单文件下载，不适合复杂的自定义 HLS 片段编排
- 如果目标是 App Store 分发，动态解释器、下载后执行代码都不该作为方案基础

所以这个项目要按下面原则设计：

- `extractor`、`format selector`、`downloader` 全部 Swift 原生实现
- 优先支持 `HTTP MP4` 和可原生处理的 `HLS`
- 不把复杂转码、合并、后处理作为第一阶段前提
- 后台能力按 iOS 能力设计成“尽量继续”，不是桌面端那种“永远稳定常驻”

## 2. 总体架构

推荐采用两层视角：

### 产品层

```text
SwiftUI App
  -> App Layer
  -> Download Core
  -> Local Persistence
  -> File Library
```

### 下载内核层

```text
URL Input
  -> URL Canonicalizer
  -> Twitter API Client
  -> Tweet Resolver
  -> Media Extractor
  -> Format Normalizer
  -> Format Selector
  -> Download Planner
  -> Downloader
       -> HTTP File Downloader
       -> HLS Manifest Downloader
       -> Segment Downloader
       -> File Assembler
  -> Local Asset Store
```

这套结构基本对应 `yt-dlp` 的三层抽象：

- `extractor`
- `YoutubeDL` 风格的格式整理和选择
- `downloader`

## 3. 客户端分层

不要上来就做很重的 Clean Architecture，但也不要把下载引擎直接塞进 ViewModel。推荐四层：

### Presentation

负责：

- SwiftUI 页面
- 用户输入 URL
- 任务列表、进度、失败态、文件库展示

### Application

负责：

- 编排用例
- 组织下载流程
- 在 UI 和下载内核之间做边界层

### Core

负责：

- Twitter 解析
- format 抽取和选择
- HTTP/HLS 下载
- 文件落盘

这是这个 app 的核心竞争力。

### Infrastructure

负责：

- `URLSession`
- `SwiftData` 或 SQLite
- 文件系统
- Keychain
- App 生命周期
- 日志与诊断

## 4. 推荐目录结构

```text
SaveX/
  App/
    SaveXApp.swift
    AppContainer.swift
    AppRouter.swift

  Features/
    Home/
    Jobs/
    Library/
    Settings/

  Core/
    Twitter/
      TwitterAPIClient.swift
      TwitterAuthProvider.swift
      GuestTokenStore.swift
      TwitterURLParser.swift
      TweetResolver.swift
      GraphQLTweetMapper.swift
      LegacyTweetMapper.swift
    Extraction/
      TwitterMediaExtractor.swift
      CardMediaExtractor.swift
      VMapParser.swift
      FormatNormalizer.swift
    Selection/
      FormatSelector.swift
      FormatSortPolicy.swift
    Download/
      DownloadPlanner.swift
      DownloadEngine.swift
      HTTPFileDownloader.swift
      HLSManifestLoader.swift
      HLSSegmentDownloader.swift
      SegmentStore.swift
      FileAssembler.swift
    Models/
      TweetMediaInfo.swift
      MediaFormat.swift
      DownloadJob.swift
      DownloadTaskPlan.swift
      LocalAsset.swift
    Support/
      SaveXError.swift
      RetryPolicy.swift
      CancellationBag.swift

  Data/
    Repositories/
      DownloadRepository.swift
      LibraryRepository.swift
    Persistence/
      JobStore.swift
      AssetStore.swift

  Infrastructure/
    Networking/
      APIRequest.swift
      HTTPClient.swift
    Storage/
      FileStore.swift
    System/
      AppLifecycleObserver.swift
      BackgroundTaskCoordinator.swift
    Logging/
      AppLogger.swift
```

## 5. 核心模型

### 5.1 TweetMediaInfo

相当于简化版 `info_dict`，建议至少包含：

- `tweetId`
- `displayURL`
- `title`
- `authorName`
- `authorHandle`
- `thumbnailURL`
- `duration`
- `formats`
- `subtitles`
- `sourceHeaders`

### 5.2 MediaFormat

这是最关键的数据模型，建议字段：

- `id`
- `url`
- `container`
- `protocol`
- `width`
- `height`
- `bitrate`
- `fileSizeApprox`
- `videoCodec`
- `audioCodec`
- `isHLS`
- `httpHeaders`
- `qualityRank`

### 5.3 DownloadJob

建议区分“解析状态”和“下载状态”：

- `id`
- `sourceURL`
- `phase`
- `progress`
- `selectedFormatID`
- `outputFilename`
- `errorCode`
- `errorMessage`
- `createdAt`
- `updatedAt`

## 6. 下载状态机

本地重写时，状态机必须比服务端方案更细，因为所有中间过程都发生在设备上。

```text
idle
validating_url
fetching_guest_token
fetching_tweet
normalizing_tweet
extracting_media
selecting_format
preparing_download
downloading_file
downloading_manifest
downloading_segments
assembling_file
finalizing_asset
completed
failed
canceled
```

建议把错误也规范化：

- `invalidURL`
- `guestTokenFailed`
- `tweetFetchFailed`
- `tweetUnavailable`
- `unsupportedCard`
- `noPlayableFormat`
- `manifestParseFailed`
- `segmentDownloadFailed`
- `fileAssembleFailed`
- `localWriteFailed`
- `backgroundExpired`

## 7. 本地版 `yt-dlp` 主链路怎么拆

### 7.1 URL Canonicalizer

职责：

- 识别 `x.com` / `twitter.com`
- 解析 `status/<id>`
- 识别 `/video/<n>` 这类媒体索引
- 归一化为内部 `TweetRequest`

输出建议：

- `tweetId`
- `screenName`
- `selectedMediaIndex`
- `originalURL`

### 7.2 TwitterAPIClient

职责：

- 维护请求头
- 管理 `guest_token`
- 发 GraphQL / legacy 请求
- 统一错误码

这里要把文档里那条链路原生化：

```text
POST guest/activate.json
  -> 拿 guest token
GET/POST TweetResultByRestId
  -> 拿 tweet payload
```

需要的组件：

- `GuestTokenStore`
- `BearerTokenProvider`
- `TwitterAuthProvider`

注意：

- Bearer token、GraphQL endpoint、features 都要配置化
- 不要把这些常量散落在 ViewModel 里

### 7.3 TweetResolver

职责：

- 从 GraphQL/legacy 响应中找到 tweet 主体
- 处理 retweet / quoted tweet / tombstone / unavailable
- 统一映射到内部 tweet model

对应 `yt-dlp` 里的职责，大致就是：

- `_extract_status`
- `_graphql_to_legacy`

### 7.4 MediaExtractor

职责：

- 从 `extended_entities.media[].video_info.variants` 提取视频
- 从 `card` 分支提取 player/unified_card/VMAP 资源
- 产出统一 `MediaFormat[]`

建议拆成：

- `TwitterMediaExtractor`
- `CardMediaExtractor`
- `VMapParser`

这层只负责“找资源”，不负责“下资源”。

### 7.5 FormatNormalizer

职责：

- 补协议字段
- 规范分辨率、码率、容器
- 合并重复 format
- 为每个 format 计算排序键

这里相当于本地实现一个轻量版 `process_video_result(...)`。

### 7.6 FormatSelector

职责：

- 根据规则从 `formats` 中选出最终下载目标
- 支持“优先清晰度”或“优先兼容性”

第一版建议策略：

- 默认优先 MP4 直链
- 如果只有 HLS，再走 HLS
- 同清晰度下优先更稳定的直链

原因：

- 本地版 HLS 下载在 iOS 上的复杂度和后台不确定性更高
- 桌面端 `yt-dlp` 偏好 HLS，不代表 iOS 本地实现也该完全照搬

## 8. Downloader 设计

这是本地方案最重要的一层。

## 8.1 DownloadPlanner

负责根据 `MediaFormat` 生成执行计划：

### HTTP 直链

```text
MediaFormat(http/mp4)
  -> SingleFilePlan
  -> HTTPFileDownloader
```

### HLS

```text
MediaFormat(m3u8)
  -> ManifestPlan
  -> HLSManifestLoader
  -> Segment list
  -> HLSSegmentDownloader
  -> FileAssembler
```

### 为什么要有 Planner

因为“格式选择”和“下载执行”要解耦：

- 选择层只决定“下哪个格式”
- Planner 决定“这个格式应该怎么下”

## 8.2 HTTPFileDownloader

职责：

- 用 `URLSessionDownloadTask` 下载单文件
- 支持断点恢复
- 支持后台 session
- 支持进度上报

这是最稳定的一条下载路径，应优先打磨。

## 8.3 HLSManifestLoader

职责：

- 拉取 m3u8
- 解析 master playlist / media playlist
- 处理相对路径
- 产出 segment 清单

建议支持：

- `#EXTM3U`
- `#EXT-X-STREAM-INF`
- `#EXTINF`
- `#EXT-X-MAP`
- `#EXT-X-KEY`

第一版可以明确不支持：

- DRM
- live HLS
- 复杂低延迟 HLS

## 8.4 HLSSegmentDownloader

职责：

- 并发下载 ts/fmp4 分片
- 失败重试
- 校验分片顺序
- 落到 `SegmentStore`

注意：

- 这层如果跑在前台，体验可控
- 这层如果 app 进入后台，系统未必给足够时间跑完整个任务

所以产品策略上要明确：

- `MP4` 可以主打后台下载
- `HLS` 更适合前台下载或短时后台继续

## 8.5 FileAssembler

职责：

- 按 manifest 顺序拼接分片
- 处理 init segment
- 生成最终媒体文件

第一阶段只做“无转码拼接”：

- `.ts` 按序拼接
- `fMP4` 按容器规则拼接可行时再支持

不要一开始就承诺本地做复杂转码。

## 9. iOS 后台策略

这部分必须单独设计，否则本地方案会在体验上失真。

### MP4 任务

用：

- `URLSessionConfiguration.background`

效果：

- app 挂后台或被系统挂起后，系统仍可继续单文件下载
- 适合 HTTP MP4

### HLS 任务

不要假设自定义 segment 下载器拥有和 background session 同等能力。

建议策略：

- 前台下载优先
- 进入后台时尝试申请有限后台执行时间
- 未完成则挂起为 `pausedBySystem`
- 回到前台自动续传

这不是代码问题，是平台模型决定的。

## 10. 本地持久化

建议拆成两类数据：

### JobStore

存：

- 下载任务
- 当前 phase
- 进度
- 选中的 format
- 失败原因
- 断点信息

### AssetStore

存：

- 本地文件索引
- 文件路径
- 缩略图路径
- 时长
- 文件大小

文件本体建议放：

- `Application Support/Downloads/`

不要依赖 `Documents/` 暴露原始实现细节。

## 11. UI 信息架构

推荐先做 4 个页面：

- `Home`：粘贴 URL，解析，发起下载
- `Jobs`：查看解析中、下载中、失败、暂停任务
- `Library`：查看本地文件、播放、分享、删除
- `Settings`：下载偏好、日志开关、调试信息

重点不是页面数量，而是分清三件事：

- 输入 URL
- 运行任务
- 管理结果

## 12. 依赖注入

建议用一个轻量 `AppContainer` 组装依赖：

```text
HomeViewModel
  -> CreateDownloadJobUseCase
      -> DownloadRepository
          -> DownloadEngine
              -> TweetResolver
              -> MediaExtractor
              -> FormatSelector
              -> DownloadPlanner
```

不要让 ViewModel 直接碰：

- GraphQL endpoint
- guest token
- m3u8 parser
- 文件拼接逻辑

## 13. 测试策略

这个项目测试重点不在 UI，而在下载内核。

### 必测单元

- URL 解析
- tweet JSON 映射
- format 提取
- format 排序
- m3u8 解析
- segment 拼装顺序
- 错误分类

### 必测集成

- 公开 tweet 的 MP4 下载
- 公开 tweet 的 HLS 下载
- 多媒体 tweet 的指定索引
- app 冷启动后任务恢复

建议在仓库里沉淀一批固定夹具：

- GraphQL 响应样本
- legacy 响应样本
- unified card 样本
- VMAP 样本
- m3u8 样本

## 14. 版本演进

### V1

- 公开 tweet
- guest token + GraphQL 获取 tweet
- `extended_entities.video_info.variants`
- MP4 直链下载
- 基础本地文件库

### V1.5

- 基础 HLS manifest 解析
- 前台 segment 下载
- 任务恢复

### V2

- card / VMAP 支持
- 多媒体索引选择
- 更完整的 format selector
- 更完善的失败恢复

### V3

- 登录态媒体
- 引用 tweet / retweet 兼容增强
- 字幕、封面、命名模板

## 15. 当前项目的落地建议

你现在这个仓库还是模板工程，建议按下面顺序做，不要一上来就糊一个巨型 `DownloadManager`：

1. 先搭目录结构和核心 model
2. 先写 `TwitterURLParser`、`TweetResolver`、`MediaFormat`
3. 再写 `FormatSelector`
4. 先打通 `MP4` 单文件下载
5. 再引入 `HLSManifestLoader` 和 `HLSSegmentDownloader`
6. 最后接 UI、任务恢复和文件库

## 16. 一句话定案

这不是一个普通 SwiftUI app，而是一个本地媒体抓取内核 + iOS 外壳。

如果坚持本地重写 `yt-dlp` 逻辑，最合理的架构不是“页面先行”，而是：

```text
先做 extractor / selector / downloader 三段式内核，
再让 SwiftUI 成为这个内核的控制台和文件管理界面。
```
