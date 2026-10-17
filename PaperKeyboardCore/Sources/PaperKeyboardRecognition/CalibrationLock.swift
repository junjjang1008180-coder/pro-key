import Foundation
import PaperKeyboardShared

/// 보정 고정. 네 마커가 연속으로 안정되면 그 평균 위치로 종이 좌표 변환을 고정하고,
/// 그 뒤에는 손이 마커를 가려도 고정값을 계속 쓴다. 마커가 다시 보일 때 크게 벗어나 있으면
/// (종이가 밀림) "재보정 필요"로 알린다. 재보정 버튼은 `reset()`을 부른다.
public struct CalibrationLock: Sendable {
    public enum State: Equatable, Sendable {
        /// 네 마커를 아직 모두 찾지 못함.
        case searching
        /// 안정 확인 중 (frames / required).
        case stabilizing(frames: Int, required: Int)
        case locked
        /// 종이가 밀린 것 같음. 새로 잡기 전까지는 기존 변환을 계속 쓴다.
        case needsRecalibration
    }

    public private(set) var state: State = .searching
    /// 고정된 픽셀 ↔ 종이 변환. 고정 전이면 nil.
    public private(set) var mapping: PaperMapping?
    /// 고정할 때 쓴 마커 위치 (평균). 디버그 화면 표시용.
    public private(set) var lockedMarkers: CornerQuad<PixelPoint>?

    private let markerPaper: CornerQuad<PaperPoint>
    private let settings: RecognitionSettings
    private var recent: [CornerQuad<PixelPoint>] = []
    private var driftFrames = 0

    /// `markerPaper`는 레이아웃의 마커 중심 (`KeyboardLayout.markerCenters`).
    public init(markerPaper: CornerQuad<PaperPoint>, settings: RecognitionSettings = RecognitionSettings()) {
        self.markerPaper = markerPaper
        self.settings = settings
    }

    /// 프레임마다 검출 결과를 넣는다. 네 마커를 다 찾지 못한 프레임은 nil.
    @discardableResult
    public mutating func update(markers: CornerQuad<PixelPoint>?) -> State {
        switch state {
        case .searching, .stabilizing:
            stabilize(with: markers)
        case .locked:
            checkDrift(with: markers)
        case .needsRecalibration:
            break
        }
        return state
    }

    /// 재보정: 고정을 풀고 처음부터 다시 찾는다.
    public mutating func reset() {
        state = .searching
        mapping = nil
        lockedMarkers = nil
        recent.removeAll()
        driftFrames = 0
    }

    private mutating func stabilize(with markers: CornerQuad<PixelPoint>?) {
        guard let markers else {
            recent.removeAll()
            state = .searching
            return
        }
        // 첫 프레임에서 너무 멀어졌으면(아직 움직이는 중) 처음부터 다시 센다.
        if let first = recent.first, Self.maxDistance(first, markers) > settings.lockMaxJitter * Self.diagonal(first) {
            recent.removeAll()
        }
        recent.append(markers)
        guard recent.count >= settings.lockFrameCount else {
            state = .stabilizing(frames: recent.count, required: settings.lockFrameCount)
            return
        }

        let averaged = Self.average(recent)
        recent.removeAll()
        guard let newMapping = PaperMapping(markerPixels: averaged, markerPaper: markerPaper) else {
            state = .searching
            return
        }
        mapping = newMapping
        lockedMarkers = averaged
        driftFrames = 0
        state = .locked
    }

    private mutating func checkDrift(with markers: CornerQuad<PixelPoint>?) {
        // 손이 마커를 가린 프레임: 고정값 유지.
        guard let markers, let lockedMarkers else { return }
        let limit = settings.driftThreshold * Self.diagonal(lockedMarkers)
        let movedCorners = zip(lockedMarkers.all, markers.all).filter { Self.distance($0, $1) > limit }.count
        // 종이가 밀리면 마커 여러 개가 함께 움직인다. 하나만 벗어난 것은 손에 일부 가려진 경우로 본다.
        if movedCorners >= 2 {
            driftFrames += 1
            if driftFrames >= settings.driftFrameCount { state = .needsRecalibration }
        } else {
            driftFrames = 0
        }
    }

    // MARK: - 계산

    static func distance(_ a: PixelPoint, _ b: PixelPoint) -> Double {
        hypot(a.x - b.x, a.y - b.y)
    }

    static func maxDistance(_ a: CornerQuad<PixelPoint>, _ b: CornerQuad<PixelPoint>) -> Double {
        zip(a.all, b.all).map { distance($0, $1) }.max() ?? 0
    }

    static func diagonal(_ quad: CornerQuad<PixelPoint>) -> Double {
        distance(quad.topLeft, quad.bottomRight)
    }

    static func average(_ quads: [CornerQuad<PixelPoint>]) -> CornerQuad<PixelPoint> {
        func mean(_ corner: KeyPath<CornerQuad<PixelPoint>, PixelPoint>) -> PixelPoint {
            let points = quads.map { $0[keyPath: corner] }
            return PixelPoint(
                x: points.map(\.x).reduce(0, +) / Double(points.count),
                y: points.map(\.y).reduce(0, +) / Double(points.count)
            )
        }
        return CornerQuad(topLeft: mean(\.topLeft), topRight: mean(\.topRight), bottomRight: mean(\.bottomRight), bottomLeft: mean(\.bottomLeft))
    }
}
