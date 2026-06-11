import Foundation

struct TwitterAPIConfiguration {
    struct GraphQLQuery: Encodable {
        let variables: [String: GraphQLValue]
        let features: [String: Bool]
        let fieldToggles: [String: Bool]
    }

    enum GraphQLValue: Encodable {
        case string(String)
        case bool(Bool)

        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case let .string(value):
                try container.encode(value)
            case let .bool(value):
                try container.encode(value)
            }
        }
    }

    static func buildGraphQLQuery(tweetID: String) -> GraphQLQuery {
        GraphQLQuery(
            variables: [
                "tweetId": .string(tweetID),
                "withCommunity": .bool(false),
                "includePromotedContent": .bool(false),
                "withVoice": .bool(false),
            ],
            features: [
                "creator_subscriptions_tweet_preview_api_enabled": true,
                "tweetypie_unmention_optimization_enabled": true,
                "responsive_web_edit_tweet_api_enabled": true,
                "graphql_is_translatable_rweb_tweet_is_translatable_enabled": true,
                "view_counts_everywhere_api_enabled": true,
                "longform_notetweets_consumption_enabled": true,
                "responsive_web_twitter_article_tweet_consumption_enabled": false,
                "tweet_awards_web_tipping_enabled": false,
                "freedom_of_speech_not_reach_fetch_enabled": true,
                "standardized_nudges_misinfo": true,
                "tweet_with_visibility_results_prefer_gql_limited_actions_policy_enabled": true,
                "longform_notetweets_rich_text_read_enabled": true,
                "longform_notetweets_inline_media_enabled": true,
                "responsive_web_graphql_exclude_directive_enabled": true,
                "verified_phone_label_enabled": false,
                "responsive_web_media_download_video_enabled": false,
                "responsive_web_graphql_skip_user_profile_image_extensions_enabled": false,
                "responsive_web_graphql_timeline_navigation_enabled": true,
                "responsive_web_enhance_cards_enabled": false,
            ],
            fieldToggles: [
                "withArticleRichContentState": false,
            ]
        )
    }

    static func encodedGraphQLItems(tweetID: String) throws -> [URLQueryItem] {
        let query = buildGraphQLQuery(tweetID: tweetID)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return [
            URLQueryItem(name: "variables", value: String(data: try encoder.encode(query.variables), encoding: .utf8)),
            URLQueryItem(name: "features", value: String(data: try encoder.encode(query.features), encoding: .utf8)),
            URLQueryItem(name: "fieldToggles", value: String(data: try encoder.encode(query.fieldToggles), encoding: .utf8)),
        ]
    }
}

struct TwitterURLParser {
    private static let pattern = #"https?://(?:(?:www|m(?:obile)?)\.)?(?:(?:twitter|x)\.com|twitter3e4tixl4xyajtrzo62zg5vztmjuricljdp2c5kshju4avyoid\.onion)/(?:(?:i/web|[^/]+)/status|statuses)/(?<id>\d+)(?:/(?:video|photo)/(?<index>\d+))?"#
    private let expression = try! NSRegularExpression(pattern: Self.pattern, options: [.caseInsensitive])

    func parse(_ rawURL: String) throws -> TweetRequest {
        guard let url = URL(string: rawURL), let host = url.host else {
            throw SaveXError.invalidURL(rawURL)
        }
        guard host.contains("twitter.com") || host.contains("x.com") || host.contains(".onion") else {
            throw SaveXError.unsupportedHost(host)
        }

        let range = NSRange(rawURL.startIndex..<rawURL.endIndex, in: rawURL)
        guard let match = expression.firstMatch(in: rawURL, options: [], range: range) else {
            throw SaveXError.invalidURL(rawURL)
        }

        let tweetID = Range(match.range(withName: "id"), in: rawURL).map { String(rawURL[$0]) } ?? ""
        let selectedMediaIndex = Range(match.range(withName: "index"), in: rawURL).flatMap { Int(rawURL[$0]) }
        let screenName = url.pathComponents.dropFirst().first

        return TweetRequest(
            sourceURL: url,
            tweetID: tweetID,
            screenName: screenName == "i" ? nil : screenName,
            selectedMediaIndex: selectedMediaIndex
        )
    }
}

actor GuestTokenStore {
    private var cachedToken: String?

    func token(using loader: @Sendable () async throws -> String) async throws -> String {
        if let cachedToken {
            return cachedToken
        }
        let token = try await loader()
        cachedToken = token
        return token
    }

    func clear() {
        cachedToken = nil
    }
}

protocol TwitterAuthProviding: Sendable {
    var isLoggedIn: Bool { get }
    func baseHeaders(legacy: Bool) -> [String: String]
    func sessionHeaders() -> [String: String]
}

struct DefaultTwitterAuthProvider: TwitterAuthProviding {
    let authToken: String?
    let csrfToken: String?

    var isLoggedIn: Bool {
        !(authToken?.isEmpty ?? true)
    }

    func baseHeaders(legacy: Bool) -> [String: String] {
        let bearer = legacy && !isLoggedIn
            ? SaveXKernelCompatibility.twitterLegacyBearerToken
            : SaveXKernelCompatibility.twitterBearerToken

        var headers = [
            "Authorization": "Bearer \(bearer)"
        ]
        if let csrfToken, !csrfToken.isEmpty {
            headers["x-csrf-token"] = csrfToken
        }
        return headers
    }

    func sessionHeaders() -> [String: String] {
        guard isLoggedIn else {
            return [:]
        }
        return [
            "x-twitter-auth-type": "OAuth2Session",
            "x-twitter-client-language": "en",
            "x-twitter-active-user": "yes",
        ]
    }
}

struct TweetResolver {
    func normalizeGraphQLResult(_ data: JSONDictionary, tweetID: String) throws -> JSONDictionary {
        guard var result = jsonDictionary(jsonValue(in: data, path: ["tweetResult", "result"])) else {
            throw SaveXError.invalidResponse("Missing tweetResult.result for \(tweetID)")
        }

        let typename = jsonString(result["__typename"])

        if let tombstone = jsonDictionary(result["tombstone"]),
           let text = jsonString(jsonValue(in: tombstone, path: ["text", "text"])) {
            throw SaveXError.tweetUnavailable(text.replacingOccurrences(of: ". Learn more", with: ""))
        }

        if typename == "TweetUnavailable" {
            let reason = jsonString(result["reason"]) ?? "Requested tweet is unavailable"
            switch reason {
            case "NsfwLoggedOut", "NsfwViewerHasNoStatedAge":
                throw SaveXError.loginRequired("NSFW tweet requires authentication")
            case "Protected":
                throw SaveXError.loginRequired("You are not authorized to view this protected tweet")
            default:
                throw SaveXError.tweetUnavailable(reason)
            }
        }

        if typename == "TweetWithVisibilityResults",
           let tweet = jsonDictionary(result["tweet"]) {
            result = tweet
        }

        var status = jsonDictionary(result["legacy"]) ?? [:]
        status = mergedDictionaries(status, [
            "user": jsonValue(in: result, path: ["core", "user_results", "result", "legacy"]) as Any,
            "card": jsonValue(in: result, path: ["card", "legacy"]) as Any,
            "quoted_status": jsonValue(in: result, path: ["quoted_status_result", "result", "legacy"]) as Any,
            "retweeted_status": jsonValue(in: result, path: ["legacy", "retweeted_status_result", "result", "legacy"]) as Any,
        ].compactMapValues { $0 })

        if let retweetedStatus = jsonDictionary(status["retweeted_status"]) {
            var updatedRetweeted = retweetedStatus
            if let retweetedUser = jsonDictionary(jsonValue(
                in: result,
                path: ["legacy", "retweeted_status_result", "result", "core", "user_results", "result", "legacy"]
            )) {
                updatedRetweeted["user"] = retweetedUser
            }
            status["retweeted_status"] = updatedRetweeted
        }

        if let card = jsonDictionary(status["card"]),
           let bindingArray = jsonArray(card["binding_values"]) {
            var bindingValues: JSONDictionary = [:]
            for item in bindingArray {
                guard let binding = jsonDictionary(item), let key = jsonString(binding["key"]) else {
                    continue
                }
                bindingValues[key] = binding["value"]
            }
            var updatedCard = card
            updatedCard["binding_values"] = bindingValues
            status["card"] = updatedCard
        }

        if let viewCount = jsonInt(jsonValue(in: result, path: ["views", "count"])) {
            status["view_count"] = viewCount
        }

        return preferredStatus(from: status)
    }

    func normalizeSyndicationResult(_ status: JSONDictionary, tweetID: String) -> JSONDictionary {
        var normalized = status
        var media: [JSONDictionary] = []
        let statusContainers: [Any?] = [normalized, jsonDictionary(normalized["quoted_tweet"])]

        for container in statusContainers {
            guard let container = jsonDictionary(container),
                  let mediaDetails = jsonArray(container["mediaDetails"]) else {
                continue
            }
            for item in mediaDetails {
                guard var detail = jsonDictionary(item) else {
                    continue
                }
                let variants = jsonArray(jsonValue(in: detail, path: ["video_info", "variants"])) ?? []
                let mediaID = variants
                    .compactMap { jsonDictionary($0) }
                    .compactMap { jsonString($0["url"]) }
                    .compactMap(mediaIDFromVariantURL)
                    .first ?? tweetID
                detail["id_str"] = mediaID
                media.append(detail)
            }
        }

        normalized["extended_entities"] = ["media": media]
        return preferredStatus(from: normalized)
    }

    func preferredStatus(from status: JSONDictionary) -> JSONDictionary {
        jsonDictionary(status["retweeted_status"]) ?? status
    }
}

actor TwitterAPIClient {
    private let session: URLSession
    private let authProvider: any TwitterAuthProviding
    private let guestTokenStore: GuestTokenStore
    private let resolver = TweetResolver()

    init(
        session: URLSession = .shared,
        authProvider: any TwitterAuthProviding = DefaultTwitterAuthProvider(authToken: nil, csrfToken: nil),
        guestTokenStore: GuestTokenStore = GuestTokenStore()
    ) {
        self.session = session
        self.authProvider = authProvider
        self.guestTokenStore = guestTokenStore
    }

    func fetchStatus(tweetID: String, mode: TwitterAPISelection = .graphql) async throws -> JSONDictionary {
        switch mode {
        case .graphql:
            do {
                return try await resolver.normalizeGraphQLResult(fetchGraphQLData(tweetID: tweetID), tweetID: tweetID)
            } catch let error as SaveXError {
                if case let .apiError(_, statusCode?) = error, statusCode == 429 {
                    return resolver.normalizeSyndicationResult(try await fetchSyndicationTweet(tweetID: tweetID), tweetID: tweetID)
                }
                throw error
            }
        case .legacy:
            do {
                return resolver.preferredStatus(from: try await fetchLegacyTweet(tweetID: tweetID))
            } catch let error as SaveXError {
                if case let .apiError(_, statusCode?) = error, statusCode == 429 {
                    return resolver.normalizeSyndicationResult(try await fetchSyndicationTweet(tweetID: tweetID), tweetID: tweetID)
                }
                throw error
            }
        case .syndication:
            return resolver.normalizeSyndicationResult(try await fetchSyndicationTweet(tweetID: tweetID), tweetID: tweetID)
        }
    }

    func fetchVMAP(url: URL) async throws -> Data {
        let request = URLRequest(url: url)
        let (data, response) = try await session.data(for: request)
        try Self.validateResponse(response, data: data)
        return data
    }

    private func fetchGuestToken() async throws -> String {
        try await guestTokenStore.token {
            let url = SaveXKernelCompatibility.twitterAPIBase.appending(path: "guest/activate.json")
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.httpBody = Data()
            request.allHTTPHeaderFields = authProvider.baseHeaders(legacy: false)

            let (data, response) = try await session.data(for: request)
            try Self.validateResponse(response, data: data)

            let object = try Self.decodeJSONObject(data)
            guard let token = jsonString(object["guest_token"]),
                  !token.isEmpty else {
                throw SaveXError.invalidResponse("Could not retrieve guest token")
            }
            return token
        }
    }

    private func fetchGraphQLData(tweetID: String) async throws -> JSONDictionary {
        let endpoint = SaveXKernelCompatibility.twitterGraphQLAPIBase
            .appending(path: SaveXKernelCompatibility.twitterGraphQLEndpoint)
        let queryItems = try TwitterAPIConfiguration.encodedGraphQLItems(tweetID: tweetID)
        let request = try await authenticatedRequest(url: endpoint, mode: .graphql, queryItems: queryItems)
        let (data, response) = try await session.data(for: request)
        try Self.validateResponse(response, data: data)

        let object = try Self.decodeJSONObject(data)
        try Self.validateAPIErrors(object)

        guard let rootData = jsonDictionary(object["data"]) else {
            throw SaveXError.invalidResponse("Missing GraphQL data payload")
        }
        return rootData
    }

    private func fetchLegacyTweet(tweetID: String) async throws -> JSONDictionary {
        let url = SaveXKernelCompatibility.twitterAPIBase.appending(path: "statuses/show/\(tweetID).json")
        let queryItems = [
            URLQueryItem(name: "cards_platform", value: "Web-12"),
            URLQueryItem(name: "include_cards", value: "1"),
            URLQueryItem(name: "include_reply_count", value: "1"),
            URLQueryItem(name: "include_user_entities", value: "0"),
            URLQueryItem(name: "tweet_mode", value: "extended"),
        ]
        let request = try await authenticatedRequest(url: url, mode: .legacy, queryItems: queryItems)
        let (data, response) = try await session.data(for: request)
        try Self.validateResponse(response, data: data)

        let object = try Self.decodeJSONObject(data)
        try Self.validateAPIErrors(object)
        return object
    }

    private func fetchSyndicationTweet(tweetID: String) async throws -> JSONDictionary {
        let url = URL(string: "https://cdn.syndication.twimg.com/tweet-result")!
        let token = Self.generateSyndicationToken(tweetID: tweetID)
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "id", value: tweetID),
            URLQueryItem(name: "token", value: token),
        ]
        guard let finalURL = components?.url else {
            throw SaveXError.invalidURL(url.absoluteString)
        }

        var request = URLRequest(url: finalURL)
        request.setValue("Googlebot", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        try Self.validateResponse(response, data: data)
        let object = try Self.decodeJSONObject(data)
        return object
    }

    private func authenticatedRequest(
        url: URL,
        mode: TwitterAPISelection,
        queryItems: [URLQueryItem]
    ) async throws -> URLRequest {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw SaveXError.invalidURL(url.absoluteString)
        }
        components.queryItems = queryItems
        guard let finalURL = components.url else {
            throw SaveXError.invalidURL(url.absoluteString)
        }

        var request = URLRequest(url: finalURL)
        let legacy = mode == .legacy
        var headers = authProvider.baseHeaders(legacy: legacy)
        if authProvider.isLoggedIn {
            headers.merge(authProvider.sessionHeaders()) { _, new in new }
        } else {
            headers["x-guest-token"] = try await fetchGuestToken()
        }
        request.allHTTPHeaderFields = headers
        return request
    }

    private static func validateResponse(_ response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else {
            throw SaveXError.invalidResponse("Non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = String(data: data, encoding: .utf8) ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw SaveXError.apiError(message, statusCode: http.statusCode)
        }
    }

    private static func validateAPIErrors(_ object: JSONDictionary) throws {
        guard let errors = jsonArray(object["errors"]) else {
            return
        }
        let messages = errors
            .compactMap { jsonDictionary($0) }
            .compactMap { jsonString($0["message"]) }

        let filtered = Array(Set(messages)).sorted()
        guard let message = filtered.first, filtered.count > 0 else {
            return
        }
        if message.lowercased() == "dependency: unspecified" {
            return
        }
        if message.lowercased().contains("not authorized") {
            throw SaveXError.loginRequired(message.replacingOccurrences(of: ".", with: ""))
        }
        throw SaveXError.apiError(filtered.joined(separator: ", "), statusCode: nil)
    }

    private static func decodeJSONObject(_ data: Data) throws -> JSONDictionary {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? JSONDictionary else {
            throw SaveXError.invalidResponse("Expected JSON object")
        }
        return dictionary
    }

    private static func generateSyndicationToken(tweetID: String) -> String {
        let value = ((Double(tweetID) ?? 0) / 1e15) * Double.pi
        return jsRadix36String(value).filter { $0 != "0" && $0 != "." }
    }
}
