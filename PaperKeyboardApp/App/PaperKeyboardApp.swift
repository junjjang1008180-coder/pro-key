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

/// 카메라와 종이 인식을 잇는다. 화면 상태는 메인 스레드에서만 바꾼다.
final class AppModel: ObservableObject {
    let layout: KeyboardLayout
    let camera = CameraService()
    let detector: PaperKeyboardDetector
    @Published private(set) var snapshot = PaperKeyboardDetector.Snapshot()

    init() {
        do {
            layout = try KeyboardLayout.bundledQWERTY()
        } catch {
            // 레이아웃은 앱에 들어 있는 파일이고 단위 테스트로 검사하므로, 여기서 실패하면 빌드가 잘못된 것.
            fatalError("레이아웃 파일을 읽지 못함: \(error.localizedDescription)")
        }
        detector = PaperKeyboardDetector(layout: layout)

        camera.onFrame = { [detector] buffer in detector.process(buffer) }
        detector.onSnapshot = { [weak self] snapshot in
            DispatchQueue.main.async { self?.snapshot = snapshot }
        }
        // 카메라가 바뀌면 화면 속 종이 위치가 달라지므로 다시 찾는다.
        camera.onCameraChanged = { [detector] in detector.recalibrate() }
    }

    func recalibrate() {
        detector.recalibrate()
    }
}
