import Foundation
import PaperKeyboardShared

/// 손끝 좌표 떨림을 줄이는 지수 이동 평균. FingertipTracker가 Vision 결과를 종이 좌표로 바꾼 뒤 적용한다.
public struct FingertipSmoother: Sendable {
    public var settings: RecognitionSettings
    private var last: (time: Double, point: PaperPoint)?

    public init(settings: RecognitionSettings) {
        self.settings = settings
    }

    public mutating func smooth(_ point: PaperPoint, at time: Double) -> PaperPoint {
        let alpha = min(max(settings.smoothingFactor, 0), 1)
        guard let last, time - last.time <= settings.maxSampleGap else {
            self.last = (time, point)
            return point
        }
        let smoothed = PaperPoint(
            x: last.point.x + alpha * (point.x - last.point.x),
            y: last.point.y + alpha * (point.y - last.point.y)
        )
        self.last = (time, smoothed)
        return smoothed
    }

    public mutating func reset() {
        last = nil
    }
}
