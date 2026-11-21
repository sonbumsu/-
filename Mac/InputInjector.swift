import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// 아이패드에서 온 입력을 맥의 마우스 이벤트로 바꿔 넣는다. (손쉬운 사용 권한 필요)
final class InputInjector {
    private let source = CGEventSource(stateID: .hidSystemState)
    private var lastClickTime: TimeInterval = 0
    private var lastClickPoint = CGPoint.zero
    private var clickCount: Int64 = 1
    private var lastPoint = CGPoint.zero

    static var isTrusted: Bool { AXIsProcessTrusted() }

    static func requestTrust() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// 정규화 좌표(0...1)를 해당 디스플레이의 전역 좌표로 바꾼다.
    static func globalPoint(x: Float, y: Float, in bounds: CGRect) -> CGPoint {
        let cx = min(max(CGFloat(x), 0), 1)
        let cy = min(max(CGFloat(y), 0), 1)
        // 오른쪽/아래 끝 픽셀 바깥으로 나가지 않게 살짝 안쪽으로
        return CGPoint(x: bounds.minX + cx * (bounds.width - 1), y: bounds.minY + cy * (bounds.height - 1))
    }

    func handle(_ event: InputEvent, displayID: CGDirectDisplayID) {
        let bounds = CGDisplayBounds(displayID)
        let p = Self.globalPoint(x: event.x, y: event.y, in: bounds)

        switch event.kind {
        case .move:
            post(.mouseMoved, at: p, button: .left)
        case .leftDown:
            updateClickCount(at: p)
            post(.leftMouseDown, at: p, button: .left, clicks: clickCount)
        case .leftDrag:
            post(.leftMouseDragged, at: p, button: .left)
        case .leftUp:
            post(.leftMouseUp, at: p, button: .left, clicks: clickCount)
        case .rightClick:
            post(.rightMouseDown, at: p, button: .right)
            post(.rightMouseUp, at: p, button: .right)
        case .scroll:
            // 아이패드 손가락 방향 그대로 따라가는 자연스러운 스크롤
            let e = CGEvent(scrollWheelEvent2Source: source, units: .pixel, wheelCount: 2,
                            wheel1: Int32(event.dy.rounded()), wheel2: Int32(event.dx.rounded()), wheel3: 0)
            e?.post(tap: .cghidEventTap)
            return
        }
        lastPoint = p
    }

    private func updateClickCount(at p: CGPoint) {
        let now = ProcessInfo.processInfo.systemUptime
        let near = hypot(p.x - lastClickPoint.x, p.y - lastClickPoint.y) < 8
        clickCount = (now - lastClickTime < NSEvent.doubleClickInterval && near) ? min(clickCount + 1, 3) : 1
        lastClickTime = now
        lastClickPoint = p
    }

    private func post(_ type: CGEventType, at p: CGPoint, button: CGMouseButton, clicks: Int64 = 1) {
        guard let e = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: p, mouseButton: button)
        else { return }
        e.setIntegerValueField(.mouseEventClickState, value: clicks)
        e.post(tap: .cghidEventTap)
    }
}

