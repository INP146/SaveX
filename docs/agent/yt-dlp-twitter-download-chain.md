# yt-dlp 下载 Twitter/X 视频的原理和链路

本文基于仓库内源码版本 `yt-dlp-2026.06.09` 整理，关注标准 Tweet URL 走到视频文件落盘的主链路。

## 1. 结论先行

`yt-dlp` 下载 Twitter/X 视频，不是“先抓网页再从 HTML 里硬抠视频地址”，主路径是：

1. 用 `TwitterIE` 匹配 Tweet URL。
2. 通过 Twitter/X API 拿 Tweet 结构化数据。
3. 从 `extended_entities.media[].video_info.variants` 或 `card` 里提取媒体源。
4. 把源地址转换成 `formats` 列表。
5. `YoutubeDL` 对 `formats` 排序、筛选、选中最终格式。
6. 根据协议选择 downloader：
   - 直链 MP4 通常走 `HttpFD`
   - HLS `m3u8_native` 通常走 `HlsFD`
   - `m3u8` 或需要委托时走 `FFmpegFD`
7. 下载器把文件或分片写到本地，必要时再做合并。

一句话概括：`extractor` 负责“拿到可下载媒体信息”，`YoutubeDL` 负责“选格式”，`downloader` 负责“真正下载”。

## 2. 关键源码位置

- Tweet extractor: `yt-dlp-2026.06.09/yt_dlp/extractor/twitter.py`
- 调度入口: `yt-dlp-2026.06.09/yt_dlp/YoutubeDL.py`
- 下载器分派: `yt-dlp-2026.06.09/yt_dlp/downloader/__init__.py`
- HLS 原生下载: `yt-dlp-2026.06.09/yt_dlp/downloader/hls.py`
- 分片下载基类: `yt-dlp-2026.06.09/yt_dlp/downloader/fragment.py`

## 3. 标准入口链路

用户给一个 Tweet URL，例如：

```text
https://x.com/<user>/status/<tweet_id>
https://twitter.com/<user>/status/<tweet_id>
https://x.com/<user>/status/<tweet_id>/video/1
```

主入口调用链：

```text
YoutubeDL.extract_info(url)
  -> 选中 TwitterIE
  -> YoutubeDL.__extract_info(...)
  -> TwitterIE._real_extract(url)
  -> 返回 info_dict
  -> YoutubeDL.process_ie_result(...)
  -> YoutubeDL.process_video_result(...)
  -> YoutubeDL.process_info(...)
  -> get_suitable_downloader(...)
  -> 具体 downloader 下载
```

其中：

- `extract_info` 负责选 extractor。
- `TwitterIE._real_extract` 负责拿到 Tweet 元数据和媒体源。
- `process_video_result` 负责格式清洗、排序、筛选。
- `process_info` 负责把最终选中的格式交给下载器。

## 4. URL 匹配与视频索引

`TwitterIE` 的 URL 规则支持：

- 标准状态页 `/status/<id>`
- 旧式 `/statuses/<id>`
- 带显式媒体索引 `/video/<n>` 或 `/photo/<n>`

这意味着一个 Tweet 有多个媒体时，`yt-dlp` 有两种行为：

- 不指定索引：把多个视频媒体当 playlist/多 entry 处理
- 指定 `/video/1`：只提取指定视频

对应逻辑在 `TwitterIE._real_extract` 里通过 `selected_index` 和 `_yes_playlist(...)` 控制。

## 5. Tweet 元数据是怎么拿到的

### 5.1 API 选择

`TwitterBaseIE` 默认 API 选择是 `graphql`，也支持：

- `graphql`
- `legacy`
- `syndication`

默认值来自：

```python
def _selected_api(self):
    return self._configuration_arg('api', ['graphql'], ie_key='Twitter')[0]
```

### 5.2 请求头和鉴权

基础请求头由 `_set_base_headers(...)` 构造，核心是：

- `Authorization: Bearer ...`
- 已登录时尝试带 `x-csrf-token`

是否“已登录”通过 cookie 里的 `auth_token` 判断。

如果没登录，`_call_api(...)` 会先调用：

```text
POST https://api.x.com/1.1/guest/activate.json
```

拿 `guest_token`，然后加到：

- `x-guest-token`

如果已登录，则附带：

- `x-twitter-auth-type: OAuth2Session`
- `x-twitter-client-language: en`
- `x-twitter-active-user: yes`

所以标准匿名访问链路其实是：

```text
Tweet URL
  -> guest/activate.json 拿 guest token
  -> GraphQL 或 legacy API 拿 Tweet JSON
```

### 5.3 GraphQL 主路径

默认标准路径是：

```text
https://x.com/i/api/graphql/<endpoint>/TweetResultByRestId
```

本版本 `_GRAPHQL_ENDPOINT` 是：

```text
2ICDjqPd81tulZcYrtpTuQ/TweetResultByRestId
```

`_build_graphql_query(...)` 会传三组参数：

- `variables`
- `features`
- `fieldToggles`

其中最关键的是：

- `tweetId`

GraphQL 返回的数据结构不是老 REST 结构，所以还要经过 `_graphql_to_legacy(...)` 做一次归一化。

### 5.4 Legacy API 兼容路径

如果强制选 `legacy`，会请求：

```text
https://api.x.com/1.1/statuses/show/<tweet_id>.json
```

附带的典型 query 包括：

- `cards_platform=Web-12`
- `include_cards=1`
- `include_reply_count=1`
- `include_user_entities=0`
- `tweet_mode=extended`

这个接口返回的结构已经比较接近老版 Tweet JSON。

### 5.5 限流后的回退

如果 GraphQL/legacy 请求抛出 `HTTP 429`，`_extract_status(...)` 会回退到 syndication：

```text
https://cdn.syndication.twimg.com/tweet-result?id=<twid>&token=<generated>
```

token 不是服务端下发，而是本地按 Tweet ID 计算出来的：

```text
((Number(twid) / 1e15) * Math.PI).toString(36).replace(/(0+|\.)/g, '')
```

源码里由 `_generate_syndication_token(...)` 实现。

这条回退链路的特点：

- 能绕过部分 API 限流
- 但 metadata 和 media 不一定完整
- 代码里有明确 warning：`Not all metadata or media is available via syndication endpoint`

## 6. GraphQL 结果如何归一化

GraphQL 返回结构和老 REST 不同，所以 `yt-dlp` 先做一次“转旧结构”：

- 从 `tweetResult.result` 取主体
- 处理 `TweetWithVisibilityResults`
- 识别 `TweetUnavailable` / tombstone / 需要登录
- 把这些字段尽量映射到 legacy 风格：
  - `legacy`
  - `core.user_results.result.legacy`
  - `card.legacy`
  - `quoted_status_result.result.legacy`
  - `retweeted_status_result.result.legacy`

同时，`card.binding_values` 在 GraphQL 结果里是数组，`yt-dlp` 会把它转成按 key 索引的 dict，方便后续按字段取值。

这一步的意义很直接：后面的媒体提取逻辑只需要处理一套近似统一的 Tweet 结构。

## 7. 视频地址是怎么抽出来的

`TwitterIE._real_extract(...)` 主要有两条媒体提取路径：

1. `extended_entities.media[].video_info.variants`
2. `status.card`

### 7.1 常规原生视频路径

对原生 Twitter/X 视频，最常见的是：

```text
status
  -> extended_entities
    -> media[]
      -> video_info
        -> variants[]
```

每个 `variant` 可能是：

- 直链 MP4
- HLS manifest（`.m3u8`）

`extract_from_video_info(...)` 会遍历 `variants`，逐个交给 `_extract_variant_formats(...)`。

### 7.2 `_extract_variant_formats(...)` 的行为

如果 `variant.url`：

- 包含 `.m3u8`
  - 调 `_extract_m3u8_formats_and_subtitles(...)`
  - 生成一组 HLS formats
  - 同时解析字幕
- 否则
  - 按普通 HTTP 视频直链处理
  - 从 `bitrate` / `bit_rate` 生成 `tbr`
  - 从 URL 中尝试解析分辨率

也就是说，Twitter/X extractor 自己并不下载 HLS 分片，它只是把 manifest URL 展开成一批候选格式。

### 7.3 卡片媒体路径

很多 Tweet 不是标准 `video_info.variants`，而是通过 `card` 提供媒体能力。`extract_from_card_info(...)` 会按 `card.name` 分支处理：

- `player`
  - 返回 `_type=url`
  - 后续递归交给其它 extractor
- `periscope_broadcast`
  - 交给 `PeriscopeIE`
- `broadcast`
  - 交给 `TwitterBroadcastIE`
- `audiospace`
  - 交给 `TwitterSpacesIE`
- `summary`
  - 交给 `card_url`
- `unified_card`
  - 从 `media_entities` 里继续抽视频
- 其它视频类 card
  - 走 VMAP

这意味着一个 Tweet 页面里看到“视频”，不一定真的由 `TwitterIE` 直接落盘；有些只是把下载工作转给别的 extractor。

### 7.4 VMAP 路径

对 `amplify`、`promo_video_*`、`appplayer` 等 card，`yt-dlp` 会读：

- `amplify_url_vmap`
- 或 `player_stream_url`

然后进入 `_extract_formats_from_vmap_url(...)`：

1. 下载 VMAP XML
2. 遍历 `videoVariant`
3. 把 `videoVariant.attrib['url']` 还原
4. 继续复用 `_extract_variant_formats(...)`
5. 如果 `MediaFile` 里还有一个主媒体地址且前面没覆盖，再补进格式列表

所以 VMAP 本质上也是“中间描述层”，最终仍然会回到：

- MP4 直链
- 或 m3u8 manifest

## 8. 返回给 YoutubeDL 的 info_dict 长什么样

`TwitterIE._real_extract(...)` 最终返回的是标准 `info_dict`，核心字段包括：

- `id`
- `title`
- `description`
- `uploader`
- `uploader_id`
- `timestamp`
- `view_count`
- `like_count`
- `repost_count`
- `comment_count`
- `age_limit`
- `tags`
- `formats`
- `subtitles`
- `thumbnails`
- `duration`

其中最关键的是 `formats`。后续所有下载动作都围绕它展开。

## 9. `YoutubeDL` 如何处理这些格式

`YoutubeDL.process_ie_result(...)` 收到 `video` 类型结果后，会进入：

```text
process_video_result(info_dict, download=True)
```

这里做的事主要有：

1. 清洗字段类型
2. 补默认字段
3. 整理字幕/缩略图
4. 校验 `formats`
5. 给每个 format 算协议、分辨率、近似大小、请求头
6. 排序 formats
7. 根据 `-f` 选择最终下载格式

### 9.1 Twitter extractor 对排序的特殊处理

`extract_from_video_info(...)` 里专门设置了：

```python
'_format_sort_fields': ('res', 'proto:m3u8', 'br', 'size')
```

注释写得很清楚：

- 优先按分辨率
- 同分辨率下优先 m3u8
- 再按码率
- 最后按 size

原因是 Twitter/X 的 HTTP 直链格式经常缺少 codec 等完整信息，所以 extractor 显式提高了 HLS 的优先级。

### 9.2 请求头如何下传到实际下载

`process_video_result(...)` 会为每个 format 调：

```text
fmt['http_headers'] = self._calc_headers(...)
```

这样后续真正下载时，下载器能继续复用 cookie、鉴权头、UA 等上下文，而不是裸连媒体 URL。

## 10. 真正下载时如何选 downloader

`YoutubeDL.process_info(...)` 里会调用：

```text
get_suitable_downloader(info_dict, params, ...)
```

分派逻辑在 `yt_dlp/downloader/__init__.py`。

核心映射关系：

- `http` / `https` -> `HttpFD`
- `m3u8_native` -> `HlsFD`
- `m3u8` -> `FFmpegFD`
- `http_dash_segments` -> `DashSegmentsFD`

另外还有几个规则很重要：

- 直播 HLS 通常强制走 `FFmpegFD`
- 如果显式要求 `hls_prefer_native=True`，优先 `HlsFD`
- 如果 `hls_prefer_native=False`，优先 `FFmpegFD`
- 如果只下载片段区间，且 ffmpeg 可用，会优先 `FFmpegFD`

所以“Twitter 视频最终怎么下”，不是 extractor 决定的，而是由 format 的协议和 downloader 规则共同决定。

## 11. HLS 下载内部链路

当选中的格式是 `m3u8_native` 时，通常进入 `HlsFD.real_download(...)`。

链路如下：

```text
HlsFD.real_download(...)
  -> 下载 m3u8 manifest
  -> 检查 DRM / AES-128 / 不支持特性
  -> 能原生下就解析分片
  -> 不能原生下就委托 FFmpegFD
  -> 逐个 fragment 下载
  -> 拼接为最终文件
```

### 11.1 Manifest 检查

`HlsFD.can_download(...)` 会拒绝或降级这些情况：

- live HLS
- 某些不支持的 manifest 特性
- DRM
- 部分加密场景

如果原生下载器不适合，代码会：

```text
extraction will be delegated to ffmpeg
```

### 11.2 分片下载

原生 HLS 情况下，`HlsFD` 会：

1. 逐行解析 manifest
2. 找出媒体分片 URL
3. 构造 `fragments` 列表
4. 交给 `FragmentFD` 统一处理

`FragmentFD` 提供：

- 分片断点续传状态
- 并发下载
- 临时文件写入
- 下载进度统计
- 最终拼接

所以 HLS 的真正“落盘”不是 extractor 在做，而是 downloader 层在做。

## 12. 多格式/多轨时的处理

如果最终选中了多个格式，比如视频轨和音频轨分离，`process_info(...)` 可能会：

1. 分别下载多个 `requested_formats`
2. 记录临时文件
3. 用 `FFmpegMergerPP` 合并

不过 Twitter/X 原生视频常见情况是：

- 单一 MP4
- 或 HLS 单流/变体流

因此多数 Tweet 视频不会走复杂的音视频分离合并，但框架能力是通用存在的。

## 13. 特殊分支和边界情况

### 13.1 转推

源码在归一化时会优先处理 `retweeted_status`，实际拿到的视频可能来自被转推的原 Tweet，而不是外层转推壳。

### 13.2 受保护、NSFW、未授权

GraphQL 归一化里显式处理：

- `Protected`
- `NsfwLoggedOut`
- `NsfwViewerHasNoStatedAge`
- tombstone

这些情况会要求登录或直接报不可用。

### 13.3 外链播放器

如果 Tweet card 是 `player`，最终可能返回外部 URL，由其它 extractor 接管。也就是说：

- 你输入的是 Twitter URL
- 最后下载的却未必是 Twitter CDN 上的视频

### 13.4 多媒体 Tweet

一个 Tweet 可能有多张图、多个视频、视频加引用 Tweet。`TwitterIE` 会根据 URL 是否指定 `/video/<n>`，以及 `_yes_playlist(...)` 的判断，决定返回：

- 单视频 entry
- 还是多 entry playlist

## 14. 一条完整请求链路示意

标准匿名原生视频 Tweet，大致是这样：

```text
Tweet URL
  -> YoutubeDL.extract_info
  -> TwitterIE._real_extract
  -> guest/activate.json
  -> GraphQL TweetResultByRestId
  -> _graphql_to_legacy
  -> extended_entities.media[].video_info.variants
  -> MP4 / m3u8 formats
  -> YoutubeDL.process_video_result
  -> 选出最佳 format
  -> get_suitable_downloader
     -> MP4: HttpFD
     -> HLS: HlsFD 或 FFmpegFD
  -> 文件写入本地
```

如果是 card/广告/品牌视频，则会变成：

```text
Tweet URL
  -> TwitterIE._real_extract
  -> Tweet JSON
  -> card.binding_values
  -> VMAP URL
  -> VMAP XML
  -> videoVariant / MediaFile
  -> MP4 / m3u8 formats
  -> YoutubeDL 选格式
  -> downloader 下载
```

## 15. 你如果要改源码，应该盯哪几层

如果目标是“支持更多 Twitter 视频场景”或“修修下载失败”，可以按层看：

### 15.1 extractor 层

关注：

- `TwitterIE._extract_status`
- `TwitterIE._graphql_to_legacy`
- `TwitterIE._real_extract`
- `TwitterBaseIE._extract_variant_formats`
- `TwitterBaseIE._extract_formats_from_vmap_url`

这里决定：

- 请求哪个接口
- JSON 怎么归一化
- 从哪里取视频 URL

### 15.2 format 选择层

关注：

- `YoutubeDL.process_video_result`

这里决定：

- 格式是否完整
- 排序规则
- 为什么选 HLS 而不是 MP4

### 15.3 下载器层

关注：

- `get_suitable_downloader`
- `HlsFD`
- `FFmpegFD`
- `FragmentFD`

这里决定：

- 具体是原生下载、ffmpeg 代理、还是分片下载
- DRM / live / AES 等情况如何处理

## 16. 最终抽象

把 `yt-dlp` 下载 Twitter/X 视频抽象成一句工程话：

```text
TwitterIE 负责把 Tweet 解析成标准 info_dict，
其中最重要的是 formats；
YoutubeDL 负责从 formats 里选一个可下、最优的结果；
downloader 负责按协议把它真正搬到本地。
```

所以它的核心不是“下载器很懂 Twitter”，而是：

- Twitter extractor 很懂 Tweet 数据结构
- 通用 downloader 很懂媒体协议

这就是整条链路能稳定工作的根本原因。
