import AVFoundation
import UIKit

/// 카메라 캡처. USB 웹캠이 있으면 웹캠, 없으면 전면 초광각 카메라를 쓴다 (PRD 12절 결정).
/// 세션 제어는 `sessionQueue`, 프레임은 `videoQueue`에서 처리하고 UI 상태만 메인 스레드로 보낸다.
/// 프레임은 `onFrame`으로 넘기고 저장하지 않는다.
final class CameraService: NSObject, ObservableObject {
    struct CameraOption: Identifiable, Hashable {
        let id: String
        let name: String
        let isExternal: Bool
    }

    struct Status: Equatable {
        var authorization = "확인 전"
        var isRunning = false
        var cameraName = "-"
        var isExternal = false
        var resolution = "-"
        var fps = 0.0
        var multitaskingSupported = false
        var multitaskingEnabled = false
        /// 카메라가 멈춘 이유 등 사용자에게 보여 줄 문제. 없으면 nil.
        var problem: String?
    }

    @Published private(set) var status = Status()
    @Published private(set) var cameras: [CameraOption] = []
    @Published private(set) var currentDevice: AVCaptureDevice?
    /// 사용자가 고른 카메라. nil이면 자동(웹캠 우선).
    @Published private(set) var chosenCameraID: String?

    /// 프레임마다 `videoQueue`에서 불린다. 미러링·회전하지 않은 원본 버퍼와 찍힌 시각(초).
    var onFrame: ((CVPixelBuffer, Double) -> Void)?
    /// 다른 카메라로 바뀌었을 때 (보정을 다시 해야 함). 메인 스레드.
    var onCameraChanged: (() -> Void)?

    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "camera.session")
    let videoQueue = DispatchQueue(label: "camera.video")
    private let videoOutput = AVCaptureVideoDataOutput()

    private let fpsLock = NSLock()
    private var frameCount = 0
    private var fpsTimer: Timer?
    private var lastFPSCount = 0
    private var lastFPSTime = CACurrentMediaTime()

    override init() {
        super.init()
        refreshCameras()
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(deviceConnectionChanged), name: AVCaptureDevice.wasConnectedNotification, object: nil)
        center.addObserver(self, selector: #selector(deviceConnectionChanged), name: AVCaptureDevice.wasDisconnectedNotification, object: nil)
        center.addObserver(self, selector: #selector(sessionInterrupted), name: AVCaptureSession.wasInterruptedNotification, object: session)
        center.addObserver(self, selector: #selector(interruptionEnded), name: AVCaptureSession.interruptionEndedNotification, object: session)
        center.addObserver(self, selector: #selector(runtimeError), name: AVCaptureSession.runtimeErrorNotification, object: session)
    }

    // MARK: - 시작 / 카메라 선택

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            status.authorization = "허용됨"
            configure()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    self.status.authorization = granted ? "허용됨" : "거부됨"
                    if granted { self.configure() } else { self.status.problem = "카메라 권한이 거부됨. 설정에서 허용해 주세요." }
                }
            }
        default:
            status.authorization = "거부됨"
            status.problem = "카메라 권한이 거부됨. 설정에서 허용해 주세요."
        }
    }

    /// nil이면 자동 선택(웹캠 우선)으로 돌아간다.
    func choose(cameraID: String?) {
        chosenCameraID = cameraID
        configure()
    }

    private var preferredDevice: AVCaptureDevice? {
        if let chosenCameraID, let device = AVCaptureDevice(uniqueID: chosenCameraID), device.isConnected {
            return device
        }
        // 화각이 넓어야 종이와 손이 함께 들어오므로 전면은 초광각을 먼저.
        return Self.externalCameras().first
            ?? Self.frontCameras().first { $0.deviceType == .builtInUltraWideCamera }
            ?? Self.frontCameras().first
    }

    private func refreshCameras() {
        cameras = Self.externalCameras().map { CameraOption(id: $0.uniqueID, name: "웹캠: \($0.localizedName)", isExternal: true) }
            + Self.frontCameras().map { CameraOption(id: $0.uniqueID, name: $0.localizedName, isExternal: false) }
    }

    private static func externalCameras() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.external], mediaType: .video, position: .unspecified).devices
    }

    private static func frontCameras() -> [AVCaptureDevice] {
        AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInUltraWideCamera, .builtInWideAngleCamera, .builtInTrueDepthCamera],
            mediaType: .video, position: .front
        ).devices
    }

    private func configure() {
        guard let device = preferredDevice else {
            status.problem = "사용할 카메라가 없음"
            return
        }
        let changed = device.uniqueID != currentDevice?.uniqueID
        sessionQueue.async {
            // Center Stage는 얼굴을 따라 화면을 잘라내 종이 좌표를 흔든다.
            AVCaptureDevice.centerStageControlMode = .app
            AVCaptureDevice.isCenterStageEnabled = false

            self.session.beginConfiguration()
            self.session.inputs.forEach { self.session.removeInput($0) }
            // 앞 카메라의 1080p 설정이 남아 있으면 그걸 못 하는 웹캠이 붙지 않으므로 먼저 공통 설정으로.
            self.session.sessionPreset = .high
            guard let input = try? AVCaptureDeviceInput(device: device), self.session.canAddInput(input) else {
                self.session.commitConfiguration()
                self.report(problem: "카메라를 연결하지 못함: \(device.localizedName)")
                return
            }
            self.session.addInput(input)
            self.session.sessionPreset = self.session.canSetSessionPreset(.hd1920x1080) ? .hd1920x1080 : .high

            if !self.session.outputs.contains(self.videoOutput) {
                self.videoOutput.alwaysDiscardsLateVideoFrames = true
                let wanted = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
                let format = self.videoOutput.availableVideoPixelFormatTypes.contains(wanted) ? wanted : kCVPixelFormatType_32BGRA
                self.videoOutput.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: format]
                self.videoOutput.setSampleBufferDelegate(self, queue: self.videoQueue)
                guard self.session.canAddOutput(self.videoOutput) else {
                    self.session.commitConfiguration()
                    self.report(problem: "카메라 영상을 받을 수 없음")
                    return
                }
                self.session.addOutput(self.videoOutput)
            }
            // 인식은 반드시 미러링하지 않은 원본으로 한다 (ARCHITECTURE 3절). 회전도 하지 않는다.
            if let connection = self.videoOutput.connection(with: .video), connection.isVideoMirroringSupported {
                connection.automaticallyAdjustsVideoMirroring = false
                connection.isVideoMirrored = false
            }

            let supported = self.session.isMultitaskingCameraAccessSupported
            if supported { self.session.isMultitaskingCameraAccessEnabled = true }
            self.session.commitConfiguration()
            if !self.session.isRunning { self.session.startRunning() }

            let dimensions = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
            let running = self.session.isRunning
            let enabled = self.session.isMultitaskingCameraAccessEnabled
            DispatchQueue.main.async {
                self.currentDevice = device
                self.status.cameraName = device.localizedName
                self.status.isExternal = device.deviceType == .external
                self.status.resolution = "\(dimensions.width)×\(dimensions.height)"
                self.status.isRunning = running
                self.status.multitaskingSupported = supported
                self.status.multitaskingEnabled = enabled
                self.status.problem = running ? nil : "카메라가 시작되지 않음"
                UIApplication.shared.isIdleTimerDisabled = true
                self.startFPSTimer()
                if changed { self.onCameraChanged?() }
            }
        }
    }

    // MARK: - 초당 프레임

    private func startFPSTimer() {
        fpsTimer?.invalidate()
        lastFPSTime = CACurrentMediaTime()
        fpsTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self else { return }
            self.fpsLock.lock()
            let count = self.frameCount
            self.fpsLock.unlock()
            let now = CACurrentMediaTime()
            self.status.fps = Double(count - self.lastFPSCount) / (now - self.lastFPSTime)
            self.status.isRunning = self.session.isRunning
            (self.lastFPSCount, self.lastFPSTime) = (count, now)
        }
    }

    // MARK: - 알림

    @objc private func deviceConnectionChanged(_ notification: Notification) {
        guard let device = notification.object as? AVCaptureDevice, device.hasMediaType(.video) else { return }
        DispatchQueue.main.async {
            self.refreshCameras()
            // 웹캠을 꽂거나 뽑으면 자동 선택을 다시 한다 (사용자가 고른 카메라가 사라진 경우 포함).
            if self.chosenCameraID == device.uniqueID { self.chosenCameraID = nil }
            if self.status.authorization == "허용됨" { self.configure() }
        }
    }

    @objc private func sessionInterrupted(_ notification: Notification) {
        let reason = (notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int)
            .flatMap(AVCaptureSession.InterruptionReason.init(rawValue:))
        let text: String
        switch reason {
        case .videoDeviceNotAvailableWithMultipleForegroundApps: text = "다른 앱과 함께 떠 있어 카메라가 멈춤"
        case .videoDeviceNotAvailableInBackground: text = "앱이 백그라운드로 내려가 카메라가 멈춤"
        case .videoDeviceInUseByAnotherClient: text = "다른 앱이 카메라를 쓰는 중"
        case .videoDeviceNotAvailableDueToSystemPressure: text = "기기가 뜨거워 카메라가 멈춤"
        default: text = "카메라가 멈춤"
        }
        report(problem: "⚠️ \(text)")
    }

    @objc private func interruptionEnded(_ notification: Notification) {
        report(problem: nil)
    }

    @objc private func runtimeError(_ notification: Notification) {
        let error = notification.userInfo?[AVCaptureSessionErrorKey] as? NSError
        report(problem: "❌ 카메라 오류: \(error?.localizedDescription ?? "알 수 없음") [\(error?.code ?? 0)]")
    }

    private func report(problem: String?) {
        DispatchQueue.main.async { self.status.problem = problem }
    }
}

extension CameraService: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        fpsLock.lock()
        frameCount += 1
        fpsLock.unlock()
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        // 멈춘 시간·속도 계산은 처리 시각이 아니라 찍힌 시각으로 해야 처리 지연에 흔들리지 않는다.
        onFrame?(buffer, CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer)))
    }
}
