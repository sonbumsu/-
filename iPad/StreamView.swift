import AVFoundation
import SwiftUI
import UIKit

/// 맥 화면을 보여주고, 터치/펜슬 입력을 맥의 마우스 동작으로 바꾼다.
///
/// - 한 손가락 탭: 클릭
/// - 한 손가락 드래그: 끌기
/// - 길게 누르기: 오른쪽 클릭
/// - 두 손가락 드래그: 스크롤
/// - 애플펜슬: 바로 누르기/끌기 (그림 그리기용)
/// - 세 손가락 탭: 컨트롤 막대 보이기/숨기기
final class StreamUIView: UIView {
    let displayLayer: AVSampleBufferDisplayLayer
    var videoSize: CGSize = .zero
    var inputEnabled = true
    var onInput: ((InputEvent) -> Void)?
    var onThreeFingerTap: (() -> Void)?

    private enum Phase {
        case idle
        case pending(start: CGPoint)     // 탭인지 드래그인지 아직 모름
        case dragging(last: CGPoint)
        case longPressed
        case scrolling(last: CGPoint)
        case ignored                     // 세 손가락 이상
    }

    private var phase: Phase = .idle
    private var activeTouches: [UITouch] = []
    private var longPressWork: DispatchWorkItem?
    private var gestureStart: TimeInterval = 0
    private var maxTouches = 0
    private var gestureMoved = false

    private let tapSlop: CGFloat = 10
    private let longPressDelay: TimeInterval = 0.5
    private let scrollMultiplier: CGFloat = 2

    init(displayLayer: AVSampleBufferDisplayLayer) {
        self.displayLayer = displayLayer
        super.init(frame: .zero)
        backgroundColor = .black
        isMultipleTouchEnabled = true
        displayLayer.videoGravity = .resizeAspect
        layer.addSublayer(displayLayer)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        displayLayer.frame = bounds
        CATransaction.commit()
    }

    // MARK: - 좌표

    /// 화면 좌표를 영상 기준 0...1 좌표로 바꾼다. (레터박스 영역은 가장자리로 붙인다)
    private func normalized(_ p: CGPoint) -> (Float, Float) {
        guard videoSize.width > 0, videoSize.height > 0 else { return (0.5, 0.5) }
        let rect = AVMakeRect(aspectRatio: videoSize, insideRect: bounds)
        let x = (p.x - rect.minX) / rect.width
        let y = (p.y - rect.minY) / rect.height
        return (Float(min(max(x, 0), 1)), Float(min(max(y, 0), 1)))
    }

    private func emit(_ kind: InputEvent.Kind, at p: CGPoint) {
        guard inputEnabled else { return }
        let (x, y) = normalized(p)
        onInput?(InputEvent(kind, x: x, y: y))
    }

    private func centroid() -> CGPoint {
        let points = activeTouches.map { $0.location(in: self) }
        guard !points.isEmpty else { return .zero }
        let n = CGFloat(points.count)
        return CGPoint(x: points.reduce(0) { $0 + $1.x } / n, y: points.reduce(0) { $0 + $1.y } / n)
    }

    // MARK: - 터치

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        if activeTouches.isEmpty {
            gestureStart = event?.timestamp ?? ProcessInfo.processInfo.systemUptime
            maxTouches = 0
            gestureMoved = false
        }
        for t in touches where !activeTouches.contains(t) { activeTouches.append(t) }
        maxTouches = max(maxTouches, activeTouches.count)

        switch activeTouches.count {
        case 1:
            let touch = activeTouches[0]
            let p = touch.location(in: self)
            emit(.move, at: p)
            if touch.type == .pencil {
                emit(.leftDown, at: p)
                phase = .dragging(last: p)
            } else {
                phase = .pending(start: p)
                scheduleLongPress(at: p)
            }
        case 2:
            cancelLongPress()
            if case .dragging(let last) = phase { emit(.leftUp, at: last) }
            phase = .scrolling(last: centroid())
        default:
            cancelLongPress()
            if case .dragging(let last) = phase { emit(.leftUp, at: last) }
            phase = .ignored
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        switch phase {
        case .pending(let start):
            guard let touch = activeTouches.first else { return }
            let p = touch.location(in: self)
            if hypot(p.x - start.x, p.y - start.y) > tapSlop {
                cancelLongPress()
                gestureMoved = true
                emit(.leftDown, at: start)
                emit(.leftDrag, at: p)
                phase = .dragging(last: p)
            }
        case .dragging:
            guard let touch = activeTouches.first else { return }
            // 펜슬은 120Hz 이상으로 들어오는 중간 점까지 보내서 선이 매끄럽게 한다.
            let samples = event?.coalescedTouches(for: touch) ?? [touch]
            for s in samples { emit(.leftDrag, at: s.location(in: self)) }
            gestureMoved = true
            phase = .dragging(last: touch.location(in: self))
        case .scrolling(let last):
            let c = centroid()
            let dx = c.x - last.x
            let dy = c.y - last.y
            if abs(dx) + abs(dy) > 0.5 {
                gestureMoved = true
                if inputEnabled {
                    onInput?(InputEvent(.scroll, dx: Float(dx * scrollMultiplier), dy: Float(dy * scrollMultiplier)))
                }
                phase = .scrolling(last: c)
            }
        case .ignored:
            if let t = activeTouches.first {
                let d = t.location(in: self)
                let p = t.previousLocation(in: self)
                if hypot(d.x - p.x, d.y - p.y) > tapSlop { gestureMoved = true }
            }
        case .idle, .longPressed:
            break
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish(touches, event: event, cancelled: false)
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        finish(touches, event: event, cancelled: true)
    }

    private func finish(_ touches: Set<UITouch>, event: UIEvent?, cancelled: Bool) {
        let endPoint = activeTouches.first?.location(in: self)
        activeTouches.removeAll { touches.contains($0) }

        switch phase {
        case .pending(let start):
            cancelLongPress()
            if !cancelled {
                emit(.leftDown, at: start)
                emit(.leftUp, at: start)
            }
        case .dragging(let last):
            emit(.leftUp, at: endPoint ?? last)
        case .scrolling:
            // 손가락 하나만 떼면 남은 손가락 기준으로 계속 스크롤한다.
            if !activeTouches.isEmpty { phase = .scrolling(last: centroid()) }
        case .idle, .longPressed, .ignored:
            break
        }

        guard activeTouches.isEmpty else { return }
        let now = event?.timestamp ?? ProcessInfo.processInfo.systemUptime
        if !cancelled, maxTouches == 3, !gestureMoved, now - gestureStart < 0.5 {
            onThreeFingerTap?()
        }
        phase = .idle
    }

    private func scheduleLongPress(at p: CGPoint) {
        cancelLongPress()
        let work = DispatchWorkItem { [weak self] in
            guard let self, case .pending = self.phase else { return }
            self.emit(.rightClick, at: p)
            self.phase = .longPressed
        }
        longPressWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + longPressDelay, execute: work)
    }

    private func cancelLongPress() {
        longPressWork?.cancel()
        longPressWork = nil
    }
}

struct StreamView: UIViewRepresentable {
    @ObservedObject var session: ViewerSession
    var inputEnabled: Bool
    var onThreeFingerTap: () -> Void

    func makeUIView(context: Context) -> StreamUIView {
        let view = StreamUIView(displayLayer: session.displayLayer)
        let session = self.session
        view.onInput = { [weak session] event in session?.send(event) }
        return view
    }

    func updateUIView(_ view: StreamUIView, context: Context) {
        view.videoSize = session.videoSize
        view.inputEnabled = inputEnabled
        view.onThreeFingerTap = onThreeFingerTap
    }
}
