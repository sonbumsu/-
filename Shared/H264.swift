import CoreMedia
import Foundation

public enum H264Error: Error {
    case missingParameterSets
    case coreMedia(OSStatus, String)
}

extension VideoFrame {
    /// VideoToolbox 인코더가 내보낸 CMSampleBuffer를 전송용 프레임으로 바꾼다.
    public init?(encodedSampleBuffer sb: CMSampleBuffer) {
        guard let block = CMSampleBufferGetDataBuffer(sb) else { return nil }

        let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: false) as? [[String: Any]]
        let notSync = attachments?.first?[kCMSampleAttachmentKey_NotSync as String] as? Bool ?? false
        let keyframe = !notSync

        var sets: [Data] = []
        if keyframe, let fmt = CMSampleBufferGetFormatDescription(sb) {
            var count = 0
            var headerLength: Int32 = 0
            CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                fmt, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                parameterSetCountOut: &count, nalUnitHeaderLengthOut: &headerLength)
            for i in 0..<count {
                var ptr: UnsafePointer<UInt8>?
                var size = 0
                let status = CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    fmt, parameterSetIndex: i, parameterSetPointerOut: &ptr, parameterSetSizeOut: &size,
                    parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                if status == noErr, let ptr {
                    sets.append(Data(bytes: ptr, count: size))
                }
            }
        }

        let length = CMBlockBufferGetDataLength(block)
        var bytes = Data(count: length)
        let status = bytes.withUnsafeMutableBytes { raw in
            CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: raw.baseAddress!)
        }
        guard status == kCMBlockBufferNoErr else { return nil }

        let pts = CMSampleBufferGetPresentationTimeStamp(sb)
        let ns = pts.isValid ? UInt64(max(0, CMTimeGetSeconds(pts)) * 1_000_000_000) : 0
        self.init(isKeyframe: keyframe, timestampNs: ns, parameterSets: sets, data: bytes)
    }
}

/// 받은 프레임을 디코더/AVSampleBufferDisplayLayer에 넣을 수 있는 CMSampleBuffer로 만든다.
public final class H264SampleBufferBuilder {
    public private(set) var formatDescription: CMVideoFormatDescription?

    public init() {}

    public var videoSize: CGSize? {
        guard let fmt = formatDescription else { return nil }
        let dims = CMVideoFormatDescriptionGetDimensions(fmt)
        return CGSize(width: Int(dims.width), height: Int(dims.height))
    }

    public func reset() { formatDescription = nil }

    /// 키프레임을 아직 받지 못했으면 nil을 돌려준다.
    public func makeSampleBuffer(from frame: VideoFrame) throws -> CMSampleBuffer? {
        if frame.isKeyframe && !frame.parameterSets.isEmpty {
            formatDescription = try Self.makeFormatDescription(frame.parameterSets)
        }
        guard let fmt = formatDescription, !frame.data.isEmpty else { return nil }

        var block: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: frame.data.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: frame.data.count, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block)
        guard status == kCMBlockBufferNoErr, let block else { throw H264Error.coreMedia(status, "block create") }

        status = frame.data.withUnsafeBytes { raw in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: block,
                                          offsetIntoDestination: 0, dataLength: frame.data.count)
        }
        guard status == kCMBlockBufferNoErr else { throw H264Error.coreMedia(status, "block copy") }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: CMTimeValue(frame.timestampNs), timescale: 1_000_000_000),
            decodeTimeStamp: .invalid)
        var size = frame.data.count
        var sample: CMSampleBuffer?
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: fmt,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
        guard status == noErr, let sample else { throw H264Error.coreMedia(status, "sample create") }

        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            if !frame.isKeyframe {
                CFDictionarySetValue(dict,
                                     Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                                     Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            }
        }
        return sample
    }

    static func makeFormatDescription(_ sets: [Data]) throws -> CMVideoFormatDescription {
        guard !sets.isEmpty else { throw H264Error.missingParameterSets }
        // CoreMedia가 포인터를 읽는 동안 메모리가 살아 있도록 직접 복사해 둔다.
        let buffers = sets.map { set -> UnsafeMutablePointer<UInt8> in
            let p = UnsafeMutablePointer<UInt8>.allocate(capacity: max(set.count, 1))
            set.copyBytes(to: p, count: set.count)
            return p
        }
        defer { buffers.forEach { $0.deallocate() } }
        let pointers = buffers.map { UnsafePointer($0) }
        let sizes = sets.map(\.count)

        var fmt: CMVideoFormatDescription?
        let status = pointers.withUnsafeBufferPointer { ptrs in
            sizes.withUnsafeBufferPointer { szs in
                CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: sets.count,
                    parameterSetPointers: ptrs.baseAddress!, parameterSetSizes: szs.baseAddress!,
                    nalUnitHeaderLength: 4, formatDescriptionOut: &fmt)
            }
        }
        guard status == noErr, let fmt else { throw H264Error.coreMedia(status, "format description") }
        return fmt
    }
}
