import Foundation

enum DownloadExecutionPlan: Sendable {
    case singleFile(MediaFormat)
    case hls(MediaFormat)
}

struct DownloadedAsset: Codable, Sendable {
    let sourceTweetID: String
    let format: MediaFormat
    let localFileURL: URL
    let fileSize: Int64
    let responseMimeType: String?
}

struct DownloadPlanner {
    func makePlan(for format: MediaFormat) throws -> DownloadExecutionPlan {
        if format.isHLS {
            return .hls(format)
        }
        guard format.transport == .http || format.transport == .https else {
            throw SaveXError.notImplemented("Unsupported transport: \(format.transport.rawValue)")
        }
        return .singleFile(format)
    }
}

enum DownloadFileNaming {
    static func uniqueDestinationURL(
        in directory: URL,
        baseName: String,
        ext: String,
        fileExists: (String) -> Bool
    ) -> URL {
        var candidate = directory.appendingPathComponent("\(baseName).\(ext)", isDirectory: false)
        var index = 2
        while fileExists(candidate.path) {
            candidate = directory.appendingPathComponent("\(baseName)-\(index).\(ext)", isDirectory: false)
            index += 1
        }
        return candidate
    }

    static func makeFilename(tweetID: String, title: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(.whitespaces).union(CharacterSet(charactersIn: "-_"))
        let sanitizedScalars = title.unicodeScalars.map { allowed.contains($0) ? Character($0) : Character(" ") }
        let sanitized = String(sanitizedScalars)
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = sanitized.isEmpty ? "tweet-\(tweetID)" : sanitized
        return cleanedTitle(prefix, limit: 60).replacingOccurrences(of: " ", with: "-")
    }

    static func fileExtension(for format: MediaFormat, mimeType: String?) -> String {
        switch format.container {
        case .mp4:
            return "mp4"
        case .m3u8:
            return "m3u8"
        case .ts:
            return "ts"
        case .unknown:
            if let mimeType, mimeType.contains("mp4") {
                return "mp4"
            }
            if let ext = format.url.pathExtension.split(separator: "?").first, !ext.isEmpty {
                return String(ext)
            }
            return "bin"
        }
    }
}
