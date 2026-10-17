import CoreVideo
import ImageIO
import PaperKeyboardRecognition
import Vision

/// Vision 손 모양 인식으로 검지 손끝(`indexTip`)을 찾는다. 메인 앱 전용 (키보드 확장에 넣지 말 것).
/// v1은 손가락 하나만: 보이는 손 중 검지 끝 신뢰도가 가장 높은 손을 쓴다 (ARCHITECTURE 4절).
final class FingertipTracker {
    struct Result {
        /// 원본 버퍼 픽셀 좌표 (마커와 같은 공간).
        let pixel: PixelPoint
        let confidence: Double
    }

    private let request: VNDetectHumanHandPoseRequest = {
        let request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = 2
        return request
    }()

    /// - uprightRotation: 종이가 똑바로 보이게 하는 시계 방향 각도. 같은 방향으로 돌려 넘기면
    ///   손이 바로 선 모습으로 보여 인식이 잘 된다. 결과는 원본 버퍼 좌표로 되돌려 준다.
    /// - Returns: 손이 없으면 nil.
    func detect(in buffer: CVPixelBuffer, uprightRotation: Double) throws -> Result? {
        let handler = VNImageRequestHandler(cvPixelBuffer: buffer, orientation: Self.orientation(for: uprightRotation))
        try handler.perform([request])

        let tips = (request.results ?? []).compactMap { try? $0.recognizedPoint(.indexTip) }
        guard let best = tips.max(by: { $0.confidence < $1.confidence }), best.confidence > 0 else { return nil }

        let size = PixelSize(width: Double(CVPixelBufferGetWidth(buffer)), height: Double(CVPixelBufferGetHeight(buffer)))
        let pixel = CoordinateMapper.pixel(
            fromVision: NormalizedPoint(x: best.location.x, y: best.location.y),
            imageSize: size,
            uprightRotation: uprightRotation
        )
        return Result(pixel: pixel, confidence: Double(best.confidence))
    }

    /// 시계 방향으로 이만큼 돌려야 바로 서는 이미지 = EXIF 방향.
    private static func orientation(for uprightRotation: Double) -> CGImagePropertyOrientation {
        switch ((Int((uprightRotation / 90).rounded()) % 4) + 4) % 4 {
        case 1: .right
        case 2: .down
        case 3: .left
        default: .up
        }
    }
}
