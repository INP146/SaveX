import Foundation

enum LibraryStoreSmokeError: LocalizedError {
    case failed(String)

    var errorDescription: String? {
        switch self {
        case let .failed(message):
            return message
        }
    }
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() {
        throw LibraryStoreSmokeError.failed(message)
    }
}

@MainActor
@main
struct LibraryStoreSmokeMain {
    static func main() async {
        do {
            try testLibraryManifestRoundTrip()
            print("library store smoke passed")
        } catch {
            print("FAILED: \(error.localizedDescription)")
            exit(1)
        }
    }

    private static func testLibraryManifestRoundTrip() throws {
        let fileManager = FileManager.default
        let root = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("SaveXLibrarySmoke-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? fileManager.removeItem(at: root)
        }

        let downloads = root
            .appendingPathComponent("SaveX", isDirectory: true)
            .appendingPathComponent("Downloads", isDirectory: true)
        try fileManager.createDirectory(at: downloads, withIntermediateDirectories: true)

        let fileURL = downloads.appendingPathComponent("fixture.mp4", isDirectory: false)
        try Data([1, 2, 3]).write(to: fileURL)

        let staleItem = LocalLibraryItem(
            id: UUID(),
            createdAt: Date(),
            sourceTweetID: "stale",
            sourceURLString: "https://x.com/demo/status/0",
            title: "stale",
            formatID: "http",
            fileName: "missing.mp4",
            fileSize: 1,
            responseMimeType: "video/mp4"
        )
        let item = LocalLibraryItem(
            id: UUID(),
            createdAt: Date(),
            sourceTweetID: "123",
            sourceURLString: "https://x.com/demo/status/123",
            title: "fixture",
            formatID: "http-832000",
            fileName: "fixture.mp4",
            fileSize: 3,
            responseMimeType: "video/mp4"
        )

        let manifest = root
            .appendingPathComponent("SaveX", isDirectory: true)
            .appendingPathComponent("library.json", isDirectory: false)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode([staleItem, item]).write(to: manifest, options: .atomic)

        let center = DownloadCenter(
            container: AppContainer(),
            fileManager: SmokeFileManager(root: root)
        )

        try expect(center.libraryItems.count == 1, "library load should ignore missing files")
        try expect(center.libraryItems.first?.sourceTweetID == item.sourceTweetID, "library item tweet ID should round trip")
        try expect(center.libraryItems.first?.fileName == item.fileName, "library item file name should round trip")
        try expect(center.savedBytes == 3, "saved bytes should come from library")
        try expect(center.completedCount == 1, "completed count should come from library")

        center.deleteLibraryItem(item)
        try expect(center.libraryItems.isEmpty, "delete should remove item from library")
        try expect(!fileManager.fileExists(atPath: fileURL.path), "delete should remove local file")
    }
}

private final class SmokeFileManager: FileManager, @unchecked Sendable {
    private let root: URL

    init(root: URL) {
        self.root = root
        super.init()
    }

    override func urls(for directory: FileManager.SearchPathDirectory, in domainMask: FileManager.SearchPathDomainMask) -> [URL] {
        guard directory == .documentDirectory else {
            return super.urls(for: directory, in: domainMask)
        }
        return [root]
    }
}
