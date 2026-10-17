import PaperKeyboardRecognition
import SwiftUI

/// 누름 판정 임계값 조절 화면 (FR-11). 바꾸면 바로 적용되고 기기에 저장된다.
struct SettingsView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    slider("멈춰 있어야 하는 시간", value: $model.settings.dwellDuration, range: 0.05...0.6, step: 0.01, unit: "초", format: "%.2f",
                           help: "키 위에서 이만큼 멈추면 누른 것으로 봅니다. 길수록 실수로 눌리는 일이 줄지만 느려집니다.")
                    slider("멈춤으로 보는 속도", value: $model.settings.maxStillSpeed, range: 10...200, step: 5, unit: "mm/s", format: "%.0f",
                           help: "손끝이 이보다 느리면 멈춘 것으로 봅니다. 손이 떨려서 안 눌리면 올리세요.")
                    slider("손을 뗀 것으로 보는 거리", value: $model.settings.releaseDistance, range: 3...20, step: 1, unit: "mm", format: "%.0f",
                           help: "누른 자리에서 이만큼 움직이면 손을 뗀 것으로 보고 다음 입력을 받습니다.")
                    slider("손끝 인식 최소 신뢰도", value: $model.settings.minConfidence, range: 0.1...0.9, step: 0.05, unit: "", format: "%.2f",
                           help: "이보다 확실하지 않은 손끝은 무시합니다.")
                } header: {
                    Text("누름 판정")
                } footer: {
                    Text("바꾸면 바로 적용됩니다. 종이를 직접 눌러 보면서 맞춰 주세요.")
                }
                Section {
                    Button("기본값으로 되돌리기", role: .destructive) { model.resetSettings() }
                }
            }
            .navigationTitle("설정")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("완료") { dismiss() }
                }
            }
        }
    }

    private func slider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>, step: Double,
                        unit: String, format: String, help: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(title)
                Spacer()
                Text(String(format: format, value.wrappedValue) + unit)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: step)
            Text(help)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}
