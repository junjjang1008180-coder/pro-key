import AVFoundation
import SwiftUI

/// 카메라 프리뷰. 실험 3(종이와 손이 함께 보이는지)을 위해 화면을 자르지 않고 전체 화각을 보여준다.
struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    let device: AVCaptureDevice?

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspect
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        uiView.attach(device: device)
    }
}

final class PreviewView: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }

    private var rotationCoordinator: AVCaptureDevice.RotationCoordinator?
    private var rotationObservation: NSKeyValueObservation?

    /// 기기 방향(가로/세로)에 맞춰 프리뷰를 돌린다.
    func attach(device: AVCaptureDevice?) {
        guard let device, rotationCoordinator?.device != device else { return }
        let coordinator = AVCaptureDevice.RotationCoordinator(device: device, previewLayer: previewLayer)
        rotationCoordinator = coordinator
        applyRotation(coordinator.videoRotationAngleForHorizonLevelPreview)
        rotationObservation = coordinator.observe(\.videoRotationAngleForHorizonLevelPreview, options: [.new]) { [weak self] coordinator, _ in
            DispatchQueue.main.async { self?.applyRotation(coordinator.videoRotationAngleForHorizonLevelPreview) }
        }
    }

    private func applyRotation(_ angle: CGFloat) {
        guard let connection = previewLayer.connection, connection.isVideoRotationAngleSupported(angle) else { return }
        connection.videoRotationAngle = angle
    }
}
