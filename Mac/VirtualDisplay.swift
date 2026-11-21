import CoreGraphics
import Foundation

/// 아이패드 크기에 맞춘 가상 디스플레이. 이 객체가 살아 있는 동안 맥에 두 번째 모니터로 나타난다.
final class VirtualDisplay {
    private let display: CGVirtualDisplay
    let displayID: CGDirectDisplayID

    /// - Parameters:
    ///   - pointWidth/pointHeight: 아이패드 화면 크기 (포인트)
    ///   - scale: 아이패드 화면 배율 (보통 2)
    init?(name: String, pointWidth: Int, pointHeight: Int, scale: Double) {
        let pixelWidth = Int(Double(pointWidth) * scale)
        let pixelHeight = Int(Double(pointHeight) * scale)

        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.dispatchQueue = DispatchQueue.main
        descriptor.name = name
        descriptor.maxPixelsWide = UInt32(pixelWidth)
        descriptor.maxPixelsHigh = UInt32(pixelHeight)
        // 실제 크기를 대략 아이패드(약 264ppi)에 맞춰 둔다. macOS가 기본 배율을 고를 때 참고한다.
        descriptor.sizeInMillimeters = CGSize(width: Double(pixelWidth) / 264 * 25.4,
                                              height: Double(pixelHeight) / 264 * 25.4)
        descriptor.vendorID = 0x5343   // "SC"
        descriptor.productID = 0x4C4B  // "LK"
        descriptor.serialNum = UInt32(pixelWidth * 10_000 + pixelHeight)

        guard let display = CGVirtualDisplay(descriptor: descriptor) else { return nil }

        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = scale > 1 ? 1 : 0
        settings.modes = [
            CGVirtualDisplayMode(width: UInt32(pixelWidth), height: UInt32(pixelHeight), refreshRate: 60),
            CGVirtualDisplayMode(width: UInt32(pointWidth), height: UInt32(pointHeight), refreshRate: 60),
        ]
        guard display.apply(settings) else { return nil }

        self.display = display
        self.displayID = display.displayID
        self.pointWidth = pointWidth
        self.pixelWidth = pixelWidth
    }

    private let pointWidth: Int
    private let pixelWidth: Int

    /// 만든 직후에는 디스플레이 모드가 아직 준비되지 않았을 수 있어서 잠깐 기다린 뒤 모드를 고른다.
    /// - Returns: 실제 픽셀 크기. 시간 안에 준비되지 않으면 nil
    @MainActor
    func waitUntilReady(timeout: TimeInterval = 3) async -> (width: Int, height: Int)? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if CGDisplayCopyDisplayMode(displayID) != nil {
                Self.selectMode(displayID: displayID, pointWidth: pointWidth, pixelWidth: pixelWidth)
                let size = pixelSize
                if size.width > 0 && size.height > 0 { return size }
            }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return nil
    }

    /// 포인트 크기는 아이패드와 같고, 픽셀은 Retina로 렌더링되는 모드를 고른다.
    private static func selectMode(displayID: CGDirectDisplayID, pointWidth: Int, pixelWidth: Int) {
        let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode] else { return }
        let best = modes.first { $0.width == pointWidth && $0.pixelWidth == pixelWidth }
            ?? modes.first { $0.width == pointWidth }
        guard let best else { return }

        var config: CGDisplayConfigRef?
        guard CGBeginDisplayConfiguration(&config) == .success else { return }
        CGConfigureDisplayWithDisplayMode(config, displayID, best, nil)
        CGCompleteDisplayConfiguration(config, .forSession)
    }

    /// 현재 모드의 실제 픽셀 크기. 캡처 해상도로 쓴다.
    var pixelSize: (width: Int, height: Int) {
        guard let mode = CGDisplayCopyDisplayMode(displayID) else { return (0, 0) }
        return (mode.pixelWidth, mode.pixelHeight)
    }
}
