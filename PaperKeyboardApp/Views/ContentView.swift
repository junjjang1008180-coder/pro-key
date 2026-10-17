import PaperKeyboardRecognition
import PaperKeyboardShared
import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var camera: CameraService
    @State private var showsSettings = false

    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .top) {
                CameraOverlayView(
                    session: camera.session,
                    device: camera.currentDevice,
                    snapshot: model.snapshot,
                    layout: model.layout,
                    paperRotation: model.paperRotation,
                    flashKeyID: model.flashKeyID
                )
                statusBanner
                    .padding(12)
            }
            typingPanel
            controlBar
        }
        .background(Color.black)
        .onAppear { camera.start() }
        .sheet(isPresented: $showsSettings) {
            SettingsView(model: model)
        }
    }

    // MARK: - 친 글자 (4단계: 앱 안 입력칸)

    private var typingPanel: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 6) {
                Text(model.language == .korean ? "한" : "A")
                    .font(.headline)
                    .frame(width: 34, height: 30)
                    .background(model.language == .korean ? Color.blue : Color.gray.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))
                Image(systemName: model.isShiftArmed ? "shift.fill" : "shift")
                    .foregroundStyle(model.isShiftArmed ? .yellow : .secondary)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    Text(model.typedText.isEmpty ? "종이 키를 누르면 여기에 글자가 써집니다" : model.typedText + "▏")
                        .font(.title3.monospaced())
                        .foregroundStyle(model.typedText.isEmpty ? .secondary : .primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .id("end")
                }
                .onChange(of: model.typedText) { _, _ in proxy.scrollTo("end", anchor: .bottom) }
            }
            .frame(height: 72)
            Button("지우기") { model.clearText() }
                .buttonStyle(.bordered)
        }
        .padding(12)
        .background(Color(.secondarySystemBackground))
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
            if let id = model.snapshot.hoveredKeyID, let key = model.layout.key(withID: id) {
                return ("✅ 손끝 위치: \(key.kind == .space ? "Space" : key.label) 키", .green)
            }
            if model.snapshot.fingertip != nil {
                return ("✅ 손이 보여요 · 검지를 키 위에 올려 보세요", .green)
            }
            return ("✅ 종이 위치 고정됨 · 검지를 키 위에 올려 보세요", .green)
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

            Button {
                showsSettings = true
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
            .accessibilityLabel("누름 판정 설정")

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
        let snapshot = model.snapshot
        let confidence = snapshot.fingertip.map { String(format: " · 손끝 신뢰도 %.2f", $0.confidence) } ?? ""
        let first = "\(status.resolution) · \(String(format: "%.0f", status.fps))fps · 종이 \(String(format: "%.1f", snapshot.detectionMilliseconds))ms · 손 \(String(format: "%.1f", snapshot.handMilliseconds))ms\(confidence) · \(multitasking)"
        return first + "\n" + pressText
    }

    /// 누름 판정 상태와 판정에 쓰인 값 (튜닝용).
    private var pressText: String {
        guard let press = model.snapshot.press else { return "누름 판정: 대기 (종이 고정 후 시작)" }
        let state: String
        switch press.state {
        case .idle: state = "대기"
        case .hover(let id): state = "\(id) 위에 있음"
        case .touching(let id): state = "\(id) 닿음 (들면 입력)"
        case .resting(let id): state = "\(id) 올려 둠 (입력 안 함)"
        }
        let speed = press.speed.map { String(format: " · 속도 %.0fmm/s", $0) } ?? ""
        let still = press.stillDuration.map { String(format: " · 멈춤 %.2f초", $0) } ?? ""
        let touch = press.touchDuration.map { String(format: " · 닿은 지 %.2f초", $0) } ?? ""
        let lift = press.liftAmount.map { String(format: " · 들림 %.1fmm", $0) } ?? ""
        return "누름 판정: \(state)\(speed)\(still)\(touch)\(lift)"
    }
}
