import Combine
import Foundation

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}

enum TwitterCookieValidationIssue: String, Identifiable, Equatable {
    case emptyCookieHeader
    case missingAuthToken
    case missingCSRFToken
    case malformedCookiePair

    var id: String {
        rawValue
    }

    var label: String {
        switch self {
        case .emptyCookieHeader:
            return "Cookie is empty"
        case .missingAuthToken:
            return "auth_token missing"
        case .missingCSRFToken:
            return "ct0 missing"
        case .malformedCookiePair:
            return "Some cookie pairs were ignored"
        }
    }
}

struct TwitterCookieJar: Equatable, Sendable {
    let header: String
    let ignoredMalformedPairCount: Int

    private let values: [String: String]

    init(rawHeader: String) {
        let rawPairs = Self.cookieBody(from: rawHeader)
            .split(separator: ";", omittingEmptySubsequences: false)

        var normalizedPairs: [String] = []
        var parsedValues: [String: String] = [:]
        var malformedCount = 0

        for rawPair in rawPairs {
            let pair = rawPair.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !pair.isEmpty else {
                continue
            }

            let pieces = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard pieces.count == 2 else {
                malformedCount += 1
                continue
            }

            let name = pieces[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = pieces[1].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !value.isEmpty else {
                malformedCount += 1
                continue
            }

            parsedValues[name] = value
            normalizedPairs.append("\(name)=\(value)")
        }

        self.header = normalizedPairs.joined(separator: "; ")
        self.values = parsedValues
        self.ignoredMalformedPairCount = malformedCount
    }

    var isEmpty: Bool {
        header.isEmpty
    }

    var isLoggedIn: Bool {
        !(value(named: "auth_token")?.isEmpty ?? true)
    }

    var csrfToken: String? {
        value(named: "ct0")
    }

    var validationIssues: [TwitterCookieValidationIssue] {
        var issues: [TwitterCookieValidationIssue] = []
        if isEmpty {
            issues.append(.emptyCookieHeader)
        }
        if value(named: "auth_token") == nil {
            issues.append(.missingAuthToken)
        }
        if value(named: "ct0") == nil {
            issues.append(.missingCSRFToken)
        }
        if ignoredMalformedPairCount > 0 {
            issues.append(.malformedCookiePair)
        }
        return issues
    }

    func value(named name: String) -> String? {
        values[name]
    }

    private static func cookieBody(from rawHeader: String) -> String {
        let trimmed = rawHeader.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ""
        }

        let lines = trimmed
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }

        if let cookieLine = lines.first(where: { $0.lowercased().hasPrefix("cookie:") }) {
            return String(cookieLine.dropFirst("cookie:".count))
        }
        return lines.joined(separator: "; ")
    }
}

final class TwitterCookieStore: ObservableObject, @unchecked Sendable {
    @Published private(set) var session: TwitterCookieJar
    @Published private(set) var lastStorageError: String?

    private let storage: any SecureStringStoring
    private let lock = NSLock()

    init(
        storage: any SecureStringStoring = KeychainStringStore(
            service: "io.github.inp146.savex",
            account: "twitter.cookieHeader"
        )
    ) {
        self.storage = storage

        let storedHeader: String?
        do {
            storedHeader = try storage.read()
        } catch {
            storedHeader = nil
            self.lastStorageError = error.localizedDescription
        }

        self.session = TwitterCookieJar(rawHeader: storedHeader ?? "")
    }

    var hasCookie: Bool {
        !currentCookieHeader().isEmpty
    }

    var validationIssues: [TwitterCookieValidationIssue] {
        lock.withLock {
            session.validationIssues
        }
    }

    func currentCookieHeader() -> String {
        lock.withLock {
            session.header
        }
    }

    func currentSession() -> TwitterCookieJar {
        lock.withLock {
            session
        }
    }

    func update(cookieHeader: String) {
        let jar = TwitterCookieJar(rawHeader: cookieHeader)
        lock.withLock {
            session = jar
            do {
                if jar.header.isEmpty {
                    try storage.delete()
                } else {
                    try storage.write(jar.header)
                }
                lastStorageError = nil
            } catch {
                lastStorageError = error.localizedDescription
            }
        }
    }

    func clear() {
        lock.withLock {
            session = TwitterCookieJar(rawHeader: "")
            do {
                try storage.delete()
                lastStorageError = nil
            } catch {
                lastStorageError = error.localizedDescription
            }
        }
    }

    func cookieValue(named name: String) -> String? {
        lock.withLock {
            session.value(named: name)
        }
    }
}
