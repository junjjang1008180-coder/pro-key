import AVFoundation
import PaperKeyboardRecognition
import PaperKeyboardShared
import SwiftUI

/// 카메라 프리뷰 + 인식 결과 겹쳐 그리기.
/// 인식 좌표(원본 버퍼 픽셀)를 화면 좌표로 바꿀 때는 프리뷰 레이어의 변환을 쓴다.
/// 그래서 프리뷰가 화면에서 좌우 반전되거나 회전돼도 겹쳐 그린 선이 영상과 같이 따라간다.
/// 화면은 좌우 반전하지 않고(인쇄된 글자가 바로 읽히게), 종이를 고정하면 종이가 똑바로 보이도록 돌린다.
struct CameraOverlayView: UIViewRepresentable {
    let session: AVCaptureSession
    let device: AVCaptureDevice?
    let snapshot: PaperKeyboardDetector.Snapshot
    let layout: KeyboardLayout
    /// nil이면 기기 방향 기준(수평)으로, 값이 있으면 그 각도로 프리뷰를 돌린다.
    let paperRotation: Double?

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspect
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ view: PreviewView, context: Context) {
        view.attach(device: device)
        view.paperRotation = paperRotation.map { CGFloat($0) }
        view.overlay.update(snapshot: snapshot, layout: layout)
    }
}

final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    let overlay = OverlayView()

    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?
    var paperRotation: CGFloat? {
        didSet { if paperRotation != oldValue { applyCurrentRotation() } }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        overlay.previewLayer = previewLayer
        overlay.backgroundColor = .clear
        overlay.isOpaque = false
        addSubview(overlay)
    }

    required init?(coder: NSCoder) { fatalError("코드로만 만든다") }

    override func layoutSubviews() {
        super.layoutSubviews()
        overlay.frame = bounds
        applyCurrentRotation()
        overlay.setNeedsDisplay()
    }

    /// 기기 방향에 맞춰 프리뷰를 돌린다. 인식용 버퍼는 돌리지 않는다.
    func attach(device: AVCaptureDevice?) {
        guard let device, rotationCoordinator?.device != device else { return }
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
        rotationCoordinator = coordinator
        applyCurrentRotation()
        rotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.applyCurrentRotation() }
        }
    }

    /// 종이를 고정했으면 종이 기준 각도, 아니면 기기 방향 기준 각도로 돌린다.
    private func applyCurrentRotation() {
        guard let connection = previewLayer.connection else { return }
        // 웹캠·전면 카메라 프리뷰는 기본으로 거울처럼 좌우 반전되는데, 그러면 인쇄된 글자가 뒤집혀 보인다.
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = false
        }
        let angle = paperRotation ?? rotationCoordinator?.videoRotationAngleForHorizonLevelPreview ?? 0
        if connection.isVideoRotationAngleSupported(angle) { connection.videoRotationAngle = angle }
        overlay.setNeedsDisplay()
    }
}

/// 마커 후보(회색 점), 찾은 네 마커(색 동그라미), 고정된 뒤에는 모든 키 테두리와 글자를 그린다.
final class OverlayView: UIView {
    weak var previewLayer: AVCaptureVideoPreviewLayer?
    private var snapshot = PaperKeyboardDetector.Snapshot()
    private var layout: KeyboardLayout?

    func update(snapshot: PaperKeyboardDetector.Snapshot, layout: KeyboardLayout) {
        self.snapshot = snapshot
        self.layout = layout
        setNeedsDisplay()
    }

    /// 원본 버퍼 픽셀 → 이 뷰의 좌표. 버퍼는 회전·미러링하지 않았으므로 "카메라 기기 좌표(0~1)"와 같다.
    private func viewPoint(_ point: PixelPoint) -> CGPoint? {
        guard let previewLayer else { return nil }
        let size = snapshot.imageSize
        return previewLayer.layerPointConverted(fromCaptureDevicePoint: CGPoint(x: point.x / size.width, y: point.y / size.height))
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }

        if let mapping = snapshot.mapping, let layout {
            let color: UIColor = snapshot.lockState == .needsRecalibration ? .systemOrange : .systemGreen
            if let id = snapshot.hoveredKeyID, let key = layout.key(withID: id) {
                fillKey(key, mapping: mapping, in: context)
            }
            drawKeys(layout: layout, mapping: mapping, color: color, in: context)
        }

        // 검지 손끝: 빨간 점, 신뢰도가 낮으면 회색
        if let tip = snapshot.fingertip, let p = viewPoint(tip.pixel) {
            let color = tip.paper == nil ? UIColor.systemGray : UIColor.systemRed
            context.setFillColor(color.cgColor)
            context.fillEllipse(in: CGRect(x: p.x - 9, y: p.y - 9, width: 18, height: 18))
            context.setStrokeColor(UIColor.white.cgColor)
            context.setLineWidth(2)
            context.strokeEllipse(in: CGRect(x: p.x - 9, y: p.y - 9, width: 18, height: 18))
        }

        // 후보 덩어리
        context.setFillColor(UIColor.systemGray.withAlphaComponent(0.8).cgColor)
        for candidate in snapshot.candidates {
            guard let p = viewPoint(candidate) else { continue }
            context.fillEllipse(in: CGRect(x: p.x - 3, y: p.y - 3, width: 6, height: 6))
        }

        // 이번 프레임에서 찾은 네 마커: 어느 모서리로 판단했는지 색과 글자로 표시
        if let markers = snapshot.markers {
            let named: [(PixelPoint, String, UIColor)] = [
                (markers.topLeft, "왼쪽 위", .systemRed), (markers.topRight, "오른쪽 위", .systemBlue),
                (markers.bottomRight, "오른쪽 아래", .systemPurple), (markers.bottomLeft, "왼쪽 아래", .systemYellow),
            ]
            for (marker, name, color) in named {
                guard let p = viewPoint(marker) else { continue }
                context.setStrokeColor(color.cgColor)
                context.setLineWidth(3)
                context.strokeEllipse(in: CGRect(x: p.x - 14, y: p.y - 14, width: 28, height: 28))
                drawLabel(name, at: CGPoint(x: p.x, y: p.y + 26), color: color, size: 12)
            }
        }
    }

    /// 손끝이 올라간 키를 노랗게 칠한다.
    private func fillKey(_ key: KeyboardLayout.Key, mapping: PaperMapping, in context: CGContext) {
        guard let corners = mapping.pixelCorners(of: key.frame)?.compactMap(viewPoint), corners.count == 4 else { return }
        context.setFillColor(UIColor.systemYellow.withAlphaComponent(0.45).cgColor)
        context.addLines(between: corners)
        context.closePath()
        context.fillPath()
    }

    private func drawKeys(layout: KeyboardLayout, mapping: PaperMapping, color: UIColor, in context: CGContext) {
        context.setStrokeColor(color.cgColor)
        context.setLineWidth(1.5)
        for key in layout.keys {
            guard let corners = mapping.pixelCorners(of: key.frame)?.compactMap(viewPoint), corners.count == 4 else { continue }
            context.addLines(between: corners + [corners[0]])
            context.strokePath()
            // 글자가 인쇄된 키와 같은 자리에 오면 좌우 반전 없이 맞게 인식된 것.
            if let center = mapping.pixel(fromPaper: key.frame.center).flatMap(viewPoint) {
                let label = key.kind == .space ? "Space" : key.label
                drawLabel(label, at: center, color: color, size: key.kind == .char ? 13 : 10)
            }
        }
    }

    private func drawLabel(_ text: String, at point: CGPoint, color: UIColor, size: CGFloat) {
        let shadow = NSShadow()
        shadow.shadowColor = UIColor.black
        shadow.shadowBlurRadius = 3
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: size, weight: .bold),
            .foregroundColor: color,
            .shadow: shadow,
        ]
        let string = NSAttributedString(string: text, attributes: attributes)
        let bounds = string.size()
        string.draw(at: CGPoint(x: point.x - bounds.width / 2, y: point.y - bounds.height / 2))
    }
}
