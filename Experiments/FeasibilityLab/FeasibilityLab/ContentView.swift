import SwiftUI

struct ContentView: View {
    @StateObject private var camera = CameraLab()
    @State private var windowSize: CGSize = .zero
    @State private var draft = "hello from app"
    @State private var groupStatus = "아직 시도 안 함"
    @State private var keyboardMessage = "-"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                cameraSection
                appGroupSection
                logSection
            }
            .padding()
        }
        .background(
            GeometryReader { geometry in
                Color.clear
                    .onAppear { windowSize = geometry.size }
                    .onChange(of: geometry.size) { _, newSize in
                        windowSize = newSize
                        camera.addLog("창 크기 변경: \(Int(newSize.width))×\(Int(newSize.height))")
                    }
            }
        )
    }

    // MARK: - 실험 1, 3: 카메라

    private var cameraSection: some View {
        GroupBox("실험 1·3: 카메라") {
            VStack(alignment: .leading, spacing: 8) {
                CameraPreview(session: camera.session, device: camera.currentDevice)
                    .frame(height: 320)
                    .clipShape(RoundedRectangle(cornerRadius: 8))

                if camera.cameras.count > 1 {
                    Picker("카메라", selection: $camera.selectedCameraID) {
                        ForEach(camera.cameras) { option in
                            Text(option.name).tag(Optional(option.id))
                        }
                    }
                    .pickerStyle(.segmented)
                }

                HStack {
                    Button(camera.isRunning ? "카메라 다시 설정" : "카메라 시작") { camera.start() }
                        .buttonStyle(.borderedProminent)
                    Button("정지") { camera.stop() }
                        .buttonStyle(.bordered)
                }

                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
                    row("카메라 권한", camera.authorization)
                    row("isMultitaskingCameraAccessSupported", camera.multitaskingSupported)
                    row("isMultitaskingCameraAccessEnabled", camera.multitaskingEnabled)
                    row("세션 실행 중", camera.isRunning ? "예" : "아니오")
                    row("Center Stage", camera.centerStage)
                    row("해상도", camera.resolution)
                    row("초당 프레임", String(format: "%.1f fps", camera.fps))
                    row("받은 프레임 합계", "\(camera.totalFrames)")
                    row("마지막 프레임 이후", camera.secondsSinceLastFrame.map { String(format: "%.1f초", $0) } ?? "-")
                    row("창 크기", "\(Int(windowSize.width))×\(Int(windowSize.height))")
                }
                .font(.callout.monospacedDigit())
            }
        }
    }

    // MARK: - 실험 2: App Group

    private var appGroupSection: some View {
        GroupBox("실험 2: App Group") {
            VStack(alignment: .leading, spacing: 8) {
                Text("그룹 ID: \(LabShared.appGroupID)").font(.caption).textSelection(.enabled)
                Text("컨테이너: \(LabShared.containerURL == nil ? "❌ 열 수 없음" : "✅ 열림")")

                TextField("키보드로 보낼 글", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)

                HStack {
                    Button("App Group에 쓰기") { writeToGroup() }
                        .buttonStyle(.borderedProminent)
                    Button("키보드가 쓴 내용 읽기") { readFromKeyboard() }
                        .buttonStyle(.bordered)
                }
                Text("결과: \(groupStatus)")
                Text("키보드가 쓴 내용: \(keyboardMessage)")
            }
        }
    }

    private func writeToGroup() {
        do {
            try LabShared.write(draft, to: LabShared.appMessageFile)
            groupStatus = "✅ 쓰기 성공 (\(LabShared.timestamp()))"
        } catch {
            groupStatus = "❌ 쓰기 실패: \(error.localizedDescription)"
        }
    }

    private func readFromKeyboard() {
        do {
            keyboardMessage = try LabShared.read(LabShared.keyboardMessageFile)
            groupStatus = "✅ 읽기 성공 (\(LabShared.timestamp()))"
        } catch {
            groupStatus = "❌ 읽기 실패: \(error.localizedDescription)"
        }
    }

    // MARK: - 기록

    private var logSection: some View {
        GroupBox("기록 (최신이 위)") {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(camera.log.prefix(50).enumerated()), id: \.offset) { _, line in
                    Text(line).font(.caption.monospaced())
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        GridRow {
            Text(title).foregroundStyle(.secondary)
            Text(value)
        }
    }
}
