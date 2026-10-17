import Foundation
import Testing
import PaperKeyboardShared
@testable import PaperKeyboardRecognition

struct CalibrationLockTests {
    static let layout = try! KeyboardLayout.bundledQWERTY()
    static let base = CornerQuad(
        topLeft: PixelPoint(x: 150, y: 70),
        topRight: PixelPoint(x: 810, y: 80),
        bottomRight: PixelPoint(x: 800, y: 500),
        bottomLeft: PixelPoint(x: 160, y: 480)
    )
    static let required = RecognitionSettings().lockFrameCount

    static func shifted(_ quad: CornerQuad<PixelPoint>, dx: Double, dy: Double = 0) -> CornerQuad<PixelPoint> {
        quad.map { PixelPoint(x: $0.x + dx, y: $0.y + dy) }
    }

    static func lockedCalibration() -> CalibrationLock {
        var lock = CalibrationLock(markerPaper: layout.markerCenters)
        for _ in 0..<required { lock.update(markers: base) }
        return lock
    }

    @Test func 안정된_프레임이_모이면_고정한다() {
        var lock = CalibrationLock(markerPaper: Self.layout.markerCenters)
        for frame in 1..<Self.required {
            #expect(lock.update(markers: Self.base) == .stabilizing(frames: frame, required: Self.required))
        }
        #expect(lock.mapping == nil)
        #expect(lock.update(markers: Self.base) == .locked)
        #expect(lock.mapping != nil)
    }

    @Test func 움직이는_중이면_처음부터_다시_센다() {
        var lock = CalibrationLock(markerPaper: Self.layout.markerCenters)
        for _ in 0..<5 { lock.update(markers: Self.base) }
        #expect(lock.update(markers: Self.shifted(Self.base, dx: 20)) == .stabilizing(frames: 1, required: Self.required))
    }

    @Test func 마커를_놓치면_찾는_중으로_돌아간다() {
        var lock = CalibrationLock(markerPaper: Self.layout.markerCenters)
        for _ in 0..<5 { lock.update(markers: Self.base) }
        #expect(lock.update(markers: nil) == .searching)
        for _ in 0..<Self.required { lock.update(markers: Self.base) }
        #expect(lock.state == .locked)
    }

    @Test func 고정값은_흔들림의_평균이다() throws {
        var lock = CalibrationLock(markerPaper: Self.layout.markerCenters)
        for frame in 0..<Self.required {
            lock.update(markers: Self.shifted(Self.base, dx: frame.isMultiple(of: 2) ? 2 : -2))
        }
        let locked = try #require(lock.lockedMarkers)
        #expect(abs(locked.topLeft.x - Self.base.topLeft.x) < 1e-9)
    }

    @Test func 고정_후_손이_마커를_가려도_유지한다() {
        var lock = Self.lockedCalibration()
        let mapping = lock.mapping
        for _ in 0..<100 { lock.update(markers: nil) }
        #expect(lock.state == .locked)
        #expect(lock.mapping == mapping)
    }

    @Test func 마커_하나만_벗어나면_종이가_밀린_것으로_보지_않는다() {
        var lock = Self.lockedCalibration()
        var oneOff = Self.base
        oneOff.bottomRight = PixelPoint(x: oneOff.bottomRight.x - 30, y: oneOff.bottomRight.y)
        for _ in 0..<50 { lock.update(markers: oneOff) }
        #expect(lock.state == .locked)
    }

    @Test func 종이가_밀리면_재보정_필요를_알리고_기존_변환은_유지한다() {
        var lock = Self.lockedCalibration()
        let mapping = lock.mapping
        let moved = Self.shifted(Self.base, dx: 30)
        let frames = RecognitionSettings().driftFrameCount
        for _ in 1..<frames { #expect(lock.update(markers: moved) == .locked) }
        #expect(lock.update(markers: moved) == .needsRecalibration)
        #expect(lock.mapping == mapping)
        // 재보정 버튼을 누르기 전에는 그대로
        for _ in 0..<20 { lock.update(markers: Self.base) }
        #expect(lock.state == .needsRecalibration)
    }

    @Test func 한두_프레임_튀는_것은_무시한다() {
        var lock = Self.lockedCalibration()
        let moved = Self.shifted(Self.base, dx: 30)
        let frames = RecognitionSettings().driftFrameCount
        for _ in 1..<frames { lock.update(markers: moved) }
        lock.update(markers: Self.base)
        for _ in 1..<frames { lock.update(markers: moved) }
        #expect(lock.state == .locked)
    }

    @Test func 재보정하면_처음부터_다시_찾는다() {
        var lock = Self.lockedCalibration()
        lock.reset()
        #expect(lock.state == .searching)
        #expect(lock.mapping == nil)
        #expect(lock.lockedMarkers == nil)
    }
}
