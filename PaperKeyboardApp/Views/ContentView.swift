import PaperKeyboardRecognition
import PaperKeyboardShared
import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var camera: CameraService

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                CameraOverlayView(
                    session: camera.session,
                    device: camera.currentDevice,
                    snapshot: model.snapshot,
                    layout: model.layout
                )
                statusBanner
                    .padding(12)
            }
            controlBar
        }
        .background(Color.black)
        .onAppear { camera.start() }
    }

    // MARK: - 위쪽 상태 안내

    private var statusBanner: some View {
        let (text, color) = statusMessage
        return Text(text)
            .font(.headline)
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(color.opacity(0.85), in: Capsule())
    }

    /// 사용자에게 보여 줄 현재 상태. 카메라 문제가 먼저, 그다음 종이 찾기 단계.
    private var statusMessage: (String, Color) {
        if let problem = camera.status.problem { return (problem, .red) }
        if let problem = model.snapshot.problem { return (problem, .red) }
        switch model.snapshot.lockState {
        case .searching:
            switch model.snapshot.failure {
            case .notEnoughMarkers(let found)?:
                return ("종이를 찾는 중 · 검은 네모 \(found)/4개 보임 (손을 종이에서 떼 주세요)", .gray)
            case .orientationMarkerNotFound?:
                return ("구멍 난 왼쪽 위 네모를 못 찾음 · 종이 방향을 알 수 없어요", .orange)
            case .noConsistentQuad?:
                return ("네모 4개가 보이지만 종이 모양과 안 맞음", .orange)
            case nil:
                return ("종이를 찾는 중", .gray)
            }
        case .stabilizing(let frames, let required):
            return ("종이를 찾았어요 · 움직이지 마세요 (\(frames)/\(required))", .blue)
        case .locked:
            return ("✅ 종이 위치 고정됨 · 손을 올려도 됩니다", .green)
        case .needsRecalibration:
            return ("⚠️ 종이가 움직인 것 같아요 · [재보정]을 눌러 주세요", .orange)
        }
    }

    // MARK: - 아래쪽 조작 막대

    private var controlBar: some View {
        HStack(spacing: 12) {
            Menu {
                Button("자동 (웹캠 우선)") { camera.choose(cameraID: nil) }
                ForEach(camera.cameras) { option in
                    Button(option.name) { camera.choose(cameraID: option.id) }
                }
            } label: {
                Label(camera.status.cameraName, systemImage: camera.status.isExternal ? "web.camera" : "camera")
            }

            Button("재보정") { model.recalibrate() }
                .buttonStyle(.borderedProminent)

            if camera.status.authorization == "거부됨" {
                Button("설정 열기") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
            }

            Spacer()

            Text(infoText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
        }
        .padding(12)
        .background(.bar)
    }

    private var infoText: String {
        let status = camera.status
        let multitasking = status.multitaskingSupported ? "멀티태스킹 지원" : "멀티태스킹 미지원"
        return "\(status.resolution) · \(String(format: "%.0f", status.fps))fps · 검출 \(String(format: "%.1f", model.snapshot.detectionMilliseconds))ms · \(multitasking)"
    }
}
