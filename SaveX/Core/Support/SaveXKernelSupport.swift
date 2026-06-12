import Foundation

typealias JSONDictionary = [String: Any]
typealias JSONArray = [Any]

enum SaveXKernelCompatibility {
    static let ytDLPVersion = "2026.06.09"
    static let twitterAPIBase = URL(string: "https://api.x.com/1.1/")!
    static let twitterGraphQLAPIBase = URL(string: "https://x.com/i/api/graphql/")!
    static let twitterGraphQLEndpoint = "2ICDjqPd81tulZcYrtpTuQ/TweetResultByRestId"
    static let twitterBearerToken = "AAAAAAAAAAAAAAAAAAAAANRILgAAAAAAnNwIzUejRCOuH5E6I8xnZz4puTs%3D1Zv7ttfk8LF81IUq16cHjhLTvJu4FA33AGWWjCpTnA"
    static let twitterLegacyBearerToken = "AAAAAAAAAAAAAAAAAAAAAIK1zgAAAAAA2tUWuhGZ2JceoId5GwYWU5GspY4%3DUq7gzFoCZs1QfwGoVdvSac3IniczZEYXIcDyumCauIXpcAPorE"
}

enum TwitterAPISelection: String, CaseIterable, Sendable {
    case graphql
    case legacy
    case syndication
}

enum SaveXError: LocalizedError, Sendable {
    case invalidURL(String)
    case unsupportedHost(String)
    case tweetUnavailable(String)
    case loginRequired(String)
    case apiError(String, statusCode: Int?)
    case invalidResponse(String)
    case noVideoFound
    case noFormatsFound
    case videoUnavailable(index: Int)
    case mediaNotVideo(index: Int)
    case unsupportedCard(String)
    case unsupportedHLS(String)
    case hlsExportFailed(String)
    case xmlParseFailed(String)
    case notImplemented(String)
    case photoLibraryAccessDenied
    case photoLibrarySaveFailed
    case downloadPaused

    var errorDescription: String? {
        switch self {
        case let .invalidURL(value):
            return "Invalid tweet URL: \(value)"
        case let .unsupportedHost(host):
            return "Unsupported host: \(host)"
        case let .tweetUnavailable(reason):
            return "Tweet unavailable: \(reason)"
        case let .loginRequired(reason):
            return "Login required: \(reason)"
        case let .apiError(message, statusCode):
            if let statusCode {
                return "Twitter API error (\(statusCode)): \(message)"
            }
            return "Twitter API error: \(message)"
        case let .invalidResponse(reason):
            return "Invalid response: \(reason)"
        case .noVideoFound:
            return "No video could be found in this tweet"
        case .noFormatsFound:
            return "No downloadable formats were found"
        case let .videoUnavailable(index):
            return "Video #\(index) is unavailable"
        case let .mediaNotVideo(index):
            return "Media #\(index) is not a video"
        case let .unsupportedCard(name):
            return "Unsupported Twitter card: \(name)"
        case let .unsupportedHLS(reason):
            return "Unsupported HLS playlist: \(reason)"
        case let .hlsExportFailed(reason):
            return "HLS MP4 export failed: \(reason)"
        case let .xmlParseFailed(reason):
            return "VMAP parse failed: \(reason)"
        case let .notImplemented(reason):
            return "Not implemented: \(reason)"
        case .photoLibraryAccessDenied:
            return "Photo library add access was denied"
        case .photoLibrarySaveFailed:
            return "The video could not be saved to Photos"
        case .downloadPaused:
            return "Download paused"
        }
    }
}

func jsonDictionary(_ value: Any?) -> JSONDictionary? {
    value as? JSONDictionary
}

func jsonArray(_ value: Any?) -> JSONArray? {
    value as? JSONArray
}

func jsonString(_ value: Any?) -> String? {
    switch value {
    case let string as String:
        return string
    case let number as NSNumber:
        return number.stringValue
    default:
        return nil
    }
}

func jsonInt(_ value: Any?) -> Int? {
    switch value {
    case let int as Int:
        return int
    case let number as NSNumber:
        return number.intValue
    case let string as String:
        return Int(string)
    default:
        return nil
    }
}

func jsonDouble(_ value: Any?) -> Double? {
    switch value {
    case let double as Double:
        return double
    case let float as Float:
        return Double(float)
    case let int as Int:
        return Double(int)
    case let number as NSNumber:
        return number.doubleValue
    case let string as String:
        return Double(string)
    default:
        return nil
    }
}

func jsonBool(_ value: Any?) -> Bool? {
    switch value {
    case let bool as Bool:
        return bool
    case let number as NSNumber:
        return number.boolValue
    case let string as String:
        return Bool(string)
    default:
        return nil
    }
}

func jsonValue(in root: JSONDictionary, path: [String]) -> Any? {
    var current: Any? = root
    for segment in path {
        current = jsonDictionary(current)?[segment]
    }
    return current
}

func updateURLQuery(_ url: URL, name: String) -> URL? {
    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
        return nil
    }
    components.queryItems = [URLQueryItem(name: "name", value: name)]
    return components.url
}

func cleanedTweetText(_ text: String) -> String {
    text.replacingOccurrences(of: "\n", with: " ")
}

func cleanedTitle(_ text: String, limit: Int = 72) -> String {
    let stripped = text.replacingOccurrences(
        of: #"\s+(https?://[^ ]+)"#,
        with: "",
        options: .regularExpression
    )
    guard stripped.count > limit else {
        return stripped
    }
    return String(stripped.prefix(limit - 3)) + "..."
}

func parseDimensions(from url: URL) -> (width: Int, height: Int)? {
    let pattern = #"/(\d+)x(\d+)/"#
    let source = url.absoluteString
    guard let expression = try? NSRegularExpression(pattern: pattern),
          let match = expression.firstMatch(in: source, range: NSRange(source.startIndex..<source.endIndex, in: source)),
          let widthRange = Range(match.range(at: 1), in: source),
          let heightRange = Range(match.range(at: 2), in: source),
          let width = Int(source[widthRange]),
          let height = Int(source[heightRange]) else {
        return nil
    }
    return (width, height)
}

func mediaIDFromVariantURL(_ url: String) -> String? {
    let pattern = #"_video/(\d+)/"#
    guard let expression = try? NSRegularExpression(pattern: pattern),
          let match = expression.firstMatch(in: url, range: NSRange(url.startIndex..<url.endIndex, in: url)),
          let range = Range(match.range(at: 1), in: url) else {
        return nil
    }
    return String(url[range])
}

func jsRadix36String(_ value: Double, fractionalDigits: Int = 12) -> String {
    let alphabet = Array("0123456789abcdefghijklmnopqrstuvwxyz")
    let integerPart = Int(value.rounded(.down))
    var whole = integerPart
    var integerDigits: [Character] = []

    repeat {
        integerDigits.append(alphabet[whole % 36])
        whole /= 36
    } while whole > 0

    let integerString = String(integerDigits.reversed())
    var fraction = value - Double(integerPart)
    guard fraction > 0 else {
        return integerString
    }

    var fractionDigits = ""
    for _ in 0..<fractionalDigits {
        fraction *= 36
        let digit = Int(fraction.rounded(.down))
        fractionDigits.append(alphabet[digit])
        fraction -= Double(digit)
        if fraction == 0 {
            break
        }
    }

    return integerString + "." + fractionDigits
}

func mergedDictionaries(_ base: JSONDictionary, _ updates: JSONDictionary) -> JSONDictionary {
    var copy = base
    for (key, value) in updates {
        copy[key] = value
    }
    return copy
}
