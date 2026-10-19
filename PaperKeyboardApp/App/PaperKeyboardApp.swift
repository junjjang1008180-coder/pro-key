import AudioToolbox
import Combine
import PaperKeyboardRecognition
import PaperKeyboardShared
import SwiftUI

@main
struct PaperKeyboardApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView(model: model, camera: model.camera)
        }
    }
}

/// 카메라 → 인식 → 누른 키 → 글자. 화면 상태는 메인 스레드에서만 바꾼다.
final class AppModel: ObservableObject {
    let layout: KeyboardLayout
    let camera = CameraService()
    let detector: PaperKeyboardDetector
    @Published private(set) var snapshot = PaperKeyboardDetector.Snapshot()
    /// 종이가 화면에서 똑바로 보이도록 프리뷰를 돌릴 각도. 종이를 고정하기 전에는 nil(기기 방향 기준).
    /// 웹캠이 맞은편에 있으면 종이가 거꾸로 찍히므로 고정되는 순간 180°로 바뀐다.
    @Published private(set) var paperRotation: Double?

    // MARK: 입력 (4단계: 앱 안 입력칸)

    /// 종이로 친 글자. 5단계부터는 같은 입력을 키보드 확장으로도 보낸다.
    @Published private(set) var typedText = ""
    /// 방금 눌린 키 (화면에서 잠깐 반짝임).
    @Published private(set) var flashKeyID: String?
    @Published private(set) var language: KeyInputResolver.Language = .english
    @Published private(set) var isShiftArmed = false
    private var resolver = KeyInputResolver()
    private var composer = HangulComposer()
    private var flashWorkItem: DispatchWorkItem?
    private var cancellables: Set<AnyCancellable> = []

    /// 판정 임계값 (디버그 화면에서 조절, 기기에 저장).
    @Published var settings: RecognitionSettings {
        didSet {
            detector.update(settings: settings)
            SettingsStore.save(settings)
        }
    }

    init() {
        do {
            layout = try KeyboardLayout.bundledQWERTY()
        } catch {
            // 레이아웃은 앱에 들어 있는 파일이고 단위 테스트로 검사하므로, 여기서 실패하면 빌드가 잘못된 것.
            fatalError("레이아웃 파일을 읽지 못함: \(error.localizedDescription)")
        }
        let settings = SettingsStore.load()
        self.settings = settings
        detector = PaperKeyboardDetector(layout: layout, settings: settings)

        camera.onFrame = { [detector] buffer, time in detector.process(buffer, time: time) }
        detector.onSnapshot = { [weak self] snapshot in
            DispatchQueue.main.async { self?.receive(snapshot) }
        }
        detector.onKeyPress = { [weak self] key in
            DispatchQueue.main.async { self?.handlePress(key) }
        }
        // 영상의 실제 위쪽(손끝을 드는 방향)을 계산하려면 영상이 얼마나 돌아가 있는지 알아야 한다.
        camera.$captureRotation
            .sink { [detector] rotation in detector.update(captureRotation: rotation) }
            .store(in: &cancellables)
        // 카메라가 바뀌면 화면 속 종이 위치가 달라지므로 다시 찾는다.
        camera.onCameraChanged = { [weak self] in
            self?.paperRotation = nil
            self?.detector.recalibrate()
        }
    }

    func recalibrate() {
        detector.recalibrate()
    }

    func clearText() {
        typedText = ""
        composer.commit()
    }

    func resetSettings() {
        settings = RecognitionSettings()
    }

    private func receive(_ snapshot: PaperKeyboardDetector.Snapshot) {
        self.snapshot = snapshot
        // 재보정 중에는 마지막 방향을 유지해서 화면이 왔다 갔다 하지 않게 한다.
        if let mapping = snapshot.mapping,
           let rotation = mapping.uprightRotationDegrees(paperWidth: layout.paperWidth, paperHeight: layout.paperHeight),
           rotation != paperRotation {
            paperRotation = rotation
        }
    }

    // MARK: - 누른 키 → 글자

    private func handlePress(_ key: KeyboardLayout.Key) {
        AudioServicesPlaySystemSound(1104)   // 키보드 클릭 소리
        flash(key.id)

        let output = resolver.resolve(key)
        language = resolver.language
        isShiftArmed = resolver.isShiftArmed
        guard let output else { return }   // Shift, 한/영 등 상태만 바꾸는 키

        switch output.kind {
        case .char:
            if let value = output.value { apply(composer.input(value)) }
        case .space:
            apply(composer.input(" "))
        case .backspace:
            apply(composer.backspace())
        case .enter:
            composer.commit()
            typedText += "\n"
        case .tab:
            composer.commit()
            typedText += "\t"
        default:
            break
        }
    }

    private func apply(_ edit: HangulComposer.Edit) {
        typedText.removeLast(min(edit.deleteCount, typedText.count))
        typedText += edit.insert
    }

    private func flash(_ keyID: String) {
        flashKeyID = keyID
        flashWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.flashKeyID = nil }
        flashWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }
}

/// 디버그 화면에서 바꾼 누름 판정 임계값을 기기에 저장한다. 나머지 값은 기본값.
enum SettingsStore {
    private static let defaults = UserDefaults.standard
    private static let keys = (
        descent: "settings.descentDistance", lift: "settings.liftDistance",
        maxTap: "settings.maxTapDuration", confidence: "settings.minConfidence"
    )

    static func load() -> RecognitionSettings {
        var settings = RecognitionSettings()
        if let value = defaults.object(forKey: keys.descent) as? Double { settings.descentDistance = value }
        if let value = defaults.object(forKey: keys.lift) as? Double { settings.liftDistance = value }
        if let value = defaults.object(forKey: keys.maxTap) as? Double { settings.maxTapDuration = value }
        if let value = defaults.object(forKey: keys.confidence) as? Double { settings.minConfidence = value }
        return settings
    }

    static func save(_ settings: RecognitionSettings) {
        defaults.set(settings.descentDistance, forKey: keys.descent)
        defaults.set(settings.liftDistance, forKey: keys.lift)
        defaults.set(settings.maxTapDuration, forKey: keys.maxTap)
        defaults.set(settings.minConfidence, forKey: keys.confidence)
    }
}
