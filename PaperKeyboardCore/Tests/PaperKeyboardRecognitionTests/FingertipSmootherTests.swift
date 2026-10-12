import Foundation
import Testing
import PaperKeyboardShared
@testable import PaperKeyboardRecognition

struct FingertipSmootherTests {
    @Test func 새_값_비중만큼_따라간다() {
        var settings = RecognitionSettings()
        settings.smoothingFactor = 0.5
        var smoother = FingertipSmoother(settings: settings)
        #expect(smoother.smooth(PaperPoint(x: 0, y: 0), at: 0) == PaperPoint(x: 0, y: 0))
        #expect(smoother.smooth(PaperPoint(x: 10, y: 20), at: 0.033) == PaperPoint(x: 5, y: 10))
    }

    @Test func 비중_1이면_그대로() {
        var settings = RecognitionSettings()
        settings.smoothingFactor = 1
        var smoother = FingertipSmoother(settings: settings)
        _ = smoother.smooth(PaperPoint(x: 0, y: 0), at: 0)
        #expect(smoother.smooth(PaperPoint(x: 10, y: 20), at: 0.033) == PaperPoint(x: 10, y: 20))
    }

    @Test func 프레임이_오래_끊기면_새로_시작한다() {
        var smoother = FingertipSmoother(settings: RecognitionSettings())
        _ = smoother.smooth(PaperPoint(x: 0, y: 0), at: 0)
        #expect(smoother.smooth(PaperPoint(x: 100, y: 100), at: 1) == PaperPoint(x: 100, y: 100))
    }
}
