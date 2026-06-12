import Foundation

struct HLSResumeState: Codable, Sendable {
    let jobID: UUID
    let formatID: String
    let manifestURL: URL
    let segmentURLs: [URL]
    var completedSegmentIndices: [Int]
    var updatedAt: Date
}

final class HLSResumeStore: @unchecked Sendable {
    private let fileManager: FileManager
    private let lock = NSLock()

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func workingDirectory(jobID: UUID) -> URL {
        rootDirectory.appendingPathComponent(jobID.uuidString, isDirectory: true)
    }

    func state(jobID: UUID) -> HLSResumeState? {
        lock.lock()
        defer { lock.unlock() }
        return loadState(jobID: jobID)
    }

    func prepareState(jobID: UUID, format: MediaFormat, segments: [HLSSegment]) {
        lock.lock()
        defer { lock.unlock() }

        let segmentURLs = segments.map(\.url)
        if let existing = loadState(jobID: jobID),
           existing.formatID == format.formatID,
           existing.manifestURL == format.url,
           existing.segmentURLs == segmentURLs {
            return
        }

        try? fileManager.removeItem(at: workingDirectory(jobID: jobID))
        saveState(HLSResumeState(
            jobID: jobID,
            formatID: format.formatID,
            manifestURL: format.url,
            segmentURLs: segmentURLs,
            completedSegmentIndices: [],
            updatedAt: Date()
        ))
    }

    func markCompleted(index: Int, jobID: UUID) {
        lock.lock()
        defer { lock.unlock() }
        guard var state = loadState(jobID: jobID) else {
            return
        }
        if !state.completedSegmentIndices.contains(index) {
            state.completedSegmentIndices.append(index)
            state.completedSegmentIndices.sort()
        }
        state.updatedAt = Date()
        saveState(state)
    }

    func clear(jobID: UUID) {
        lock.lock()
        defer { lock.unlock() }
        try? fileManager.removeItem(at: workingDirectory(jobID: jobID))
        try? fileManager.removeItem(at: stateURL(jobID: jobID))
    }

    private func loadState(jobID: UUID) -> HLSResumeState? {
        guard let data = try? Data(contentsOf: stateURL(jobID: jobID)) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(HLSResumeState.self, from: data)
    }

    private func saveState(_ state: HLSResumeState) {
        do {
            try fileManager.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(state)
            try data.write(to: stateURL(jobID: state.jobID), options: .atomic)
        } catch {
            assertionFailure("Failed to persist HLS resume state: \(error.localizedDescription)")
        }
    }

    private func stateURL(jobID: UUID) -> URL {
        stateDirectory.appendingPathComponent("\(jobID.uuidString).json", isDirectory: false)
    }

    private var stateDirectory: URL {
        rootDirectory.appendingPathComponent("State", isDirectory: true)
    }

    private var rootDirectory: URL {
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return applicationSupport
            .appendingPathComponent("SaveX", isDirectory: true)
            .appendingPathComponent("HLSJobs", isDirectory: true)
    }
}
