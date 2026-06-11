import Foundation

enum FormatSelectionPreference: Sendable {
    case ytDLPCompatible
    case preferMP4Direct
    case preferHLS
    case exactFormatID(String)
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
