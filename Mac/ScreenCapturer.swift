import CoreMedia
import CoreVideo
import Foundation
import ScreenCaptureKit

/// ScreenCaptureKit으로 디스플레이 하나를 캡처한다.
final class ScreenCapturer: NSObject, SCStreamOutput, SCStreamDelegate {
    enum CaptureError: LocalizedError {
        case displayNotFound(CGDirectDisplayID)
        var errorDescription: String? {
            switch self {
            case .displayNotFound(let id): return "캡처할 디스플레이(\(id))를 찾지 못했어요."
            }
        }
    }

    private var stream: SCStream?
    private let outputQueue: DispatchQueue
    private let onFrame: (CVPixelBuffer, CMTime) -> Void
    var onStop: ((Error?) -> Void)?

    /// - Parameter queue: 프레임 콜백을 부를 큐
    init(queue: DispatchQueue, onFrame: @escaping (CVPixelBuffer, CMTime) -> Void) {
        self.outputQueue = queue
        self.onFrame = onFrame
    }

    /// 가상 디스플레이는 만든 직후 바로 목록에 나타나지 않을 수 있어서 몇 번 다시 찾는다.
    func start(displayID: CGDirectDisplayID, width: Int, height: Int, fps: Int) async throws {
        var display: SCDisplay?
        for attempt in 0..<15 {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            display = content.displays.first { $0.displayID == displayID }
            if display != nil { break }
            if attempt < 14 { try await Task.sleep(nanoseconds: 200_000_000) }
        }
        guard let display else { throw CaptureError.displayNotFound(displayID) }

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let config = SCStreamConfiguration()
        config.width = width
        config.height = height
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
        config.queueDepth = 4
        config.showsCursor = true
        config.scalesToFit = true

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: outputQueue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixelBuffer = sampleBuffer.imageBuffer
        else { return }
        onFrame(pixelBuffer, sampleBuffer.presentationTimeStamp)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        self.stream = nil
        onStop?(error)
    }
}
