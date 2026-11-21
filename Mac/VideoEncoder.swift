import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox

/// VideoToolbox 하드웨어 H.264 인코더 (저지연 설정).
final class VideoEncoder {
    enum EncoderError: Error { case create(OSStatus) }

    let width: Int
    let height: Int
    private var session: VTCompressionSession?
    private let onEncoded: (VideoFrame) -> Void

    init(width: Int, height: Int, fps: Int, bitrate: Int, onEncoded: @escaping (VideoFrame) -> Void) throws {
        self.width = width
        self.height = height
        self.onEncoded = onEncoded

        // 저지연 rate control을 먼저 시도하고, 안 되면 일반 하드웨어 인코더를 쓴다.
        let specs: [[CFString: Any]] = [
            [kVTVideoEncoderSpecification_EnableLowLatencyRateControl: true,
             kVTVideoEncoderSpecification_RequireHardwareAcceleratedVideoEncoder: true],
            [kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder: true],
        ]
        var lastStatus: OSStatus = noErr
        for spec in specs {
            var s: VTCompressionSession?
            lastStatus = VTCompressionSessionCreate(
                allocator: kCFAllocatorDefault, width: Int32(width), height: Int32(height),
                codecType: kCMVideoCodecType_H264, encoderSpecification: spec as CFDictionary,
                imageBufferAttributes: nil, compressedDataAllocator: nil,
                outputCallback: nil, refcon: nil, compressionSessionOut: &s)
            if lastStatus == noErr, let s {
                session = s
                break
            }
        }
        guard let session else { throw EncoderError.create(lastStatus) }

        func set(_ key: CFString, _ value: Any) {
            VTSessionSetProperty(session, key: key, value: value as CFTypeRef)
        }
        set(kVTCompressionPropertyKey_RealTime, true)
        set(kVTCompressionPropertyKey_AllowFrameReordering, false)
        set(kVTCompressionPropertyKey_ProfileLevel, kVTProfileLevel_H264_High_AutoLevel)
        set(kVTCompressionPropertyKey_AverageBitRate, bitrate)
        set(kVTCompressionPropertyKey_ExpectedFrameRate, fps)
        set(kVTCompressionPropertyKey_MaxKeyFrameInterval, fps * 2)
        set(kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, 2)
        VTCompressionSessionPrepareToEncodeFrames(session)
    }

    deinit { invalidate() }

    /// 화면 크기와 FPS에 맞는 기본 비트레이트 (4~20 Mbps)
    static func defaultBitrate(width: Int, height: Int, fps: Int) -> Int {
        let raw = Double(width * height * fps) * 0.06
        return Int(min(20_000_000, max(4_000_000, raw)))
    }

    func encode(_ pixelBuffer: CVPixelBuffer, pts: CMTime, forceKeyframe: Bool) {
        guard let session else { return }
        let props: CFDictionary? = forceKeyframe
            ? [kVTEncodeFrameOptionKey_ForceKeyFrame: true] as CFDictionary
            : nil
        VTCompressionSessionEncodeFrame(
            session, imageBuffer: pixelBuffer, presentationTimeStamp: pts, duration: .invalid,
            frameProperties: props, infoFlagsOut: nil
        ) { [weak self] status, _, sampleBuffer in
            guard status == noErr, let sampleBuffer, let self,
                  let frame = VideoFrame(encodedSampleBuffer: sampleBuffer) else { return }
            self.onEncoded(frame)
        }
    }

    func invalidate() {
        if let session {
            VTCompressionSessionInvalidate(session)
        }
        session = nil
    }
}
