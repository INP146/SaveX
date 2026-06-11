import Foundation

struct TwitterMediaExtractor {
    private let cardExtractor = CardMediaExtractor()

    func extractEntries(
        from status: JSONDictionary,
        request: TweetRequest,
        loadVMAP: @escaping @Sendable (URL) async throws -> Data = { _ in
            throw SaveXError.notImplemented("VMAP loader is not configured")
        }
    ) async throws -> [TweetMediaInfo] {
        let base = makeBaseInfo(status: status, request: request)
        let videos = collectVideoMedia(from: status)

        var entries = videos.map { makeEntry(from: $0, base: base) }
        entries.append(contentsOf: try await cardExtractor.extractEntries(
            from: jsonDictionary(status["card"]),
            tweetID: request.tweetID,
            base: base,
                variantExtractor: { variant, videoID in
                    extractFormats(from: variant, tweetID: videoID)
                },
            loadVMAP: loadVMAP
        ))

        if entries.isEmpty {
            throw SaveXError.noVideoFound
        }

        if let selectedMediaIndex = request.selectedMediaIndex {
            guard selectedMediaIndex > 0, selectedMediaIndex <= entries.count else {
                throw SaveXError.videoUnavailable(index: selectedMediaIndex)
            }
            return [entries[selectedMediaIndex - 1]]
        }

        return entries.enumerated().map { index, entry in
            guard entries.count > 1 else {
                return entry
            }
            return TweetMediaInfo(
                id: entry.id,
                displayID: entry.displayID,
                title: "\(entry.title) #\(index + 1)",
                description: entry.description,
                uploader: entry.uploader,
                uploaderID: entry.uploaderID,
                uploaderURL: entry.uploaderURL,
                channelID: entry.channelID,
                timestamp: entry.timestamp,
                viewCount: entry.viewCount,
                likeCount: entry.likeCount,
                repostCount: entry.repostCount,
                commentCount: entry.commentCount,
                ageLimit: entry.ageLimit,
                tags: entry.tags,
                duration: entry.duration,
                formats: entry.formats,
                subtitles: entry.subtitles,
                thumbnails: entry.thumbnails,
                externalReferenceURL: entry.externalReferenceURL,
                formatSortFields: entry.formatSortFields
            )
        }
    }

    func extractFormats(from variant: JSONDictionary, tweetID: String) -> [MediaFormat] {
        guard let urlString = jsonString(variant["url"]), let url = URL(string: urlString) else {
            return []
        }

        if urlString.contains(".m3u8") {
            return [
                MediaFormat(
                    id: "\(tweetID)-hls-\(urlString.hashValue)",
                    url: url,
                    formatID: "hls",
                    transport: .m3u8Native,
                    container: .mp4,
                    bitrate: nil,
                    width: parseDimensions(from: url)?.width,
                    height: parseDimensions(from: url)?.height,
                    fileSizeApprox: nil,
                    videoCodec: nil,
                    audioCodec: nil,
                    httpHeaders: [:]
                )
            ]
        }

        let bitrate = jsonInt(variant["bitrate"]) ?? jsonInt(variant["bit_rate"]).map { $0 / 1000 }
        let dimensions = parseDimensions(from: url)
        return [
            MediaFormat(
                id: "\(tweetID)-http-\(urlString.hashValue)",
                url: url,
                formatID: bitrate.map { "http-\($0)" } ?? "http",
                transport: url.scheme == "https" ? .https : .http,
                container: .mp4,
                bitrate: bitrate,
                width: dimensions?.width,
                height: dimensions?.height,
                fileSizeApprox: nil,
                videoCodec: nil,
                audioCodec: nil,
                httpHeaders: [:]
            )
        ]
    }

    private func makeBaseInfo(status: JSONDictionary, request: TweetRequest) -> TweetMediaInfo {
        let description = cleanedTweetText(
            jsonString(status["full_text"]) ??
            jsonString(status["text"]) ??
            ""
        )

        let uploader = jsonString(jsonValue(in: status, path: ["user", "name"]))
        let uploaderID = jsonString(jsonValue(in: status, path: ["user", "screen_name"]))
        let titleCore = cleanedTitle(description)
        let title = uploader.map { "\($0) - \(titleCore)" } ?? titleCore

        return TweetMediaInfo(
            id: request.tweetID,
            displayID: request.displayID,
            title: title,
            description: description,
            uploader: uploader,
            uploaderID: uploaderID,
            uploaderURL: uploaderID.flatMap { URL(string: "https://twitter.com/\($0)") },
            channelID: jsonString(status["user_id_str"]) ?? jsonString(jsonValue(in: status, path: ["user", "id_str"])),
            timestamp: twitterDate(jsonString(status["created_at"])),
            viewCount: jsonInt(status["view_count"]),
            likeCount: jsonInt(status["favorite_count"]),
            repostCount: jsonInt(status["retweet_count"]),
            commentCount: jsonInt(status["reply_count"]),
            ageLimit: jsonBool(status["possibly_sensitive"]) == true ? 18 : 0,
            tags: extractTags(status),
            duration: nil,
            formats: [],
            subtitles: [],
            thumbnails: [],
            externalReferenceURL: nil,
            formatSortFields: [.resolution, .preferM3U8, .bitrate, .fileSize]
        )
    }

    private func makeEntry(from media: JSONDictionary, base: TweetMediaInfo) -> TweetMediaInfo {
        let mediaID = jsonString(media["id_str"]) ?? jsonString(media["id"]) ?? base.id
        let extractedFormats = (jsonArray(jsonValue(in: media, path: ["video_info", "variants"])) ?? [])
            .compactMap(jsonDictionary)
            .flatMap { extractFormats(from: $0, tweetID: base.displayID) }

        let formats = FormatNormalizer().normalize(
            extractedFormats
        )

        return TweetMediaInfo(
            id: mediaID,
            displayID: base.displayID,
            title: base.title,
            description: base.description,
            uploader: base.uploader,
            uploaderID: base.uploaderID,
            uploaderURL: base.uploaderURL,
            channelID: base.channelID,
            timestamp: base.timestamp,
            viewCount: base.viewCount,
            likeCount: base.likeCount,
            repostCount: base.repostCount,
            commentCount: base.commentCount,
            ageLimit: base.ageLimit,
            tags: base.tags,
            duration: jsonDouble(jsonValue(in: media, path: ["video_info", "duration_millis"])).map { $0 / 1000 },
            formats: formats,
            subtitles: [],
            thumbnails: thumbnails(from: media),
            externalReferenceURL: nil,
            formatSortFields: [.resolution, .preferM3U8, .bitrate, .fileSize]
        )
    }

    private func collectVideoMedia(from status: JSONDictionary) -> [JSONDictionary] {
        let containers = [status, jsonDictionary(status["quoted_status"])]
        return containers
            .compactMap { $0 }
            .flatMap { container -> [JSONDictionary] in
                let media = jsonArray(jsonValue(in: container, path: ["extended_entities", "media"])) ?? []
                return media.compactMap(jsonDictionary).filter {
                    jsonString($0["type"]) != "photo"
                }
            }
    }

    private func thumbnails(from media: JSONDictionary) -> [MediaThumbnail] {
        guard let mediaURLString = jsonString(media["media_url_https"]) ?? jsonString(media["media_url"]),
              let mediaURL = URL(string: mediaURLString) else {
            return []
        }

        var thumbnails: [MediaThumbnail] = []
        let sizes = jsonDictionary(media["sizes"]) ?? [:]
        for (name, value) in sizes {
            guard let size = jsonDictionary(value),
                  let url = updateURLQuery(mediaURL, name: name) else {
                continue
            }
            thumbnails.append(
                MediaThumbnail(
                    id: name,
                    url: url,
                    width: jsonInt(size["w"]) ?? jsonInt(size["width"]),
                    height: jsonInt(size["h"]) ?? jsonInt(size["height"])
                )
            )
        }

        if let originalInfo = jsonDictionary(media["original_info"]),
           let url = updateURLQuery(mediaURL, name: "orig") {
            thumbnails.append(
                MediaThumbnail(
                    id: "orig",
                    url: url,
                    width: jsonInt(originalInfo["w"]) ?? jsonInt(originalInfo["width"]),
                    height: jsonInt(originalInfo["h"]) ?? jsonInt(originalInfo["height"])
                )
            )
        }

        return thumbnails
    }

    private func extractTags(_ status: JSONDictionary) -> [String] {
        let hashtags = jsonArray(jsonValue(in: status, path: ["entities", "hashtags"])) ?? []
        return hashtags
            .compactMap(jsonDictionary)
            .compactMap { jsonString($0["text"]) }
    }

    private func twitterDate(_ string: String?) -> Date? {
        guard let string else {
            return nil
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE MMM dd HH:mm:ss Z yyyy"
        return formatter.date(from: string)
    }
}

struct CardMediaExtractor {
    struct CardExtraction {
        let id: String
        let duration: Double?
        let formats: [MediaFormat]
        let thumbnails: [MediaThumbnail]
        let externalReferenceURL: URL?
    }

    func extractEntries(
        from card: JSONDictionary?,
        tweetID: String,
        base: TweetMediaInfo,
        variantExtractor: (JSONDictionary, String) -> [MediaFormat],
        loadVMAP: @escaping @Sendable (URL) async throws -> Data
    ) async throws -> [TweetMediaInfo] {
        guard let card else {
            return []
        }

        let cardName = (jsonString(card["name"]) ?? "").split(separator: ":").last.map(String.init) ?? ""
        let bindingValues = jsonDictionary(card["binding_values"]) ?? [:]

        switch cardName {
        case "player":
            guard let url = bindingURL("player_url", in: bindingValues) else { return [] }
            return [makeEntry(base: base, id: tweetID, duration: nil, formats: [], thumbnails: [], externalReferenceURL: url)]
        case "summary":
            guard let url = bindingURL("card_url", in: bindingValues) else { return [] }
            return [makeEntry(base: base, id: tweetID, duration: nil, formats: [], thumbnails: [], externalReferenceURL: url)]
        case "periscope_broadcast", "broadcast", "audiospace":
            let key: String = switch cardName {
            case "periscope_broadcast": "url"
            case "broadcast": "broadcast_url"
            default: "id"
            }
            if let url = bindingURL(key, in: bindingValues) {
                return [makeEntry(base: base, id: tweetID, duration: nil, formats: [], thumbnails: [], externalReferenceURL: url)]
            }
            if cardName == "audiospace", let id = bindingString("id", in: bindingValues), let url = URL(string: "https://twitter.com/i/spaces/\(id)") {
                return [makeEntry(base: base, id: tweetID, duration: nil, formats: [], thumbnails: [], externalReferenceURL: url)]
            }
            return []
        case "unified_card":
            guard let raw = bindingString("unified_card", in: bindingValues),
                  let data = raw.data(using: .utf8),
                  let object = try JSONSerialization.jsonObject(with: data) as? JSONDictionary else {
                return []
            }
            let mediaEntities = jsonDictionary(object["media_entities"]) ?? [:]
            return mediaEntities.values
                .compactMap(jsonDictionary)
                .filter { jsonString($0["type"]) == "video" }
                .map { entity in
                    let formats = (jsonArray(jsonValue(in: entity, path: ["video_info", "variants"])) ?? [])
                        .compactMap(jsonDictionary)
                        .flatMap { variantExtractor($0, tweetID) }
                    return makeEntry(
                        base: base,
                        id: jsonString(entity["id_str"]) ?? tweetID,
                        duration: jsonDouble(jsonValue(in: entity, path: ["video_info", "duration_millis"])).map { $0 / 1000 },
                        formats: FormatNormalizer().normalize(formats),
                        thumbnails: [],
                        externalReferenceURL: nil
                    )
                }
        default:
            let isAmplify = cardName == "amplify"
            let vmapURL = isAmplify
                ? bindingURL("amplify_url_vmap", in: bindingValues)
                : bindingURL("player_stream_url", in: bindingValues)
            guard let vmapURL else {
                return []
            }
            let vmapData = try await loadVMAP(vmapURL)
            let manifest = try VMapParser().parse(vmapData)
            let urls = Set(manifest.variantURLs.map(\.absoluteString))
            var formats = manifest.variantURLs.flatMap { variantExtractor(["url": $0.absoluteString], tweetID) }
            if let mediaFileURL = manifest.mediaFileURL, !urls.contains(mediaFileURL.absoluteString) {
                formats.append(contentsOf: variantExtractor(["url": mediaFileURL.absoluteString], tweetID))
            }
            return [makeEntry(
                base: base,
                id: bindingString("\(cardName)_content_id", in: bindingValues)
                    ?? bindingString("player_content_id", in: bindingValues)
                    ?? tweetID,
                duration: jsonDouble(bindingValue("content_duration_seconds", in: bindingValues)),
                formats: FormatNormalizer().normalize(formats),
                thumbnails: thumbnails(from: bindingValues),
                externalReferenceURL: nil
            )]
        }
    }

    private func makeEntry(
        base: TweetMediaInfo,
        id: String,
        duration: Double?,
        formats: [MediaFormat],
        thumbnails: [MediaThumbnail],
        externalReferenceURL: URL?
    ) -> TweetMediaInfo {
        TweetMediaInfo(
            id: id,
            displayID: base.displayID,
            title: base.title,
            description: base.description,
            uploader: base.uploader,
            uploaderID: base.uploaderID,
            uploaderURL: base.uploaderURL,
            channelID: base.channelID,
            timestamp: base.timestamp,
            viewCount: base.viewCount,
            likeCount: base.likeCount,
            repostCount: base.repostCount,
            commentCount: base.commentCount,
            ageLimit: base.ageLimit,
            tags: base.tags,
            duration: duration,
            formats: formats,
            subtitles: [],
            thumbnails: thumbnails,
            externalReferenceURL: externalReferenceURL,
            formatSortFields: [.resolution, .preferM3U8, .bitrate, .fileSize]
        )
    }

    private func bindingValue(_ key: String, in bindingValues: JSONDictionary) -> Any? {
        guard let raw = jsonDictionary(bindingValues[key]) else {
            return bindingValues[key]
        }
        if let type = jsonString(raw["type"])?.lowercased(),
           let value = raw["\(type)_value"] {
            return value
        }
        return raw["string_value"] ?? raw["image_value"] ?? raw["boolean_value"] ?? raw["scribe_key"] ?? raw
    }

    private func bindingString(_ key: String, in bindingValues: JSONDictionary) -> String? {
        jsonString(bindingValue(key, in: bindingValues))
    }

    private func bindingURL(_ key: String, in bindingValues: JSONDictionary) -> URL? {
        if let string = bindingString(key, in: bindingValues), let url = URL(string: string) {
            return url
        }
        return nil
    }

    private func thumbnails(from bindingValues: JSONDictionary) -> [MediaThumbnail] {
        let suffixes = ["_small", "", "_large", "_x_large", "_original"]
        return suffixes.compactMap { suffix in
            guard let image = jsonDictionary(bindingValue("player_image\(suffix)", in: bindingValues)),
                  let string = jsonString(image["url"]),
                  !string.contains("/player-placeholder"),
                  let url = URL(string: string) else {
                return nil
            }
            let id = suffix.isEmpty ? "medium" : String(suffix.dropFirst())
            return MediaThumbnail(
                id: id,
                url: url,
                width: jsonInt(image["width"]),
                height: jsonInt(image["height"])
            )
        }
    }
}

struct VMapManifest: Sendable {
    let variantURLs: [URL]
    let mediaFileURL: URL?
}

struct VMapParser {
    func parse(_ data: Data) throws -> VMapManifest {
        let delegate = VMapXMLDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else {
            throw SaveXError.xmlParseFailed(parser.parserError?.localizedDescription ?? "Unknown parser failure")
        }
        return VMapManifest(variantURLs: delegate.variantURLs, mediaFileURL: delegate.mediaFileURL)
    }
}

private final class VMapXMLDelegate: NSObject, XMLParserDelegate {
    private var currentElement = ""
    private var mediaFileBuffer = ""

    var variantURLs: [URL] = []
    var mediaFileURL: URL?

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        currentElement = elementName
        if elementName == "videoVariant",
           let raw = attributeDict["url"]?.removingPercentEncoding ?? attributeDict["url"],
           let url = URL(string: raw) {
            variantURLs.append(url)
        } else if elementName == "MediaFile" {
            mediaFileBuffer = ""
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if currentElement == "MediaFile" {
            mediaFileBuffer.append(string)
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        if elementName == "MediaFile" {
            let trimmed = mediaFileBuffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if let url = URL(string: trimmed), !trimmed.isEmpty {
                mediaFileURL = url
            }
        }
        currentElement = ""
    }
}

struct FormatNormalizer {
    func normalize(_ formats: [MediaFormat]) -> [MediaFormat] {
        var deduped: [String: MediaFormat] = [:]
        for format in formats {
            let key = "\(format.url.absoluteString)|\(format.formatID)"
            if let existing = deduped[key] {
                deduped[key] = betterFormat(existing, format)
            } else {
                deduped[key] = format
            }
        }
        return Array(deduped.values)
    }

    private func betterFormat(_ lhs: MediaFormat, _ rhs: MediaFormat) -> MediaFormat {
        let lhsScore = metadataScore(lhs)
        let rhsScore = metadataScore(rhs)
        return rhsScore > lhsScore ? rhs : lhs
    }

    private func metadataScore(_ format: MediaFormat) -> Int {
        var score = 0
        if format.width != nil { score += 2 }
        if format.height != nil { score += 2 }
        if format.bitrate != nil { score += 1 }
        if format.fileSizeApprox != nil { score += 1 }
        if format.videoCodec != nil { score += 1 }
        if format.audioCodec != nil { score += 1 }
        return score
    }
}
