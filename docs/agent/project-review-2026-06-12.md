# Project Review - 2026-06-12

审查范围：当前 `main` 无未提交 diff，重点审查最新提交 `1274ba7 feat: Enhance download management with progress events and resumable downloads` 相对 `HEAD~1` 的项目级影响。

## Findings

### 1. P1 / Bug - 恢复后的 background task 只按旧 taskIdentifier 查 metadata，可能丢失完成事件

- 文件和行号：
  - `SaveX/Core/Download/SaveXDownloadKernel.swift:935`
  - `SaveX/Core/Download/SaveXDownloadKernel.swift:1145`
  - `SaveX/Core/Download/SaveXDownloadKernel.swift:1581`
- 问题描述：
  `observeRestoredTasks` 恢复任务时允许用 `taskDescription == jobID` 或旧 `taskIdentifier` 匹配系统任务，但后续 delegate 回调里，进度和完成处理仍只调用 `metadata(for: taskIdentifier)`。如果重建 background session 后系统任务的 `taskIdentifier` 与持久化 metadata 不一致，任务会被启动阶段认为“已绑定”，但 `didWriteData` 找不到 metadata，不再更新进度；更严重的是 `didFinishDownloadingTo` 会直接 `return`，不会把临时文件移动到最终目录，也不会写 detached completion。
- 影响说明：
  App 被系统杀掉或重启后，MP4 background 下载完成事件可能被静默丢弃。iOS 的 download 临时文件需要在 delegate 回调里及时移动；这里提前返回会导致下载结果丢失，Jobs 可能一直停留在 `waitingForSystem`，或后续被误判 missing 后重复下载。
- 建议修复方式：
  统一 task -> metadata 查找路径，优先用 `task.taskDescription` 解析 `jobID`，再 fallback 到当前 `taskIdentifier`。在 `observeRestoredTasks` 成功绑定时，应把 metadata 的 `taskIdentifier` 更新为当前 task 的 identifier。`pause(jobID:)` 中 `metadataList.first { $0.taskIdentifier == task.taskIdentifier }` 也需要按 `jobID/taskDescription` fallback。补一个 coordinator 级测试，模拟 metadata 里的旧 task id 与恢复后 task id 不一致，验证进度、完成移动和 pause resumeData 都仍然可用。

### 2. P1 / Bug - detached completion 在处理前被清空，进程中断会永久丢结果

- 文件和行号：
  - `SaveX/Core/Download/SaveXDownloadKernel.swift:1033`
  - `SaveX/App/DownloadCenter.swift:256`
  - `SaveX/App/DownloadCenter.swift:269`
- 问题描述：
  `drainDetachedCompletions()` 读取持久化完成记录后立刻 `saveDetachedCompletions([])`，而 `DownloadCenter.consumeDetachedBackgroundCompletions()` 随后才逐条更新 job、写入 library、保存 Photos。`handleDetachedBackgroundCompletion` 末尾虽然有 `acknowledgeDetachedCompletion`，但启动恢复路径中记录已经提前被删掉。
- 影响说明：
  如果 App 在 drain 之后、library manifest 写入之前被系统挂起/杀掉，background 下载文件已经移动到 Documents，但 detached completion 已经不存在；job 也可能在 `updateJob(.completed)` 时被从 job store 移除。结果是用户既看不到未完成任务，也看不到 Library 记录，下载结果变成孤儿文件。这个问题直接削弱了本次变更要解决的“后台完成不丢失”目标。
- 建议修复方式：
  把 drain 改成 peek/read，不要提前删除。只有在 `recordLibraryItem` 成功并且 job 状态更新完成后再 ack 单个 completion。为避免重复处理，完成处理应按 `jobID` 或 `localFileURL` 做幂等。补测试覆盖：持久化一个 detached completion，模拟 `handleDetachedBackgroundCompletion` 中途失败/中断后再次启动，确认 completion 仍可重放。

### 3. P2 / Bug - HTTP Range fallback 未校验 Content-Range 起点，可能拼接出损坏文件

- 文件和行号：
  - `SaveX/Core/Download/SaveXDownloadKernel.swift:1414`
  - `SaveX/Core/Download/SaveXDownloadKernel.swift:1433`
  - `SaveX/Core/Download/SaveXDownloadKernel.swift:1443`
- 问题描述：
  当存在 partial file 时，代码发送 `Range: bytes=<existingBytes>-`，但只检查响应状态是否为 206。它没有解析 `Content-Range` 并确认返回范围确实从 `existingBytes` 开始。如果服务端、代理或 CDN 返回了错误的 206 范围，当前实现会直接 seek 到 partial 末尾继续追加。
- 影响说明：
  断点续传会生成字节重复或缺口的 MP4 文件，后续仍可能被标记为 completed 并保存到 Photos。用户看到的是“下载成功但视频损坏”，排查成本高。
- 建议修复方式：
  对 206 响应解析 `Content-Range`，要求 start 等于 `existingBytes`，total 与已知 total 不冲突；不满足时删除 partial 并从 0 重新下载，或明确失败。补 URLProtocol mock 测试：partial 为 N 字节，服务端返回 `Content-Range: bytes 0-.../...` 时不得追加到旧 partial。

### 4. P2 / Bug - HLS 导出阶段取消不可靠，删除/暂停后仍可能入库或保存 Photos

- 文件和行号：
  - `SaveX/Core/Download/SaveXDownloadKernel.swift:751`
  - `SaveX/App/DownloadCenter.swift:404`
  - `SaveX/App/DownloadCenter.swift:518`
- 问题描述：
  HLS 下载在 segment 循环和导出前检查 cancellation，但 `exporter.exportMP4` 返回后没有再次 `Task.checkCancellation()`，`AVFoundationHLSMediaExporter` 也没有用 cancellation handler 显式调用 `AVAssetExportSession.cancelExport()`。同时 `deleteJob` 只是取消 task 并移除 job；如果 exporter 不响应 Swift task cancellation，`runDownload` 拿到 asset 后仍会执行 `recordLibraryItem` 和 Photos save。
- 影响说明：
  用户在 HLS `exportingMedia` 阶段点击 Delete 或 Pause 后，任务仍可能继续产出 MP4、写入 Library、保存到 Photos。这会制造隐藏副作用：UI 上任务已经被删除/暂停，但本地文件和相册状态仍被后台逻辑改变。
- 建议修复方式：
  在 `exportMP4` 返回后立即 `try Task.checkCancellation()`，并在返回 asset 前清理取消时产生的 destination file。`AVFoundationHLSMediaExporter` 应使用 `withTaskCancellationHandler` 调用 `exportSession.cancelExport()`。`runDownload` 在 `recordLibraryItem` 前也应确认 job 仍存在且未 paused/deleted。补一个慢 exporter 测试：导出中取消/删除后不得入库、不得调用 Photos writer。

### 5. P2 / Performance - 每个进度事件都同步重写 jobs.json，会拖慢 UI 并放大 IO

- 文件和行号：
  - `SaveX/App/DownloadCenter.swift:579`
  - `SaveX/App/DownloadCenter.swift:603`
  - `SaveX/App/DownloadCenter.swift:611`
  - `SaveX/Core/Download/SaveXDownloadKernel.swift:1124`
- 问题描述：
  `applyProgressEvent` 每次更新下载字节、速度、ETA 都调用 `updateJob`，而 `updateJob` 立即 `persistJob`。`persistJob` 通过 `DownloadJobStore.upsert` 读取、修改、JSON encode 并 atomic write 整个 `jobs.json`。background 下载进度目前每 0.25 秒触发一次，多任务时会在 MainActor 上持续同步磁盘读写。
- 影响说明：
  长时间下载会造成不必要的闪存 IO、电量消耗和主线程卡顿风险。更重要的是，持久化策略和 UI 实时状态耦合在一起，未来新增更多 progress 字段或并发任务时，维护者很难判断哪些状态必须 durable，哪些只是展示态。
- 建议修复方式：
  区分实时 UI progress 与 durable job snapshot。phase 变化、pause/resume/fail、resume checkpoint 等关键状态立即持久化；字节/速度/ETA 用 debounce 或后台 actor 降频写入，例如 5-15 秒一次，或只在进入后台/暂停/失败时保存。给 `DownloadJobStore` 注入可观测 fake store，补测试验证高频 progress 不会触发等量磁盘写。

### 6. P3 / Convention - 提交包含 Xcode 用户界面状态二进制文件

- 文件和行号：
  - `SaveX.xcodeproj/project.xcworkspace/xcuserdata/user.xcuserdatad/UserInterfaceState.xcuserstate:1`
- 问题描述：
  本次提交包含 `UserInterfaceState.xcuserstate` 的二进制变更。这是本机 Xcode 窗口/编辑器状态，不是项目源代码或构建输入。
- 影响说明：
  这类文件会制造无意义 diff 和合并冲突，也会让后续 review 混入不可读的二进制噪音。它不会直接导致运行时 bug，但会持续污染主分支历史。
- 建议修复方式：
  从仓库移除该文件并加入忽略规则，例如 `*.xcuserstate`、`xcuserdata/`。如果已被追踪，用 `git rm --cached` 移出索引。

## 验证情况

- `xcodebuild -project SaveX.xcodeproj -scheme SaveX -destination generic/platform=iOS -derivedDataPath /tmp/SaveXDerivedData CODE_SIGNING_ALLOWED=NO build`：通过。
- `/tmp/hls_download_smoke`：通过。
- `/tmp/library_store_smoke`：通过。

第一次 sandbox 内 `xcodebuild` 被 CoreSimulator/cache 权限问题挡住；在授权的沙箱外重跑后通过。Swift smoke 使用 `swiftc` 编译到 `/tmp` 后执行，避免解释器把后续 Swift 文件当脚本参数。

## 简短结论

- 整体风险等级：High。
- 是否建议合并：不建议直接合并。
- 合并前必须处理的问题：Finding 1 和 Finding 2。它们都影响 background 下载完成结果的可靠性，属于本次功能的核心目标。
- 建议补充的测试：
  - background session 恢复后 taskIdentifier 变化但 taskDescription/jobID 保持一致的完成与暂停路径。
  - detached completion 在处理前后发生中断时的重放与幂等。
  - HTTP Range fallback 的错误 `Content-Range` 响应。
  - HLS 导出中取消/删除后不得入库、不得保存 Photos。
  - 高频 progress 不应导致同频率 job store 写盘。
