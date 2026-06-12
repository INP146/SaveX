# SaveX 项目级代码 Review - 2026-06-12

审查范围：当前工作区整个 SaveX 项目，而不是单次 commit diff。已阅读 README、架构文档、App 入口、`DownloadCenter`、Twitter URL/API/抽取/选择链路、HTTP/HLS 下载内核、后台恢复逻辑、Photos/Library 存储、SwiftUI 页面、Xcode 工程配置、XCTest 和 smoke 脚本。

## 本轮修复状态

- Finding 1：已修复。恢复后的 background task 现在有 failure callback；no-active failure 会保存 resumeData、清理 metadata，并清掉 pause marker，`DownloadCenter` 会把仍在等待系统任务的 job 标为 failed。
- Finding 2：已修复。`.ready` 作为 durable 状态保留，重启恢复时不会再被改写成 `.waitingForSystem`。
- Finding 3：已修复。删除 job 会删除未被 Library 引用的本地文件；`DownloadEngine.cancelAndClean(jobID:)` 统一清理 HTTP background/resume 和 HLS resume artifact；下载完成后发现 job 已被删除时会丢弃刚落盘的 asset。
- Finding 4：已补测试。新增 XCTest 覆盖 `.ready` 恢复、删除 ready job 清理本地文件、统一清理 HLS resume artifact。
- Finding 5：已修复下载内核大文件问题。`SaveXDownloadKernel.swift` 从 2414 行降到 207 行，只保留 `DownloadEngine` 编排；共享下载类型、HLS manifest/parser、HLS downloader/export/resume、HTTP resume、background HTTP coordinator、foreground HTTP downloader 已拆到独立文件。`DownloadCenter` 的 Data 层拆分仍可作为后续增强，但本次指出的下载内核“大文件混职责”问题已落地处理。

### 下载内核拆分结果

- `SaveX/Core/Download/DownloadCoreTypes.swift`：下载计划、下载结果和文件命名。
- `SaveX/Core/Download/SaveXDownloadKernel.swift`：`DownloadEngine` 编排。
- `SaveX/Core/Download/HLSManifest.swift`：HLS manifest 模型、parser、loader。
- `SaveX/Core/Download/HLSMediaDownloader.swift`：HLS segment 下载和导出流程。
- `SaveX/Core/Download/HLSMediaExport.swift`：AVFoundation MP4 export adapter。
- `SaveX/Core/Download/HLSResumeStore.swift`：HLS resume state 和 working directory 管理。
- `SaveX/Core/Download/HTTPResumeStore.swift`：HTTP resume data/partial state 管理。
- `SaveX/Core/Download/BackgroundHTTPDownloadCoordinator.swift`：background `URLSessionDownloadDelegate` 状态机。
- `SaveX/Core/Download/HTTPFileDownloader.swift`：前台 HTTP 下载和 background coordinator 适配。

## Findings

以下 Findings 记录原始项目级审查证据；当前修复状态以上方“本轮修复状态”为准。

### 1. P1 / Bug - 恢复后的后台任务失败会被静默吞掉，并可能污染后续 pause 状态

- 文件和行号：
  - `SaveX/Core/Download/SaveXDownloadKernel.swift:1060`
  - `SaveX/Core/Download/SaveXDownloadKernel.swift:1074`
  - `SaveX/Core/Download/SaveXDownloadKernel.swift:1437`
  - `SaveX/Core/Download/SaveXDownloadKernel.swift:1462`
  - `SaveX/App/DownloadCenter.swift:228`
- 问题描述：
  `observeRestoredTasks` 只为恢复后的 background `URLSessionTask` 注册进度 observer，没有注册完成/失败回调。恢复任务如果在当前进程内失败，`urlSession(_:task:didCompleteWithError:)` 进入 `activeDownload == nil` 分支后只删除 metadata 并 `return`，不会通知 `DownloadCenter` 标记失败或重启。另一个相关问题是：对恢复任务调用 `pause(jobID:)` 时会把 jobID 加入 `pausingJobIDs`，但 no-active 的 delegate 分支不会调用 `removePausingJobID`；之后同一个 job resume 后如果遇到真实网络错误，可能被 `removePausingJobID` 误判成 `downloadPaused`。
- 影响说明：
  App 重启后接管的后台下载如果失败，Jobs 会长期停在 `waitingForSystem`，用户看不到失败原因，也不会自动重试。更糟的是，恢复任务暂停后遗留的 `pausingJobIDs` 会把后续真实失败伪装成暂停，隐藏错误状态，增加后续排查和状态机维护成本。
- 建议修复方式：
  给 restored task 增加明确的完成/失败通道，而不是只传 progress。`BackgroundHTTPDownloadCoordinator` 应在 no-active `didCompleteWithError` 中根据 `taskDescription`/metadata 找到 jobID，清理 pausing marker，并向 `DownloadCenter` 回调失败或持久化 detached failure。`DownloadCenter` 收到 restored failure 后应把 job 标为 `.failed` 或进入可控重启路径。补测试：模拟已恢复 task 无 active continuation 时失败，验证 job 不会卡在 `waitingForSystem`；模拟恢复任务 pause 后 resume 再失败，验证真实错误不会被当成 pause。

### 2. P2 / Bug - `.ready` 下载完成态在重启后会被当成中断下载重新拉起

- 文件和行号：
  - `SaveX/App/DownloadCenter.swift:304`
  - `SaveX/App/DownloadCenter.swift:582`
  - `SaveX/App/DownloadCenter.swift:899`
  - `SaveX/App/DownloadCenter.swift:910`
  - `SaveX/App/DownloadCenter.swift:234`
- 问题描述：
  Library manifest 写入失败时，前台和后台完成路径都会把 job 置为 `.ready`，并保留 `localFileURL`。但 `restoredJob(from:)` 对除 `.paused` 和 terminal phase 之外的所有状态都改成 `.waitingForSystem`。因此 `.ready` job 在 App 重启后会被误认为后台系统任务待恢复；如果没有 metadata/task，`observeRestoredBackgroundTasks` 会走 missing-task 分支并重新下载。
- 影响说明：
  `.ready` 本来应该表示“文件已经下载完成，只是 Library 持久化失败”。当前恢复逻辑会丢掉这个语义，导致已有文件变成孤儿文件，并触发重复下载、重复占用磁盘和网络。这个状态折叠也让后续维护者很难判断 `.ready` 到底是下载完成态、失败恢复态，还是仍需系统接管的活跃任务。
- 建议修复方式：
  把 `.ready` 作为独立的 durable 状态处理，`restoredJob(from:)` 不应把它改成 `.waitingForSystem`。为 `.ready` 增加明确操作：重试写入 Library/Photos、打开/分享本地文件、删除并清理文件。必要时拆出 `DownloadedButUnindexed` 或 `pendingLibraryRecord` 状态，避免和活跃下载状态混用。补测试：构造 `.ready` job 且有 `localFileURL`，重启恢复后不得触发 background missing restart。

### 3. P2 / Bug - 删除 job 没有统一清理已下载文件和 HLS resume 目录

- 文件和行号：
  - `SaveX/App/DownloadCenter.swift:482`
  - `SaveX/Core/Download/SaveXDownloadKernel.swift:760`
  - `SaveX/Core/Download/SaveXDownloadKernel.swift:849`
  - `SaveX/Core/Download/SaveXDownloadKernel.swift:1394`
  - `SaveX/App/DownloadCenter.swift:578`
- 问题描述：
  `deleteJob` 只取消外层 task、删除 job store，并调用 HTTP background coordinator 的 `cancel`。它不知道 HLS resume store，也不会删除 `.ready` job 的 `localFileURL`。HLS 下载在带 `jobID` 时故意保留 working directory 以支持 resume，只有成功完成后才 `resumeStore.clear`；删除/取消路径没有对应清理。另一个竞态是：background/HTTP 下载可能已经把临时文件移动到最终目录，但 `runDownload` 发现 job 已被删除后直接 `return`，没有删除刚产出的 asset。
- 影响说明：
  用户删除任务后，`Application Support/SaveX/HLSJobs/<jobID>`、partial/resume 数据或已完成视频可能继续留在磁盘上，但 Jobs/Library 都不再引用它们。这会制造隐藏状态和磁盘泄漏；未来排查“为什么占用空间不降”或实现清理策略时，需要跨 `DownloadCenter`、HLS store、background coordinator 多处追踪。
- 建议修复方式：
  引入统一的 artifact cleanup 边界，例如 `DownloadArtifactStore` 或 `DownloadEngine.cancelAndClean(jobID:)`，由下载内核清理 HTTP resume、HLS resume/working directory、已落盘但未入库的 local file。`deleteJob` 对 `.ready`/有 `localFileURL` 的 job 应明确删除文件或转成用户可见的 Library item。`runDownload` 在 asset 返回后发现 job 已删除时，应删除该 asset 或遵循 delete tombstone。补测试：删除 HLS paused job 后 working directory 被清理；删除 `.ready` job 后 local file 被清理；completion/delete 竞态不会留下未引用文件。

### 4. P2 / Test - 自动化测试没有覆盖最危险的下载生命周期和持久化事务

- 文件和行号：
  - `SaveXTests/SaveXKernelTests.swift:4`
  - `SaveXTests/SaveXKernelTests.swift:54`
  - `scripts/hls_download_smoke.swift:59`
  - `SaveX/App/AppContainer.swift:13`
  - `SaveX/App/DownloadCenter.swift:147`
- 问题描述：
  当前 XCTest target 只有 4 个测试，主要覆盖 URL/media index 和 HLS parser unsupported tags。更有价值的 HLS resume/cancel smoke 在 `scripts/hls_download_smoke.swift`，不属于 `xcodebuild test` 的默认测试集。后台恢复失败、pause/complete 竞态、detached completion 幂等、`.ready` 恢复、删除清理、Library manifest 写入失败等高风险路径都没有自动化覆盖。`AppContainer` 和 `DownloadCenter` 也基本绑定具体实现，缺少 fake downloader/store/photo writer 注入点，导致生命周期测试很难写。
- 影响说明：
  当前项目最复杂的部分不是 parser，而是异步下载、后台恢复和本地状态事务。缺少这些测试会让后续每次改 pause/resume/background/Library 都依赖手测，回归风险高；同时硬编码依赖会推动维护者继续在大对象里加分支，而不是用可测试边界约束行为。
- 建议修复方式：
  将现有 smoke 中可离线的 HLS download/resume/cancel 用例迁入 XCTest 或让 scheme/CI 运行它们。为 `DownloadCenter` 引入可注入协议或小型 adapter：download engine、job store、library store、photo writer、background coordinator。优先补齐：restored task failure、restored pause marker、`.ready` restore、delete cleanup、detached completion replay/ack、manifest write failure。

### 5. P3 / Maintainability - 下载内核和应用编排仍集中在少数大文件，状态边界不清

- 文件和行号：
  - `SaveX/Core/Download/SaveXDownloadKernel.swift:159`
  - `SaveX/Core/Download/SaveXDownloadKernel.swift:410`
  - `SaveX/Core/Download/SaveXDownloadKernel.swift:601`
  - `SaveX/Core/Download/SaveXDownloadKernel.swift:702`
  - `SaveX/Core/Download/SaveXDownloadKernel.swift:924`
  - `SaveX/Core/Download/SaveXDownloadKernel.swift:1934`
  - `SaveX/Core/Download/SaveXDownloadKernel.swift:2152`
  - `SaveX/App/DownloadCenter.swift:82`
  - `SaveX/App/DownloadCenter.swift:131`
- 问题描述：
  `SaveXDownloadKernel.swift` 同时承载 HLS parser、HTTP/HLS resume stores、HLS downloader、background coordinator、foreground HTTP downloader 和 `DownloadEngine`。`DownloadCenter.swift` 同时负责 job store、library manifest、Photos 保存、日志、UI banner、任务编排和恢复策略。这不是单纯文件长的问题：例如 HLS cleanup state 被封在下载内核内部，`DownloadCenter.deleteJob` 只能清 HTTP coordinator，无法统一清理所有 artifact。
- 影响说明：
  状态所有权分散但文件边界又过度集中，会让生命周期 bug 很容易以局部 patch 形式修补：一个分支处理 HTTP，另一个分支漏掉 HLS；一个路径处理前台完成，另一个路径漏掉 detached completion。未来接入 Settings、后台策略、磁盘清理或更完整的 Library pending 状态时，维护者需要同时理解 UI、store、URLSession delegate 和 HLS 目录布局，改动危险性会持续上升。
- 建议修复方式：
  按现有架构文档做渐进拆分，不需要一次性重构：提取 `JobStore`/`LibraryStore` 到 Data 层；提取 `BackgroundHTTPDownloadCoordinator`、`HTTPResumeStore`、`HLSResumeStore`、`HLSMediaDownloader`、`HLSManifestParser` 到独立文件；新增统一的 artifact/file store，供 HTTP/HLS/background/delete 共用。`DownloadCenter` 保留用例编排和 UI 状态映射，清理/恢复细节下沉到可测试的应用服务或 core service。

## 验证情况

- `xcodebuild -list -project SaveX.xcodeproj`：确认存在 `SaveX` 和 `SaveXTests` targets，scheme 为 `SaveX`。
- `xcodebuild -project SaveX.xcodeproj -scheme SaveX -destination 'generic/platform=iOS Simulator' test CODE_SIGNING_ALLOWED=NO`：未执行测试，Xcode 报错要求 concrete device；这是命令目的地限制，不是项目测试失败。
- `xcodebuild -project SaveX.xcodeproj -scheme SaveX -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.3.1' test CODE_SIGNING_ALLOWED=NO`：通过，7 个 `SaveXKernelTests` 全部通过。
- `swiftc ... scripts/kernel_fixture_smoke.swift`：通过。
- `swiftc ... scripts/hls_manifest_smoke.swift`：通过。
- `swiftc ... scripts/hls_download_smoke.swift`：通过。
- `swiftc ... scripts/library_store_smoke.swift`：通过。

未验证项：真机 background URLSession 被系统唤醒、App 被 kill 后的 completion handler 时序、真实 Photos 权限弹窗与保存、真实 Twitter/X API 字段变化和限流行为。

## 简短结论

- 修复后整体风险等级：Medium。
- 是否建议合并：可以合并当前修复，但真机后台恢复仍建议在发布前做一次手动验证。
- 合并前必须处理的问题：无新的代码级阻塞项。
- 建议补充的测试：真实 background URLSession kill/relaunch 场景仍需要真机或更高层集成测试覆盖；detached completion replay/ack 和 Library manifest 写入失败也仍可继续加强。
