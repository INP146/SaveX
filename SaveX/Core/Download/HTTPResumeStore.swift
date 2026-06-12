import Foundation

struct HTTPResumeState: Codable, Sendable {
    let jobID: UUID
    let format: MediaFormat
    let tweetID: String
    let title: String
    let destinationDirectoryPath: String
    var resumeDataFileName: String?
    var partialFileName: String?
    var downloadedBytes: Int64?
    var totalBytes: Int64?
    var updatedAt: Date
}

final class HTTPResumeStore: @unchecked Sendable {
    private let fileManager: FileManager
    private let lock = NSLock()

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func state(jobID: UUID) -> HTTPResumeState? {
        lock.lock()
        defer { lock.unlock() }
        return loadState(jobID: jobID)
    }

    func resumeData(jobID: UUID) -> Data? {
        lock.lock()
        defer { lock.unlock() }
        guard let state = loadState(jobID: jobID),
              let fileName = state.resumeDataFileName else {
            return nil
        }
        return try? Data(contentsOf: resumeDataDirectory.appendingPathComponent(fileName, isDirectory: false))
    }

    func partialURL(jobID: UUID) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        guard let state = loadState(jobID: jobID),
              let fileName = state.partialFileName else {
            return nil
        }
        let url = partialDirectory.appendingPathComponent(fileName, isDirectory: false)
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    func saveResumeData(
        _ data: Data,
        jobID: UUID,
        format: MediaFormat,
        tweetID: String,
        title: String,
        destinationDirectory: URL,
        totalBytes: Int64?
    ) {
        lock.lock()
        defer { lock.unlock() }

        do {
            try fileManager.createDirectory(at: resumeDataDirectory, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: partialDirectory, withIntermediateDirectories: true)

            let resumeFileName = "\(jobID.uuidString).resume"
            let resumeURL = resumeDataDirectory.appendingPathComponent(resumeFileName, isDirectory: false)
            try data.write(to: resumeURL, options: .atomic)

            var partialFileName = loadState(jobID: jobID)?.partialFileName
            if let sourcePartialURL = sourcePartialURL(fromResumeData: data) {
                let destinationFileName = "\(jobID.uuidString).partial"
                let destinationURL = partialDirectory.appendingPathComponent(destinationFileName, isDirectory: false)
                if fileManager.fileExists(atPath: destinationURL.path) {
                    try? fileManager.removeItem(at: destinationURL)
                }
                try? fileManager.copyItem(at: sourcePartialURL, to: destinationURL)
                if fileManager.fileExists(atPath: destinationURL.path) {
                    partialFileName = destinationFileName
                }
            }

            let partialBytes = partialFileName.flatMap { fileName -> Int64? in
                let url = partialDirectory.appendingPathComponent(fileName, isDirectory: false)
                return (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
            }

            saveState(HTTPResumeState(
                jobID: jobID,
                format: format,
                tweetID: tweetID,
                title: title,
                destinationDirectoryPath: destinationDirectory.path,
                resumeDataFileName: resumeFileName,
                partialFileName: partialFileName,
                downloadedBytes: partialBytes ?? resumeBytesReceived(fromResumeData: data),
                totalBytes: totalBytes,
                updatedAt: Date()
            ))
        } catch {
            assertionFailure("Failed to persist resume data: \(error.localizedDescription)")
        }
    }

    func clear(jobID: UUID) {
        lock.lock()
        defer { lock.unlock() }
        guard let state = loadState(jobID: jobID) else {
            return
        }
        if let resumeDataFileName = state.resumeDataFileName {
            try? fileManager.removeItem(at: resumeDataDirectory.appendingPathComponent(resumeDataFileName, isDirectory: false))
        }
        if let partialFileName = state.partialFileName {
            try? fileManager.removeItem(at: partialDirectory.appendingPathComponent(partialFileName, isDirectory: false))
        }
        try? fileManager.removeItem(at: stateURL(jobID: jobID))
    }

    private func loadState(jobID: UUID) -> HTTPResumeState? {
        let url = stateURL(jobID: jobID)
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(HTTPResumeState.self, from: data)
    }

    private func saveState(_ state: HTTPResumeState) {
        do {
            try fileManager.createDirectory(at: stateDirectory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(state)
            try data.write(to: stateURL(jobID: state.jobID), options: .atomic)
        } catch {
            assertionFailure("Failed to persist resume state: \(error.localizedDescription)")
        }
    }

    private func sourcePartialURL(fromResumeData data: Data) -> URL? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            return nil
        }

        if let path = plist["NSURLSessionResumeInfoLocalPath"] as? String {
            let url = URL(fileURLWithPath: path, isDirectory: false)
            if fileManager.fileExists(atPath: url.path) {
                return url
            }
        }

        if let tempFileName = plist["NSURLSessionResumeInfoTempFileName"] as? String {
            let url = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
                .appendingPathComponent(tempFileName, isDirectory: false)
            if fileManager.fileExists(atPath: url.path) {
                return url
            }
        }

        return nil
    }

    private func resumeBytesReceived(fromResumeData data: Data) -> Int64? {
        guard let plist = try? PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            return nil
        }
        return (plist["NSURLSessionResumeBytesReceived"] as? NSNumber)?.int64Value
            ?? (plist["NSURLSessionResumeInfoBytesReceived"] as? NSNumber)?.int64Value
    }

    private func stateURL(jobID: UUID) -> URL {
        stateDirectory.appendingPathComponent("\(jobID.uuidString).json", isDirectory: false)
    }

    private var stateDirectory: URL {
        rootDirectory.appendingPathComponent("HTTPResumeState", isDirectory: true)
    }

    private var resumeDataDirectory: URL {
        rootDirectory.appendingPathComponent("ResumeData", isDirectory: true)
    }

    private var partialDirectory: URL {
        rootDirectory.appendingPathComponent("PartialHTTP", isDirectory: true)
    }

    private var rootDirectory: URL {
        let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return applicationSupport.appendingPathComponent("SaveX", isDirectory: true)
    }
}
