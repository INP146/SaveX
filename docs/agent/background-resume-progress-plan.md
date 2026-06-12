# 后台下载、断点续传、精细进度实施计划

这份计划聚焦三个能力：

- MP4 单文件后台下载
- MP4 与 HLS 的断点续传
- 任务列表里的精细进度与可恢复状态

当前代码已经打通基础下载链路，但这三项还没有真正落到可恢复、可持久化、可后台接管的任务系统里。目标是把下载层从“发起一次 async download”升级成“可被系统、App 生命周期和 UI 共同管理的下载任务”。

## 1. 当前状态

### 执行进度

- 2026-06-12: Phase 1 已开始落地。代码已加入结构化 `DownloadProgressEvent`、MP4 字节级传输进度、HLS segment 级进度，以及 Jobs 页面里的字节/速度/ETA/segment 展示。
- 2026-06-12: Phase 2/4 已开始落地。MP4 默认下载路径已接入 `URLSessionConfiguration.background` delegate coordinator；SwiftUI lifecycle 已接入 background URLSession completion handler；未完成 Jobs 已开始持久化到 Application Support；background task metadata 和 detached completion 暂存已接上，App 被系统唤醒后可以把无 continuation 的完成结果交回 `DownloadCenter` 入库。
- 2026-06-12: 修复 App 被 kill 后重进一直停在 `waitingForSystem` 的问题。启动时会主动重建 background session、查询系统仍在运行的 background tasks、按 metadata 重新绑定进度观察；如果 iOS 已经不再保留该 background task，会清理旧 metadata 并自动重新排队，而不是直接失败。
- 2026-06-12: Jobs 页面已补上失败任务重试和任务删除；background task 恢复匹配改为优先使用 `taskDescription` / job id，避免只靠 `taskIdentifier` 变化导致误判 missing；旧版本已经写入的 missing-background failed 任务会在启动时自动重新排队。
- 2026-06-12: MP4 已接入用户暂停/继续、`resumeData` 持久化、resumeData 失效后的 HTTP Range fallback；HLS 工作目录已改为按 job id 持久化，segment 下载状态会落盘，恢复时跳过已完成 segment。
- 后续仍需补更细的设备级后台测试矩阵、resumeData 失效诊断日志，以及 HLS 后台时间片策略。

### 已有能力

- `HTTPFileDownloader` 可以下载单文件 MP4，并保存到本地 Downloads 目录。
- `HLSMediaDownloader` 可以下载 VOD playlist 的 segment，顺序拼接后导出 MP4。
- `DownloadCenter` 可以创建任务、展示阶段进度、记录日志和本地媒体库。
- Jobs 页面有 `ProgressView`，可以展示当前任务 phase 和粗略进度。

### 主要缺口

- MP4 下载使用普通 `URLSession`，没有使用 `URLSessionConfiguration.background`。
- 没有 background session delegate，也没有处理 App 被系统唤醒后的 completion handler。
- 没有持久化 job store；App 重启后无法恢复未完成任务。
- 没有保存 `resumeData`，也没有基于 HTTP `Range` 的续传策略。
- HLS segment 工作目录是临时 UUID 目录，任务结束或失败后没有可恢复的 segment 状态。
- 下载进度现在是阶段常量，不是字节级或 segment 级实时进度。

## 2. 设计原则

- MP4 优先实现系统级后台下载，因为它最符合 iOS background URLSession 模型。
- HLS 不承诺长期后台稳定下载，采用前台优先、短时后台继续、回前台恢复的策略。
- 所有可恢复能力都必须先有持久化任务模型，否则 UI 和 downloader 会互相猜状态。
- 进度模型要区分“阶段进度”和“传输进度”，避免下载前解析阶段和下载中百分比混在一起。
- 下载任务的状态机要显式表达暂停、系统挂起、可恢复、失败不可恢复等状态。

## 3. 目标状态

### MP4

- 使用 background `URLSessionDownloadTask`。
- App 进入后台、被挂起后，系统可以继续下载单文件。
- App 被系统唤醒时能接回完成事件，移动文件到最终目录，并更新 Library。
- 失败或取消时保存可用的 `resumeData`。
- 用户可以暂停、继续、取消。
- UI 展示已下载字节、总字节、速度、剩余时间。

### HLS

- manifest 和 segment 下载状态可持久化。
- 已完成 segment 不重复下载。
- 失败后可以从未完成 segment 继续。
- 前台运行时可以展示 segment 级进度。
- 进入后台时申请有限后台时间；时间不足则保存状态并标记为可恢复。
- 回到前台后自动或手动恢复。

### UI / 状态

- Jobs 页面展示更细的状态：准备、下载中、暂停、等待系统、恢复中、导出中、保存相册中、完成、失败。
- 每个任务显示格式、文件大小、已下载大小、百分比、速度和错误原因。
- App 重启后能重新加载未完成任务。
- Logs 能记录恢复、暂停、后台接管、segment 跳过等关键事件。

## 4. 数据模型

新增 `DownloadJobRecord`，由 `JobStore` 持久化到 JSON、SQLite 或 SwiftData。

建议字段：

```text
id
sourceURL
tweetID
selectedMediaIndex
preference
selectedFormatID
route: mp4 | hls
phase
createdAt
updatedAt
destinationFileName
temporaryDirectory
downloadedBytes
totalBytes
progressFraction
resumeDataFileName
backgroundTaskIdentifier
hlsManifestURL
hlsSegmentRecords
errorMessage
isRecoverable
```

HLS segment record：

```text
index
url
duration
fileName
byteSize
state: pending | downloading | completed | failed
retryCount
lastError
```

## 5. Phase 1: 进度模型先落地

目的：先把 UI 和核心层之间的事件协议升级好，避免后面每加一种 downloader 都改 UI。

任务：

- 新增 `DownloadProgressEvent`。
- 区分 phase、transfer、file、segment、export、photoSave 等事件。
- `DownloadEngine.download` 回调从 `(phase, progress, formatID)` 升级为结构化事件。
- `DownloadJob` 增加 `downloadedBytes`、`totalBytes`、`speedBytesPerSecond`、`etaSeconds`、`detailText`。
- Jobs 页面显示百分比和字节信息。
- 对 MP4 暂时仍可用普通 session，但先通过 delegate 或自定义 adapter 上报字节进度。

验收：

- MP4 下载过程中进度不再直接跳到 `0.9`。
- UI 能显示类似 `12.4 MB / 48.0 MB`。
- 解析、选择格式、下载、保存相册各阶段的进度来源清晰。

## 6. Phase 2: MP4 background URLSession

目的：把最稳定的单文件 MP4 下载接入 iOS 后台下载模型。

任务：

- 新增 `BackgroundDownloadService`，用 `URLSessionConfiguration.background(withIdentifier:)`。
- 用 delegate 接收：
  - `urlSession(_:downloadTask:didWriteData:totalBytesWritten:totalBytesExpectedToWrite:)`
  - `urlSession(_:downloadTask:didFinishDownloadingTo:)`
  - `urlSession(_:task:didCompleteWithError:)`
- 在 App 启动时用固定 identifier 重建 background session。
- 在 App delegate / SwiftUI lifecycle 中保存系统提供的 background completion handler。
- 把 `URLSessionTask.taskIdentifier` 映射到 `DownloadJobRecord.id`。
- 完成后移动临时文件到最终目录，并更新 Library。

验收：

- 开始 MP4 下载后切到后台，下载可以继续由系统管理。
- App 被重新打开后，任务状态和文件结果正确。
- 完成事件不会丢失，也不会重复入库。

## 7. Phase 3: MP4 断点续传

目的：支持用户暂停、网络失败后恢复。

任务：

- 用户暂停时调用 `cancel(byProducingResumeData:)`。
- 将 `resumeData` 写入 `Application Support/SaveX/ResumeData`。
- Job record 保存 resume data 文件名。
- 继续下载时优先使用 `downloadTask(withResumeData:)`。
- 如果 resume data 失效，再检查服务器是否支持 `Accept-Ranges`。
- 对可 Range 的 MP4，使用 `Range: bytes=<localSize>-` 补齐临时文件。
- 对不可恢复的失败，明确标记 `isRecoverable = false`。

验收：

- MP4 下载到一半暂停后，继续不会从 0 开始。
- App 重启后仍能恢复可恢复任务。
- resume data 无效时有可理解的失败日志或 Range fallback。

## 8. Phase 4: JobStore 与 App 重启恢复

目的：让下载任务成为持久化对象，而不是内存里的临时数组。

任务：

- 新增 `JobStore`，负责保存和读取 `DownloadJobRecord`。
- `DownloadCenter` 启动时加载 active / paused / recoverable jobs。
- 对 background MP4，重建 session 后等待系统回调，不重复创建任务。
- 对 paused jobs，显示“继续”入口。
- 对 failed recoverable jobs，显示“重试/恢复”入口。
- 清理 completed / canceled 任务的临时文件和 resume data。

验收：

- App 强退再打开后，未完成任务仍在 Jobs 页面。
- 可恢复任务能继续。
- 已完成任务只保留 Library 记录，不残留无用临时数据。

## 9. Phase 5: HLS segment 级续传

目的：让 HLS 在前台下载中具备失败恢复能力。

任务：

- HLS 工作目录不再使用纯临时 UUID 后立即删除，改成与 job id 绑定。
- manifest 解析结果写入 job record。
- 每个 segment 下载完成后落盘并标记 completed。
- 恢复时跳过已完成 segment。
- 下载失败时保留已完成 segment 和 manifest 状态。
- 拼接前校验 segment 数量、顺序和文件存在性。
- 导出成功后清理 HLS 工作目录。

验收：

- HLS 下载中断后，恢复时不会重复下载已完成 segment。
- Jobs 能显示 `35 / 120 segments` 这类进度。
- 导出失败不会误标为下载失败不可恢复，除非错误确实不可恢复。

## 10. Phase 6: HLS 后台策略

目的：让 HLS 在 iOS 约束下尽量友好，但不假装它等同于 MP4 后台下载。

任务：

- App 进入后台时，如果 HLS 正在下载，申请 `beginBackgroundTask`。
- 后台时间即将过期时停止创建新 segment 请求，保存当前状态。
- 将任务标记为 `pausedBySystem`。
- 回到前台时自动恢复或提示用户继续。
- Logs 记录后台时间过期、系统暂停、前台恢复。

验收：

- HLS 进入后台不会丢失已完成 segment。
- 后台时间不足时任务状态可解释，不表现为普通失败。
- 回前台后可以继续。

## 11. Phase 7: UI 操作与诊断

目的：让用户能控制任务，也让调试变得可靠。

任务：

- Jobs row 增加暂停、继续、取消、重试按钮。
- 增加速度和 ETA。
- 失败状态显示是否可恢复。
- Logs 增加 task id、session id、segment index、resume data 状态。
- Settings 里的蜂窝网络、并发数、后台策略接入真实配置。

验收：

- 用户可以完整控制 MP4 任务生命周期。
- HLS 可恢复失败能被清晰解释。
- 诊断日志足够定位后台回调丢失、resume data 失效、segment 失败等问题。

## 12. 建议实现顺序

1. 先做结构化进度事件和 UI 字段。
2. 再做 MP4 background session。
3. 接 MP4 暂停/继续和 resume data。
4. 做 JobStore 和重启恢复。
5. 做 HLS segment store 和恢复。
6. 最后接 HLS 短时后台策略和完整 UI 操作。

这个顺序能先把最稳定、最符合 iOS 平台能力的 MP4 路径打磨好，再把 HLS 做成“前台可靠、后台可解释、回前台可恢复”。
