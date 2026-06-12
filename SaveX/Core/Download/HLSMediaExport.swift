import Foundation
@preconcurrency import AVFoundation

protocol HLSMediaExporting: Sendable {
    func exportMP4(from sourceURL: URL, to destinationURL: URL) async throws
}

struct AVFoundationHLSMediaExporter: HLSMediaExporting {
    func exportMP4(from sourceURL: URL, to destinationURL: URL) async throws {
        let cancellationBox = HLSExportCancellationBox()
        try await withTaskCancellationHandler {
            let asset = AVURLAsset(url: sourceURL)
            guard let exportSession = AVAssetExportSession(
                asset: asset,
                presetName: AVAssetExportPresetPassthrough
            ) else {
                throw SaveXError.hlsExportFailed("AVFoundation could not create a passthrough export session")
            }
            cancellationBox.set(exportSession)
            guard exportSession.supportedFileTypes.contains(.mp4) else {
                throw SaveXError.hlsExportFailed("AVFoundation does not support MP4 export for this HLS media")
            }

            exportSession.outputURL = destinationURL
            exportSession.outputFileType = .mp4
            exportSession.shouldOptimizeForNetworkUse = true

            do {
                try Task.checkCancellation()
                try await exportSession.export(to: destinationURL, as: .mp4)
                try Task.checkCancellation()
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let reason = error.localizedDescription
                throw SaveXError.hlsExportFailed(reason)
            }
        } onCancel: {
            cancellationBox.cancel()
        }
    }
}

private final class HLSExportCancellationBox: @unchecked Sendable {
    private let lock = NSLock()
    private var exportSession: AVAssetExportSession?

    func set(_ exportSession: AVAssetExportSession) {
        lock.lock()
        self.exportSession = exportSession
        lock.unlock()
    }

    func cancel() {
        lock.lock()
        let exportSession = exportSession
        lock.unlock()
        exportSession?.cancelExport()
    }
}
