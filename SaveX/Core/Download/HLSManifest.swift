import Foundation

struct HLSVariant: Sendable {
    let url: URL
    let bandwidth: Int?
    let averageBandwidth: Int?
    let codecs: String?
    let width: Int?
    let height: Int?
}

struct HLSSegment: Sendable {
    let url: URL
    let duration: Double?
    let title: String?
}

struct HLSMediaPlaylist: Sendable {
    let targetDuration: Double?
    let segments: [HLSSegment]
    let hasEndList: Bool
}

enum HLSManifest: Sendable {
    case master(variants: [HLSVariant])
    case media(HLSMediaPlaylist)
}

struct HLSManifestParser {
    func parse(_ data: Data, baseURL: URL) throws -> HLSManifest {
        guard let source = String(data: data, encoding: .utf8) else {
            throw SaveXError.invalidResponse("HLS manifest was not UTF-8 text")
        }
        return try parse(source, baseURL: baseURL)
    }

    func parse(_ source: String, baseURL: URL) throws -> HLSManifest {
        let lines = source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard lines.first == "#EXTM3U" else {
            throw SaveXError.invalidResponse("HLS manifest is missing #EXTM3U")
        }

        try rejectUnsupportedLowLatencyTags(in: lines)

        let hasStreamInf = lines.contains { $0.hasPrefix("#EXT-X-STREAM-INF:") }
        return hasStreamInf
            ? try parseMaster(lines: lines, baseURL: baseURL)
            : try parseMedia(lines: lines, baseURL: baseURL)
    }

    private func parseMaster(lines: [String], baseURL: URL) throws -> HLSManifest {
        var variants: [HLSVariant] = []
        var pendingAttributes: [String: String]?

        for line in lines.dropFirst() {
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                pendingAttributes = parseAttributes(String(line.dropFirst("#EXT-X-STREAM-INF:".count)))
                continue
            }

            guard !line.hasPrefix("#"), let attributes = pendingAttributes else {
                continue
            }

            variants.append(HLSVariant(
                url: try resolveURL(line, relativeTo: baseURL),
                bandwidth: attributes["BANDWIDTH"].flatMap(Int.init),
                averageBandwidth: attributes["AVERAGE-BANDWIDTH"].flatMap(Int.init),
                codecs: attributes["CODECS"],
                width: parseResolution(attributes["RESOLUTION"])?.width,
                height: parseResolution(attributes["RESOLUTION"])?.height
            ))
            pendingAttributes = nil
        }

        guard !variants.isEmpty else {
            throw SaveXError.invalidResponse("HLS master playlist contained no variants")
        }
        return .master(variants: variants)
    }

    private func parseMedia(lines: [String], baseURL: URL) throws -> HLSManifest {
        var segments: [HLSSegment] = []
        var pendingDuration: Double?
        var pendingTitle: String?
        var targetDuration: Double?
        var hasEndList = false

        for line in lines.dropFirst() {
            if line.hasPrefix("#EXT-X-KEY:") {
                let attributes = parseAttributes(String(line.dropFirst("#EXT-X-KEY:".count)))
                let method = attributes["METHOD"]?.uppercased() ?? ""
                if method != "NONE" {
                    throw SaveXError.unsupportedHLS("Encrypted media segments are not supported yet")
                }
                continue
            }

            if line.hasPrefix("#EXT-X-MAP:") {
                throw SaveXError.unsupportedHLS("fMP4 HLS playlists with EXT-X-MAP are not supported yet")
            }

            if line.hasPrefix("#EXT-X-BYTERANGE:") {
                throw SaveXError.unsupportedHLS("Byte-range HLS playlists are not supported yet")
            }

            if line == "#EXT-X-DISCONTINUITY" {
                throw SaveXError.unsupportedHLS("HLS discontinuities are not supported yet")
            }

            if line.hasPrefix("#EXT-X-TARGETDURATION:") {
                targetDuration = Double(line.dropFirst("#EXT-X-TARGETDURATION:".count))
                continue
            }

            if line.hasPrefix("#EXTINF:") {
                let payload = String(line.dropFirst("#EXTINF:".count))
                let pieces = payload.split(separator: ",", maxSplits: 1, omittingEmptySubsequences: false)
                pendingDuration = pieces.first.flatMap { Double($0) }
                pendingTitle = pieces.count > 1 ? String(pieces[1]) : nil
                continue
            }

            if line == "#EXT-X-ENDLIST" {
                hasEndList = true
                continue
            }

            guard !line.hasPrefix("#") else {
                continue
            }

            segments.append(HLSSegment(
                url: try resolveURL(line, relativeTo: baseURL),
                duration: pendingDuration,
                title: pendingTitle
            ))
            pendingDuration = nil
            pendingTitle = nil
        }

        guard !segments.isEmpty else {
            throw SaveXError.invalidResponse("HLS media playlist contained no segments")
        }
        guard hasEndList else {
            throw SaveXError.unsupportedHLS("Live playlists are not supported yet")
        }

        return .media(HLSMediaPlaylist(
            targetDuration: targetDuration,
            segments: segments,
            hasEndList: hasEndList
        ))
    }

    private func rejectUnsupportedLowLatencyTags(in lines: [String]) throws {
        let unsupportedTags = [
            "#EXT-X-PART",
            "#EXT-X-SERVER-CONTROL",
            "#EXT-X-PRELOAD-HINT",
        ]
        if let tag = lines.first(where: { line in unsupportedTags.contains { line.hasPrefix($0) } }) {
            throw SaveXError.unsupportedHLS("Low-latency tag \(tag.split(separator: ":").first ?? Substring(tag)) is not supported yet")
        }
    }

    private func parseAttributes(_ string: String) -> [String: String] {
        var attributes: [String: String] = [:]
        var key = ""
        var value = ""
        var readingKey = true
        var insideQuotes = false

        func commit() {
            let normalizedKey = key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedKey.isEmpty else {
                key = ""
                value = ""
                readingKey = true
                return
            }
            attributes[normalizedKey] = value.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            key = ""
            value = ""
            readingKey = true
        }

        for character in string {
            if readingKey {
                if character == "=" {
                    readingKey = false
                } else {
                    key.append(character)
                }
            } else {
                if character == "\"" {
                    insideQuotes.toggle()
                    value.append(character)
                } else if character == "," && !insideQuotes {
                    commit()
                } else {
                    value.append(character)
                }
            }
        }
        commit()
        return attributes
    }

    private func parseResolution(_ value: String?) -> (width: Int, height: Int)? {
        guard let value else {
            return nil
        }
        let pieces = value.lowercased().split(separator: "x", maxSplits: 1)
        guard pieces.count == 2,
              let width = Int(pieces[0]),
              let height = Int(pieces[1]) else {
            return nil
        }
        return (width, height)
    }

    private func resolveURL(_ value: String, relativeTo baseURL: URL) throws -> URL {
        guard let url = URL(string: value, relativeTo: baseURL)?.absoluteURL else {
            throw SaveXError.invalidURL(value)
        }
        return url
    }
}

actor HLSManifestLoader {
    private let session: URLSession
    private let parser: HLSManifestParser

    init(session: URLSession = .shared, parser: HLSManifestParser = HLSManifestParser()) {
        self.session = session
        self.parser = parser
    }

    func load(url: URL, headers: [String: String] = [:]) async throws -> HLSManifest {
        var request = URLRequest(url: url)
        for (header, value) in headers {
            request.setValue(value, forHTTPHeaderField: header)
        }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw SaveXError.invalidResponse("HLS manifest response was not HTTP")
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw SaveXError.apiError(
                HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode),
                statusCode: httpResponse.statusCode
            )
        }
        return try parser.parse(data, baseURL: url)
    }
}
