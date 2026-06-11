import Foundation

@main
struct SaveXKernelSmokeMain {
    static func main() async {
        let parser = TwitterURLParser()
        let apiClient = TwitterAPIClient()
        let extractor = TwitterMediaExtractor()
        let selector = FormatSelector()

        let candidates = [
            "https://twitter.com/starwars/status/665052190608723968",
            "https://twitter.com/BTNBrentYarina/status/705235433198714880",
            "https://twitter.com/BrooklynNets/status/1349794411333394432",
            "https://twitter.com/oshtru/status/1577855540407197696",
            "https://twitter.com/i/web/status/910031516746514432",
            "https://twitter.com/UltimaShadowX/status/1577719286659006464/video/1",
        ]

        for rawURL in candidates {
            print("=== \(rawURL)")
            do {
                let request = try parser.parse(rawURL)
                print("parsed tweetID=\(request.tweetID) selectedIndex=\(request.selectedMediaIndex.map(String.init) ?? "nil")")

                for mode in [TwitterAPISelection.graphql, .legacy, .syndication] {
                    do {
                        let status = try await apiClient.fetchStatus(tweetID: request.tweetID, mode: mode)
                        let entries = try await extractor.extractEntries(
                            from: status,
                            request: request,
                            loadVMAP: { url in
                                try await apiClient.fetchVMAP(url: url)
                            }
                        )

                        print("mode=\(mode.rawValue) entries=\(entries.count)")
                        for (index, entry) in entries.enumerated() {
                            print("  [\(index + 1)] id=\(entry.id) title=\(entry.title)")
                            print("      formats=\(entry.formats.count) duration=\(entry.duration.map { String(format: "%.3f", $0) } ?? "nil") external=\(entry.externalReferenceURL?.absoluteString ?? "nil")")
                            if let selected = try? selector.selectBest(from: entry.formats) {
                                print("      selected formatID=\(selected.formatID) transport=\(selected.transport.rawValue) url=\(selected.url.absoluteString)")
                            } else {
                                print("      selected formatID=nil")
                            }
                        }
                    } catch {
                        print("mode=\(mode.rawValue) FAILED: \(error.localizedDescription)")
                    }
                }
            } catch {
                print("FAILED: \(error.localizedDescription)")
            }
            print("")
        }
    }
}
