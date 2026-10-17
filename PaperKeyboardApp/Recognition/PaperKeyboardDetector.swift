import CoreVideo
import Foundation
import PaperKeyboardRecognition
import PaperKeyboardShared
import QuartzCore

/// 카메라 프레임 → 마커 검출(`MarkerDetector`) → 보정 고정(`CalibrationLock`).
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
        /// 영상을 읽지 못하는 등 검출을 아예 못 한 이유.
        var problem: String?
    }

    let layout: KeyboardLayout
    var onSnapshot: ((Snapshot) -> Void)?

    private let settings: RecognitionSettings
    private let detector: MarkerDetector
    private var calibration: CalibrationLock
    private var frameIndex = 0
    private var lastPublishTime = 0.0
    private var lastPublishedState: CalibrationLock.State?
    private var last = Snapshot()

    // 재보정 버튼은 메인 스레드에서 눌리므로, 다음 프레임에서 처리하도록 표시만 해 둔다.
    private let resetLock = NSLock()
    private var resetRequested = false

    init(layout: KeyboardLayout, settings: RecognitionSettings = RecognitionSettings()) {
        self.layout = layout
        self.settings = settings
        self.detector = MarkerDetector(layout: layout, settings: settings)
        self.calibration = CalibrationLock(markerPaper: layout.markerCenters, settings: settings)
    }

    /// 재보정: 다음 프레임부터 종이를 처음부터 다시 찾는다. 아무 스레드에서나 불러도 된다.
    func recalibrate() {
        resetLock.lock()
        resetRequested = true
        resetLock.unlock()
    }

    func process(_ buffer: CVPixelBuffer) {
        resetLock.lock()
        let reset = resetRequested
        resetRequested = false
        resetLock.unlock()
        if reset { calibration.reset() }

        frameIndex += 1
        if calibration.state == .locked, frameIndex % settings.lockedDetectionInterval != 0 { return }

        let start = CACurrentMediaTime()
        guard let (image, step) = Self.grayImage(from: buffer, targetWidth: settings.detectionImageWidth) else {
            last.problem = "카메라 영상 형식을 읽을 수 없음 (\(CVPixelBufferGetPixelFormatType(buffer)))"
            publish(force: false)
            return
        }
        let detection = detector.detect(in: image)
        // 줄인 이미지 좌표 × step = 원본 버퍼 좌표
        let scale = Double(step)
        let toOriginal = { (p: PixelPoint) in PixelPoint(x: p.x * scale, y: p.y * scale) }
        let markers = detection.markers?.map(toOriginal)
        calibration.update(markers: markers)

        last = Snapshot(
            imageSize: PixelSize(width: Double(CVPixelBufferGetWidth(buffer)), height: Double(CVPixelBufferGetHeight(buffer))),
            candidates: detection.candidates.map { toOriginal($0.center) },
            markers: markers,
            failure: { if case .failure(let failure) = detection.result { return failure } else { return nil } }(),
            lockState: calibration.state,
            mapping: calibration.mapping,
            detectionMilliseconds: (CACurrentMediaTime() - start) * 1000
        )
        publish(force: calibration.state != lastPublishedState)
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
