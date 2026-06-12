# SaveX 项目级 Review - 2026-06-12

审查范围：当前工作区的整个 SaveX 项目，而不是单次提交。已阅读 README、架构文档、App 入口、`DownloadCenter`、Twitter 解析/抽取/选择、MP4/HLS 下载内核、Photos/Library 存储、主要 SwiftUI 页面、Xcode 工程配置和现有 smoke 脚本。

## 本轮修复状态

- Finding 1：已收敛 pause/complete 竞态。暂停请求不再立即取消外层 task；若后台任务确认暂停才落 `.paused`，若 completion 先返回则继续走完成入库路径。
- Finding 2：已调整前台完成事务顺序。Library manifest 写入成功后才把 job 置为 `.completed` 并清理 job store；写入失败时保留 job 为可恢复状态。
- Finding 3：已处理 missing/deleted job 的 detached completion。现在会尝试恢复入库；恢复失败时尝试清理落盘文件，并且最终 ack completion，避免反复重放。
- Finding 4：已修复 mixed media `/video/N` 索引。parser 保留 `video/photo` kind，extractor 按原始 media 数组位置匹配，并对 `/photo/N` 返回明确 `mediaNotVideo`。
- Finding 5：已拒绝暂不支持的关键 HLS tag，包括 `EXT-X-MAP`、`EXT-X-BYTERANGE`、`EXT-X-DISCONTINUITY`，避免静默产出损坏文件。
- Finding 6：已新增 `SaveXTests` XCTest target 和共享 scheme，覆盖 mixed media selection、explicit photo selection、unsupported HLS tags。
- Finding 7：已先收敛重复的下载文件命名/扩展名/去重逻辑到 `DownloadFileNaming`；更大粒度的 store/coordinator/parser 拆文件仍建议作为后续架构清理继续推进。

## Findings

### 1. P1 / Bug - MP4 接近完成时点击 Pause 可能把已完成文件变成孤儿文件

- 文件和行号：
  - `SaveX/App/DownloadCenter.swift:338`
  - `SaveX/App/DownloadCenter.swift:351`
  - `SaveX/App/DownloadCenter.swift:516`
  - `SaveX/Core/Download/SaveXDownloadKernel.swift:1318`
  - `SaveX/Core/Download/SaveXDownloadKernel.swift:1434`
- 问题描述：
  `pauseJob` 先把 job 标记为 `.paused`，再取消外层 `Task`，随后异步请求 `BackgroundHTTPDownloadCoordinator.pause`。如果 background `URLSessionDownloadTask` 在这个窗口内已经完成，coordinator 会在 `didFinishDownloadingTo` 中把临时文件移动到最终目录，并在 `didCompleteWithError` 中把 `DownloadedAsset` 返回给 continuation；但 `runDownload` 紧接着执行 `Task.checkCancellation()`，因为外层 task 已被取消，会进入 catch，并被 `isPauseError` 当成暂停处理。结果是成功下载的文件不会执行 `recordLibraryItem` 和 Photos save，job 仍停在 paused。
- 影响说明：
  用户看到任务已暂停，但磁盘上已经有一个完成的 MP4；继续任务会重新下载或生成重复文件，Library 也看不到已有文件。这是典型生命周期竞态，会让后台下载、暂停/继续和本地库状态互相背离。
- 建议修复方式：
  让 pause/delete/complete 由同一个状态机仲裁，不要在确认底层 pause 成功前直接取消外层下载 task。coordinator 应返回明确结果，例如 `.paused(resumeData)` 或 `.completed(asset)`；如果 completion 先赢，应按完成路径入库。`runDownload` 在处理返回 asset 前也应检查当前 job 是否仍允许完成，而不是只检查 Swift task cancellation。补一个 coordinator/DownloadCenter 级测试：模拟 pause 请求与 background completion 同时发生，验证完成优先时不会留下 paused orphan。

### 2. P2 / Bug - 前台下载完成时即使 Library manifest 写入失败，也会移除 job

- 文件和行号：
  - `SaveX/App/DownloadCenter.swift:521`
  - `SaveX/App/DownloadCenter.swift:539`
  - `SaveX/App/DownloadCenter.swift:647`
  - `SaveX/App/DownloadCenter.swift:732`
  - `SaveX/App/DownloadCenter.swift:752`
- 问题描述：
  前台 `runDownload` 先把 job 更新为 `.completed`，这会让 `persistJob` 从 job store 删除该 job；随后调用 `_ = recordLibraryItem(...)`，但忽略返回值。如果 `library.json` 写入失败，内存里临时有 item，持久化 manifest 里没有，job record 又已经被删除。
- 影响说明：
  App 重启后用户既看不到 Jobs 中的可恢复任务，也看不到 Library 记录，只剩 Documents 目录里的孤儿视频文件。磁盘满、Application/Documents 目录异常或 JSON 写入失败时，这会直接造成状态丢失。
- 建议修复方式：
  把“文件落盘 -> Library manifest 持久化 -> job terminal cleanup”做成有序事务。只有 `recordLibraryItem` 成功后才删除 job record；失败时保留 job 为 `.ready` 或 `.failed` 且带可恢复错误，让用户可以重试入库。补一个 fake `FileManager`/store 测试，强制 manifest write 失败，验证 job 不会被移除。

### 3. P2 / Bug - deleted/missing job 的 detached completion 永远不会 ack

- 文件和行号：
  - `SaveX/App/DownloadCenter.swift:265`
  - `SaveX/App/DownloadCenter.swift:266`
  - `SaveX/Core/Download/SaveXDownloadKernel.swift:1074`
  - `SaveX/Core/Download/SaveXDownloadKernel.swift:1081`
  - `SaveX/Core/Download/SaveXDownloadKernel.swift:1810`
- 问题描述：
  `pendingDetachedCompletions()` 现在是 peek 语义，只有 `acknowledgeDetachedCompletion` 才会删除持久化 completion。但 `handleDetachedBackgroundCompletion` 在找不到 job 时直接 `return`，不会 ack，也不会清理已移动到 Downloads 的文件。
- 影响说明：
  如果用户删除任务时 background download 正好完成，或 job store 与 completion store 已经不一致，这条 completion 会在每次启动时反复重放但永远无法处理；同时最终文件可能成为孤儿文件。这个问题会让后台下载恢复状态长期污染，并让后续排查“为什么一直有 pending completion”变困难。
- 建议修复方式：
  为 missing/deleted job 定义显式策略：如果用户已删除任务，应 ack completion 并删除对应文件；如果只是 job store 缺失，应转成 Library pending 或恢复 job。无论哪种策略，都不能静默 return。补测试覆盖：持久化 detached completion 但 job 不存在时，completion store 会被收敛，文件处理结果可预测。

### 4. P2 / Bug - 混合媒体 tweet 的 `/video/N` 索引会在过滤 photo 后失真

- 文件和行号：
  - `SaveX/Core/Twitter/SaveXTwitterKernel.swift:72`
  - `SaveX/Core/Twitter/SaveXTwitterKernel.swift:90`
  - `SaveX/Core/Extraction/SaveXExtractionKernel.swift:31`
  - `SaveX/Core/Extraction/SaveXExtractionKernel.swift:184`
  - `SaveX/Core/Extraction/SaveXExtractionKernel.swift:190`
- 问题描述：
  URL parser 接受 `/video/<index>` 和 `/photo/<index>`，并把 index 存为 `selectedMediaIndex`。但 extractor 先从 `extended_entities.media` 里过滤掉 `type == "photo"`，再用 `selectedMediaIndex` 去索引过滤后的 video entries。对于 X/Twitter 支持的图文混排 tweet，URL 中的媒体位置是原始 media 数组位置，不是“过滤后的第 N 个视频”。
- 影响说明：
  如果 tweet 的第 1 个媒体是图片、第 2 个媒体是视频，用户粘贴 `/video/2` 很可能会得到 `videoUnavailable(index: 2)`；如果存在多个视频/图片混排，也可能下载错误的视频。用户已经给出明确媒体 URL 时，当前逻辑反而降低了正确性。
- 建议修复方式：
  在过滤前保留原始 media index 和 type。`/video/N` 应匹配原始 media 数组第 N 项并确认它是 video/animated_gif；如果是 photo，返回 `mediaNotVideo`。补混合媒体 fixture：photo + video 的 `/video/2` 必须下载该视频，`/photo/1` 必须给出清晰错误。

### 5. P2 / Bug - HLS parser 静默忽略关键 playlist tag，可能产出损坏 MP4

- 文件和行号：
  - `SaveX/Core/Download/SaveXDownloadKernel.swift:172`
  - `SaveX/Core/Download/SaveXDownloadKernel.swift:179`
  - `SaveX/Core/Download/SaveXDownloadKernel.swift:207`
  - `SaveX/Core/Download/SaveXDownloadKernel.swift:725`
  - `SaveX/Core/Download/SaveXDownloadKernel.swift:738`
- 问题描述：
  media playlist parser 只显式处理 `EXT-X-KEY`、`EXT-X-TARGETDURATION`、`EXTINF` 和 `EXT-X-ENDLIST`，其他 `#EXT-...` tag 会被跳过。下载器随后按 segment URL 下载完整文件并顺序拼接。对于包含 `#EXT-X-MAP` 的 fMP4 HLS、`#EXT-X-BYTERANGE` 的 byte-range playlist、或需要处理 discontinuity/init segment 的 VOD，当前实现不会拒绝，而是静默按错误方式下载/拼接。
- 影响说明：
  这类 playlist 会得到损坏输出，甚至在 byte-range 场景重复下载同一个大资源的完整内容，造成异常 IO/网络开销。更糟的是用户可能看到“下载/导出失败”或“完成但视频坏了”，日志无法直接指出真实原因。
- 建议修复方式：
  在真正支持前，parser 应检测并拒绝 unsupported tag，例如 `EXT-X-MAP`、`EXT-X-BYTERANGE`、不受支持的 `EXT-X-DISCONTINUITY` 语义等，返回明确 `unsupportedHLS`。如果要支持 byte-range/fMP4，则模型需要保存 init map、range、sequence/discontinuity 信息，downloader 按 range 请求并正确组装。补 manifest smoke：包含 `EXT-X-MAP` 和 `EXT-X-BYTERANGE` 时必须失败或按正确字节下载。

### 6. P2 / Test - 项目没有 XCTest target，关键生命周期只能靠手动 smoke 覆盖

- 文件和行号：
  - `SaveX.xcodeproj/project.pbxproj:368`
  - `SaveX.xcodeproj/project.pbxproj:369`
  - `SaveX.xcodeproj/project.pbxproj:386`
  - `scripts/hls_download_smoke.swift:54`
  - `scripts/library_store_smoke.swift:18`
- 问题描述：
  Xcode 工程只有 `SaveX` app target，没有 test target。现有 `scripts/*.swift` 能覆盖部分 parser/HLS/library happy path，但没有进入 `xcodebuild test`，也没有覆盖 background URLSession 的恢复、pause/complete 竞态、detached completion 幂等、library persist 失败等最危险路径。
- 影响说明：
  当前代码最复杂、最容易回归的地方正是异步生命周期和持久化状态机；这些问题很难靠手测稳定发现。后续继续加暂停、恢复、后台策略时，缺少自动化测试会显著提高回归概率。
- 建议修复方式：
  新增 `SaveXTests` target，把现有 smoke 中可离线的 parser、selector、HLS manifest/download、library store 测试迁入 XCTest，并为 coordinator/DownloadCenter 提供可注入 fake downloader/store/photo writer。至少补齐：pause 与 completion 竞态、detached completion 重放/ack、manifest 写入失败、mixed media index、unsupported HLS tag。

### 7. P3 / Maintainability - 下载和状态管理被压在两个大文件里，重复逻辑已经开始分叉

- 文件和行号：
  - `SaveX/App/DownloadCenter.swift:82`
  - `SaveX/App/DownloadCenter.swift:131`
  - `SaveX/Core/Download/SaveXDownloadKernel.swift:644`
  - `SaveX/Core/Download/SaveXDownloadKernel.swift:876`
  - `SaveX/Core/Download/SaveXDownloadKernel.swift:1911`
  - `SaveX/Core/Download/SaveXDownloadKernel.swift:2154`
  - `SaveX/Core/Download/SaveXDownloadKernel.swift:855`
  - `SaveX/Core/Download/SaveXDownloadKernel.swift:1871`
  - `SaveX/Core/Download/SaveXDownloadKernel.swift:2060`
- 问题描述：
  `DownloadCenter.swift` 同时承担 job store、library store、background completion 消费、Photos 保存、日志、UI 状态折算和任务编排。`SaveXDownloadKernel.swift` 同时放了 HLS parser、HLS resume store、HLS downloader、background URLSession coordinator、HTTP downloader 和 DownloadEngine。文件命名、去重、扩展名选择等逻辑已经在 HLS/background/foreground HTTP 三处重复。
- 影响说明：
  这不是单纯“文件长不好看”。状态和 IO 边界混在一起，会让修复一个生命周期 bug 时很难判断哪一层拥有最终状态；重复的 filename/extension/destination 逻辑会导致将来接入 Settings 的“Keep source filenames”、统一下载目录策略或安全文件名规则时必须改多处，漏一处就会出现前台/后台/HLS 行为不一致。
- 建议修复方式：
  先按现有架构文档收敛边界，不需要一次性大重构：提取 `JobStore`/`LibraryStore` 到 Data 层，提取 `AssetFileNamer`/`DestinationFileStore` 供 HTTP/HLS/background 共用，拆出 `BackgroundHTTPDownloadCoordinator`、`HLSMediaDownloader`、`HLSManifestParser` 独立文件。后续 DownloadCenter 只保留用例编排和 UI 状态映射。

## 验证情况

- `xcodebuild -project SaveX.xcodeproj -scheme SaveX -destination 'generic/platform=iOS Simulator' build CODE_SIGNING_ALLOWED=NO`：通过。
- `swiftc ... scripts/kernel_fixture_smoke.swift`：通过。
- `swiftc ... scripts/hls_manifest_smoke.swift`：通过。
- `swiftc ... scripts/hls_download_smoke.swift`：通过。
- `swiftc ... scripts/library_store_smoke.swift`：通过。

残余风险：没有在真机上验证 background URLSession 被系统唤醒、App 被 kill 后 completion handler、Photos 权限弹窗与保存行为；这些路径也是本次 review 中风险最高的区域。

## 简短结论

- 整体风险等级：High。
- 是否建议合并：不建议把当前状态作为稳定主分支质量基线继续合并/发布。
- 合并前必须处理的问题：至少处理 Finding 1、2、3；它们会直接造成下载完成状态与 Library/Jobs 持久化不一致。
- 建议补充的测试：pause/complete 竞态、detached completion missing job、library manifest 写入失败、mixed media URL index、unsupported HLS tags，以及把现有 smoke 迁入可自动运行的 XCTest/CI。
