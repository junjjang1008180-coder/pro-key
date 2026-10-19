import CoreVideo
import Foundation
import PaperKeyboardRecognition
import PaperKeyboardShared
import QuartzCore

/// 인식 파이프라인: 카메라 프레임 → 마커 검출(`MarkerDetector`) → 보정 고정(`CalibrationLock`)
/// → (고정된 뒤) 손끝 추적(`FingertipTracker`) → 종이 좌표 + 스무딩 → 누름 판정(`PressDetector`).
/// 누른 키는 `onKeyPress`로 바로 내보낸다 (화면 갱신처럼 건너뛰면 안 되므로).
/// `process`는 카메라의 `videoQueue`에서만 부른다. 결과는 `onSnapshot`으로 내보낸다 (같은 큐, 초당 약 15번).
final class PaperKeyboardDetector {
    /// 화면 표시용 결과. 좌표는 모두 원본 카메라 버퍼의 픽셀.
    struct Snapshot {
        var imageSize = PixelSize(width: 1, height: 1)
        /// 마커 후보 덩어리 중심 (디버그 표시).
        var candidates: [PixelPoint] = []
        /// 이번 프레임에서 찾은 네 마커. 못 찾으면 nil.
        var markers: CornerQuad<PixelPoint>?
        var failure: MarkerDetector.Failure?
        var lockState: CalibrationLock.State = .searching
        /// 고정된 픽셀 ↔ 종이 변환.
        var mapping: PaperMapping?
        var detectionMilliseconds = 0.0
        /// 검지 손끝. 신뢰도가 낮으면 `paper`가 nil (화면에 회색으로 표시).
        var fingertip: Fingertip?
        /// 손끝이 올라가 있는 키.
        var hoveredKeyID: String?
        var handMilliseconds = 0.0
        /// 누름 판정 상태와 판정에 쓰인 값 (튜닝용).
        var press: PressDetector.Diagnostics?
        /// 영상을 읽지 못하는 등 인식을 못 한 이유.
        var problem: String?
    }

    struct Fingertip {
        /// 원본 버퍼 픽셀 (스무딩한 종이 좌표를 되돌린 값).
        var pixel: PixelPoint
        /// 스무딩한 종이 좌표 (mm). 신뢰도가 낮은 프레임은 nil.
        var paper: PaperPoint?
        var confidence: Double
    }

    let layout: KeyboardLayout
    var onSnapshot: ((Snapshot) -> Void)?
    /// 누름이 확정된 키. `videoQueue`에서 불린다.
    var onKeyPress: ((KeyboardLayout.Key) -> Void)?

    private var settings: RecognitionSettings
    private let detector: MarkerDetector
    private var calibration: CalibrationLock
    private let tracker = FingertipTracker()
    private var smoother: FingertipSmoother
    private var press: PressDetector
    private var frameTime = 0.0
    private var frameIndex = 0
    private var lastPublishTime = 0.0
    private var lastPublishedState: CalibrationLock.State?
    private var last = Snapshot()

    // 재보정 버튼·설정 변경은 메인 스레드에서 오므로, 다음 프레임에서 처리하도록 표시만 해 둔다.
    private let resetLock = NSLock()
    private var resetRequested = false
    private var pendingSettings: RecognitionSettings?
    private var pendingCaptureRotation: Double?
    /// 원본 영상을 수평으로 만드는 시계 방향 각도. 영상에서 실제 위쪽(손끝을 드는 방향)을 구할 때 쓴다.
    private var captureRotation = 0.0

    init(layout: KeyboardLayout, settings: RecognitionSettings = RecognitionSettings()) {
        self.layout = layout
        self.settings = settings
        self.detector = MarkerDetector(layout: layout, settings: settings)
        self.calibration = CalibrationLock(markerPaper: layout.markerCenters, settings: settings)
        self.smoother = FingertipSmoother(settings: settings)
        self.press = PressDetector(layout: layout, settings: settings)
    }

    /// 카메라가 바뀌거나 기기를 돌렸을 때. 다음 프레임부터 적용된다.
    func update(captureRotation: Double) {
        resetLock.lock()
        pendingCaptureRotation = captureRotation
        resetLock.unlock()
    }

    /// 판정 임계값 바꾸기 (디버그 화면). 다음 프레임부터 적용된다.
    func update(settings: RecognitionSettings) {
        resetLock.lock()
        pendingSettings = settings
        resetLock.unlock()
    }

    /// 재보정: 다음 프레임부터 종이를 처음부터 다시 찾는다. 아무 스레드에서나 불러도 된다.
    func recalibrate() {
        resetLock.lock()
        resetRequested = true
        resetLock.unlock()
    }

    func process(_ buffer: CVPixelBuffer, time: Double) {
        resetLock.lock()
        let reset = resetRequested
        resetRequested = false
        let newSettings = pendingSettings
        pendingSettings = nil
        if let rotation = pendingCaptureRotation { captureRotation = rotation }
        pendingCaptureRotation = nil
        resetLock.unlock()
        if let newSettings {
            settings = newSettings
            smoother.settings = newSettings
            press.settings = newSettings
        }
        if reset {
            calibration.reset()
            smoother.reset()
            press.reset()
        }
        frameTime = time

        frameIndex += 1
        last.imageSize = PixelSize(width: Double(CVPixelBufferGetWidth(buffer)), height: Double(CVPixelBufferGetHeight(buffer)))
        last.problem = nil

        // 1) 마커: 고정 전에는 매 프레임, 고정 뒤에는 밀림 확인용으로 몇 프레임에 한 번.
        if calibration.state != .locked || frameIndex % settings.lockedDetectionInterval == 0 {
            guard detectMarkers(in: buffer) else {
                publish(force: false)
                return
            }
        }
        last.lockState = calibration.state
        last.mapping = calibration.mapping

        // 2) 손끝: 종이 좌표로 바꿀 변환이 있을 때만.
        let observation = trackFingertip(in: buffer)

        // 3) 누름 판정. 변환이 없으면(종이를 다시 찾는 중) 판정도 처음부터.
        if let observation {
            if let key = press.process(observation) { onKeyPress?(key) }
            last.press = press.diagnostics
            // 닿는 중이면 공중의 (밀려 보이는) 손끝 아래가 아니라 실제로 닿은 키를 보여 준다.
            switch press.state {
            case .touching(let id?), .resting(let id?): last.hoveredKeyID = id
            default: break
            }
        } else {
            press.reset()
            last.press = nil
        }
        publish(force: calibration.state != lastPublishedState)
    }

    /// 영상을 읽지 못하면 false.
    private func detectMarkers(in buffer: CVPixelBuffer) -> Bool {
        let start = CACurrentMediaTime()
        guard let (image, step) = Self.grayImage(from: buffer, targetWidth: settings.detectionImageWidth) else {
            last.problem = "카메라 영상 형식을 읽을 수 없음 (\(CVPixelBufferGetPixelFormatType(buffer)))"
            return false
        }
        let detection = detector.detect(in: image)
        // 줄인 이미지 좌표 × step = 원본 버퍼 좌표
        let scale = Double(step)
        let toOriginal = { (p: PixelPoint) in PixelPoint(x: p.x * scale, y: p.y * scale) }
        let markers = detection.markers?.map(toOriginal)
        calibration.update(markers: markers)

        last.candidates = detection.candidates.map { toOriginal($0.center) }
        last.markers = markers
        if case .failure(let failure) = detection.result { last.failure = failure } else { last.failure = nil }
        last.detectionMilliseconds = (CACurrentMediaTime() - start) * 1000
        return true
    }

    /// 누름 판정에 넣을 관측값. 종이 변환이 없거나 손 인식이 실패하면 nil.
    private func trackFingertip(in buffer: CVPixelBuffer) -> PressDetector.Observation? {
        guard let mapping = calibration.mapping else {
            last.fingertip = nil
            last.hoveredKeyID = nil
            smoother.reset()
            return nil
        }
        // 맞은편 웹캠이면 180°: Vision에 손이 바로 선 모습으로 넘긴다.
        let rotation = mapping.uprightRotationDegrees(paperWidth: layout.paperWidth, paperHeight: layout.paperHeight) ?? 0
        let start = CACurrentMediaTime()
        let result: FingertipTracker.Result?
        do {
            result = try tracker.detect(in: buffer, uprightRotation: rotation)
        } catch {
            last.problem = "손 인식 오류: \(error.localizedDescription)"
            return nil
        }
        last.handMilliseconds = (CACurrentMediaTime() - start) * 1000

        guard let result, let paper = mapping.paper(fromPixel: result.pixel) else {
            // 손이 안 보임
            last.fingertip = nil
            last.hoveredKeyID = nil
            smoother.reset()
            return .noHand(at: frameTime)
        }
        // 손끝을 들면 영상에서 실제 위쪽으로 움직인다 → 종이 좌표에서의 그 방향이 누름 판정의 "들림" 방향.
        let angle = captureRotation * .pi / 180
        let lift = mapping.paperDirection(at: result.pixel, pixelDirection: (x: -sin(angle), y: -cos(angle)))
        guard result.confidence >= settings.minConfidence else {
            // 신뢰도가 낮은 프레임: 손이 사라진 것과 구분해, 위치만 회색으로 보여 주고 키 판단은 하지 않는다.
            // 누름 판정기도 신뢰도를 보고 이 프레임을 버린다 (상태 유지).
            last.fingertip = Fingertip(pixel: result.pixel, paper: nil, confidence: result.confidence)
            last.hoveredKeyID = nil
            return .fingertip(paper, confidence: result.confidence, liftDirection: lift, at: frameTime)
        }
        let smoothed = smoother.smooth(paper, at: frameTime)
        last.fingertip = Fingertip(pixel: mapping.pixel(fromPaper: smoothed) ?? result.pixel, paper: smoothed, confidence: result.confidence)
        last.hoveredKeyID = layout.key(at: smoothed)?.id
        return .fingertip(smoothed, confidence: result.confidence, liftDirection: lift, at: frameTime)
    }

    /// 상태가 바뀌면 바로, 아니면 초당 15번 정도만 화면에 보낸다.
    private func publish(force: Bool) {
        let now = CACurrentMediaTime()
        guard force || now - lastPublishTime >= 1.0 / 15 else { return }
        lastPublishTime = now
        lastPublishedState = last.lockState
        onSnapshot?(last)
    }

    /// 버퍼를 잠그고 밝기만 뽑아 `targetWidth` 정도로 줄인다. 반환하는 step을 곱하면 원본 좌표.
    private static func grayImage(from buffer: CVPixelBuffer, targetWidth: Int) -> (GrayImage, Int)? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }

        let width = CVPixelBufferGetWidth(buffer)
        let height = CVPixelBufferGetHeight(buffer)
        let step = max(1, width / targetWidth)

        switch CVPixelBufferGetPixelFormatType(buffer) {
        case kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange:
            guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, 0) else { return nil }
            let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
            let bytes = UnsafeRawBufferPointer(start: base, count: bytesPerRow * height)
            return GrayImage(luma: bytes, width: width, height: height, bytesPerRow: bytesPerRow, step: step).map { ($0, step) }
        case kCVPixelFormatType_32BGRA:
            guard let base = CVPixelBufferGetBaseAddress(buffer) else { return nil }
            let bytesPerRow = CVPixelBufferGetBytesPerRow(buffer)
            let bytes = UnsafeRawBufferPointer(start: base, count: bytesPerRow * height)
            return GrayImage(bgra: bytes, width: width, height: height, bytesPerRow: bytesPerRow, step: step).map { ($0, step) }
        default:
            return nil
        }
    }
}
