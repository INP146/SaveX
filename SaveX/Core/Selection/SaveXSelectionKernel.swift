import Foundation

enum FormatSelectionPreference: Codable, Sendable {
    case ytDLPCompatible
    case preferMP4Direct
    case preferHLS
    case exactFormatID(String)

    private enum CodingKeys: String, CodingKey {
        case kind
        case formatID
    }

    private enum Kind: String, Codable {
        case ytDLPCompatible
        case preferMP4Direct
        case preferHLS
        case exactFormatID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .ytDLPCompatible:
            self = .ytDLPCompatible
        case .preferMP4Direct:
            self = .preferMP4Direct
        case .preferHLS:
            self = .preferHLS
        case .exactFormatID:
            self = .exactFormatID(try container.decode(String.self, forKey: .formatID))
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .ytDLPCompatible:
            try container.encode(Kind.ytDLPCompatible, forKey: .kind)
        case .preferMP4Direct:
            try container.encode(Kind.preferMP4Direct, forKey: .kind)
        case .preferHLS:
            try container.encode(Kind.preferHLS, forKey: .kind)
        case let .exactFormatID(id):
            try container.encode(Kind.exactFormatID, forKey: .kind)
            try container.encode(id, forKey: .formatID)
        }
    }
}

struct FormatScore: Comparable, Sendable {
    let resolution: Int
    let protocolRank: Int
    let bitrate: Int
    let fileSize: Int

    static func < (lhs: FormatScore, rhs: FormatScore) -> Bool {
        if lhs.resolution != rhs.resolution {
            return lhs.resolution < rhs.resolution
        }
        if lhs.protocolRank != rhs.protocolRank {
            return lhs.protocolRank < rhs.protocolRank
        }
        if lhs.bitrate != rhs.bitrate {
            return lhs.bitrate < rhs.bitrate
        }
        return lhs.fileSize < rhs.fileSize
    }
}

struct FormatSortPolicy {
    let preference: FormatSelectionPreference

    func score(for format: MediaFormat) -> FormatScore {
        switch preference {
        case .ytDLPCompatible:
            return FormatScore(
                resolution: format.pixelCount,
                protocolRank: format.isHLS ? 2 : 1,
                bitrate: format.bitrate ?? 0,
                fileSize: format.fileSizeApprox ?? 0
            )
        case .preferMP4Direct:
            return FormatScore(
                resolution: format.pixelCount,
                protocolRank: format.isHLS ? 0 : 2,
                bitrate: format.bitrate ?? 0,
                fileSize: format.fileSizeApprox ?? 0
            )
        case .preferHLS:
            return FormatScore(
                resolution: format.pixelCount,
                protocolRank: format.isHLS ? 3 : 1,
                bitrate: format.bitrate ?? 0,
                fileSize: format.fileSizeApprox ?? 0
            )
        case .exactFormatID:
            return FormatScore(
                resolution: format.pixelCount,
                protocolRank: format.isHLS ? 2 : 1,
                bitrate: format.bitrate ?? 0,
                fileSize: format.fileSizeApprox ?? 0
            )
        }
    }
}

struct FormatSelector {
    func selectBest(
        from formats: [MediaFormat],
        preference: FormatSelectionPreference = .ytDLPCompatible
    ) throws -> MediaFormat {
        guard !formats.isEmpty else {
            throw SaveXError.noFormatsFound
        }

        if case let .exactFormatID(id) = preference,
           let exact = formats.first(where: { $0.formatID == id || $0.id == id }) {
            return exact
        }

        switch preference {
        case .preferMP4Direct:
            let directFormats = formats.filter { !$0.isHLS }
            if !directFormats.isEmpty {
                return try selectBest(from: directFormats, preference: .ytDLPCompatible)
            }
        case .preferHLS:
            let hlsFormats = formats.filter(\.isHLS)
            if !hlsFormats.isEmpty {
                return try selectBest(from: hlsFormats, preference: .ytDLPCompatible)
            }
        case .ytDLPCompatible, .exactFormatID:
            break
        }

        let policy = FormatSortPolicy(preference: preference)
        return try selectSorted(from: formats, policy: policy).first
            .map(\.format)
            .unwrap(or: SaveXError.noFormatsFound)
    }

    func selectSorted(from formats: [MediaFormat], policy: FormatSortPolicy) -> [(format: MediaFormat, score: FormatScore)] {
        formats
            .map { ($0, policy.score(for: $0)) }
            .sorted { lhs, rhs in
                if lhs.score == rhs.score {
                    return lhs.format.formatID < rhs.format.formatID
                }
                return lhs.score > rhs.score
            }
    }
}

private extension Optional {
    func unwrap(or error: @autoclosure () -> Error) throws -> Wrapped {
        guard let value = self else {
            throw error()
        }
        return value
    }
}
