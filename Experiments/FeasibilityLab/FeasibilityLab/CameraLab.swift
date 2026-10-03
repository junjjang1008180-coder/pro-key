import AVFoundation
import UIKit

/// 실험 1, 3용 전면 카메라 캡처.
/// 프레임은 개수만 세고 바로 버린다 (저장/전송 없음).
final class CameraLab: NSObject, ObservableObject {
    struct CameraOption: Identifiable, Hashable {
        let id: String
        let name: String
    }

    @Published private(set) var authorization = "확인 전"
    @Published private(set) var isRunning = false
    @Published private(set) var multitaskingSupported = "-"
    @Published private(set) var multitaskingEnabled = "-"
    @Published private(set) var centerStage = "-"
    @Published private(set) var resolution = "-"
    @Published private(set) var totalFrames = 0
    @Published private(set) var fps = 0.0
    @Published private(set) var secondsSinceLastFrame: Double?
    @Published private(set) var currentDevice: AVCaptureDevice?
    @Published private(set) var cameras: [CameraOption] = []
    @Published private(set) var log: [String] = []
    @Published var selectedCameraID: String?

    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "lab.camera.session")
    private let videoQueue = DispatchQueue(label: "lab.camera.video")
    private let videoOutput = AVCaptureVideoDataOutput()

    // videoQueue에서 쓰고 메인 스레드 타이머에서 읽으므로 lock으로 보호한다.
    private let counterLock = NSLock()
    private var frameCount = 0
    private var lastFrameTime: CFTimeInterval = 0
    private var frameSize: CGSize = .zero

    private var statsTimer: Timer?
    private var lastStatsCount = 0
    private var lastStatsTime = CACurrentMediaTime()

    override init() {
        super.init()
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInUltraWideCamera, .builtInWideAngleCamera, .builtInTrueDepthCamera],
            mediaType: .video,
            position: .front
        )
        cameras = discovery.devices.map { CameraOption(id: $0.uniqueID, name: $0.localizedName) }
        // 화각이 넓을수록 종이와 손이 함께 들어올 가능성이 높으므로 초광각을 먼저 고른다.
        selectedCameraID = (discovery.devices.first { $0.deviceType == .builtInUltraWideCamera } ?? discovery.devices.first)?.uniqueID
        if cameras.isEmpty { addLog("전면 카메라를 찾지 못함 (시뮬레이터에는 카메라가 없음)") }

        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(sessionInterrupted), name: AVCaptureSession.wasInterruptedNotification, object: session)
        center.addObserver(self, selector: #selector(interruptionEnded), name: AVCaptureSession.interruptionEndedNotification, object: session)
        center.addObserver(self, selector: #selector(runtimeError), name: AVCaptureSession.runtimeErrorNotification, object: session)
    }

    // MARK: - 시작/정지

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            authorization = "허용됨"
            configureAndRun()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    if granted {
                        self.authorization = "허용됨"
                        self.configureAndRun()
                    } else {
                        self.authorization = "거부됨"
                        self.addLog("카메라 권한 거부됨. 설정 > 개인정보 보호 및 보안 > 카메라에서 허용 필요")
                    }
                }
            }
        default:
            authorization = "거부됨"
            addLog("카메라 권한 없음. 설정 > 개인정보 보호 및 보안 > 카메라에서 허용 필요")
        }
    }

    func stop() {
        sessionQueue.async {
            self.session.stopRunning()
            DispatchQueue.main.async {
                self.isRunning = false
                self.statsTimer?.invalidate()
                UIApplication.shared.isIdleTimerDisabled = false
                self.addLog("카메라 정지")
            }
        }
    }

    func addLog(_ message: String) {
        log.insert("[\(LabShared.timestamp())] \(message)", at: 0)
    }

    private func configureAndRun() {
        let selectedID = selectedCameraID
        sessionQueue.async {
            guard let device = selectedID.flatMap(AVCaptureDevice.init(uniqueID:)) else {
                DispatchQueue.main.async { self.addLog("사용할 전면 카메라가 없음") }
                return
            }

            // Center Stage는 얼굴을 따라 화면을 잘라내므로 종이 좌표가 흔들린다. 실험에서는 끈다.
            AVCaptureDevice.centerStageControlMode = .app
            AVCaptureDevice.isCenterStageEnabled = false

            self.session.beginConfiguration()
            if self.session.canSetSessionPreset(.hd1920x1080) {
                self.session.sessionPreset = .hd1920x1080
            }
            self.session.inputs.forEach { self.session.removeInput($0) }

            let input: AVCaptureDeviceInput
            do {
                input = try AVCaptureDeviceInput(device: device)
            } catch {
                self.session.commitConfiguration()
                DispatchQueue.main.async { self.addLog("카메라 입력 생성 실패: \(error.localizedDescription)") }
                return
            }
            if self.session.canAddInput(input) { self.session.addInput(input) }

            if !self.session.outputs.contains(self.videoOutput) {
                self.videoOutput.alwaysDiscardsLateVideoFrames = true
                self.videoOutput.setSampleBufferDelegate(self, queue: self.videoQueue)
                if self.session.canAddOutput(self.videoOutput) { self.session.addOutput(self.videoOutput) }
            }

            let supported = self.session.isMultitaskingCameraAccessSupported
            if supported {
                self.session.isMultitaskingCameraAccessEnabled = true
            }
            self.session.commitConfiguration()

            if !self.session.isRunning { self.session.startRunning() }

            let enabled = self.session.isMultitaskingCameraAccessEnabled
            let running = self.session.isRunning
            let centerStageText = device.activeFormat.isCenterStageSupported
                ? (AVCaptureDevice.isCenterStageEnabled ? "켜짐" : "꺼짐")
                : "미지원 포맷"

            DispatchQueue.main.async {
                self.currentDevice = device
                self.multitaskingSupported = supported ? "true" : "false"
                self.multitaskingEnabled = enabled ? "true" : "false"
                self.centerStage = centerStageText
                self.isRunning = running
                self.addLog("카메라 시작: \(device.localizedName), 멀티태스킹 지원=\(supported), 활성화=\(enabled)")
                UIApplication.shared.isIdleTimerDisabled = true
                self.startStatsTimer()
            }
        }
    }

    // MARK: - 프레임 통계

    private func startStatsTimer() {
        statsTimer?.invalidate()
        lastStatsTime = CACurrentMediaTime()
        counterLock.lock()
        lastStatsCount = frameCount
        counterLock.unlock()

        statsTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.updateStats()
        }
    }

    private func updateStats() {
        counterLock.lock()
        let count = frameCount
        let lastTime = lastFrameTime
        let size = frameSize
        counterLock.unlock()

        let now = CACurrentMediaTime()
        fps = Double(count - lastStatsCount) / (now - lastStatsTime)
        lastStatsCount = count
        lastStatsTime = now
        totalFrames = count
        secondsSinceLastFrame = lastTime > 0 ? now - lastTime : nil
        if size != .zero { resolution = "\(Int(size.width))×\(Int(size.height))" }
        isRunning = session.isRunning
    }

    // MARK: - 세션 알림

    @objc private func sessionInterrupted(_ notification: Notification) {
        var reasonText = "알 수 없음"
        if let raw = notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as? Int,
           let reason = AVCaptureSession.InterruptionReason(rawValue: raw) {
            reasonText = Self.describe(reason)
        }
        DispatchQueue.main.async { self.addLog("⚠️ 카메라 중단: \(reasonText)") }
    }

    @objc private func interruptionEnded(_ notification: Notification) {
        DispatchQueue.main.async { self.addLog("카메라 중단 해제") }
    }

    @objc private func runtimeError(_ notification: Notification) {
        let error = notification.userInfo?[AVCaptureSessionErrorKey] as? Error
        DispatchQueue.main.async { self.addLog("❌ 카메라 런타임 오류: \(error?.localizedDescription ?? "알 수 없음")") }
    }

    private static func describe(_ reason: AVCaptureSession.InterruptionReason) -> String {
        switch reason {
        case .videoDeviceNotAvailableInBackground: return "앱이 백그라운드로 내려감"
        case .videoDeviceNotAvailableWithMultipleForegroundApps: return "멀티태스킹 중이라 카메라 사용 불가"
        case .videoDeviceInUseByAnotherClient: return "다른 앱이 카메라 사용 중"
        case .audioDeviceInUseByAnotherClient: return "다른 앱이 오디오 장치 사용 중"
        case .videoDeviceNotAvailableDueToSystemPressure: return "발열/시스템 부하"
        case .sensitiveContentMitigationActivated: return "민감한 콘텐츠 보호 기능 작동"
        @unknown default: return "기타 (rawValue \(reason.rawValue))"
        }
    }
}

extension CameraLab: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let size = CMSampleBufferGetImageBuffer(sampleBuffer).map {
            CGSize(width: CVPixelBufferGetWidth($0), height: CVPixelBufferGetHeight($0))
        }
        counterLock.lock()
        frameCount += 1
        lastFrameTime = CACurrentMediaTime()
        if let size { frameSize = size }
        counterLock.unlock()
    }
}
