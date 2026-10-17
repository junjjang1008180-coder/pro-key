import UIKit

/// 실험 2용 최소 키보드. 카메라/Vision 코드는 넣지 않는다.
/// 앱이 App Group에 쓴 글을 읽어 표시하고, 버튼으로 현재 입력창에 넣는다.
final class KeyboardViewController: UIInputViewController {
    private let statusLabel = UILabel()
    private let globeButton = UIButton(type: .system)
    private var pollTimer: Timer?
    private var appMessage: String?
    /// 마지막 버튼 결과. 1초 폴링이 화면을 다시 그려도 사라지지 않게 따로 보관한다.
    private var lastActionResult: String?

    override func viewDidLoad() {
        super.viewDidLoad()

        statusLabel.numberOfLines = 0
        statusLabel.font = .preferredFont(forTextStyle: .footnote)

        globeButton.setImage(UIImage(systemName: "globe"), for: .normal)
        globeButton.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)

        // iPhone처럼 폭이 좁아도 글자가 잘리지 않게 버튼을 두 줄로 놓는다.
        let topRow = UIStackView(arrangedSubviews: [
            globeButton,
            makeButton("앱 글 넣기", #selector(insertAppMessage)),
            makeButton("키보드→앱 쓰기", #selector(writeToApp)),
        ])
        let bottomRow = UIStackView(arrangedSubviews: [
            makeButton("스페이스", #selector(insertSpace)),
            makeButton("⌫", #selector(deleteBackward)),
        ])
        for row in [topRow, bottomRow] {
            row.axis = .horizontal
            row.spacing = 8
            row.distribution = .fillProportionally
        }

        let stack = UIStackView(arrangedSubviews: [statusLabel, topRow, bottomRow])
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        let height = view.heightAnchor.constraint(equalToConstant: 260)
        height.priority = .defaultHigh
        NSLayoutConstraint.activate([
            height,
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -12),
            stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 12),
        ])
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refreshStatus()
        // 실험용: 키보드가 보이는 동안 1초마다 앱이 쓴 글을 다시 읽는다.
        // viewWillAppear가 두 번 불려도 타이머가 겹치지 않도록 먼저 정리한다.
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.refreshStatus()
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        pollTimer?.invalidate()
        pollTimer = nil
    }

    override func viewWillLayoutSubviews() {
        super.viewWillLayoutSubviews()
        globeButton.isHidden = !needsInputModeSwitchKey
    }

    private func refreshStatus() {
        var lines = [
            hasFullAccess
                ? "Full Access: ✅ 켜짐"
                : "Full Access: ❌ 꺼짐 → 설정 > 일반 > 키보드 > 키보드 > 종이키보드 실험 > 전체 접근 허용",
            "App Group 컨테이너: \(LabShared.containerURL == nil ? "❌ 열 수 없음" : "✅ 열림")",
        ]
        do {
            let message = try LabShared.read(LabShared.appMessageFile)
            appMessage = message
            lines.append("앱이 쓴 글: \(message)")
        } catch {
            appMessage = nil
            lines.append("앱이 쓴 글 읽기 실패: \(error.localizedDescription)")
        }
        if let lastActionResult { lines.append(lastActionResult) }
        statusLabel.text = lines.joined(separator: "\n")
    }

    private func makeButton(_ title: String, _ action: Selector) -> UIButton {
        var configuration = UIButton.Configuration.gray()
        configuration.title = title
        let button = UIButton(configuration: configuration)
        button.addTarget(self, action: action, for: .touchUpInside)
        return button
    }

    @objc private func insertAppMessage() {
        guard let appMessage else {
            report("넣을 글이 없음 (앱에서 먼저 'App Group에 쓰기')")
            return
        }
        textDocumentProxy.insertText(appMessage)
        report("✅ 앱 글 넣기 실행")
    }

    @objc private func writeToApp() {
        let text = "키보드가 씀 \(LabShared.timestamp()), Full Access=\(hasFullAccess)"
        do {
            try LabShared.write(text, to: LabShared.keyboardMessageFile)
            report("✅ 키보드→앱 쓰기 성공")
        } catch {
            report("❌ 키보드→앱 쓰기 실패: \(error.localizedDescription)")
        }
    }

    private func report(_ result: String) {
        lastActionResult = "[\(LabShared.timestamp())] \(result)"
        refreshStatus()
    }

    @objc private func insertSpace() {
        textDocumentProxy.insertText(" ")
    }

    @objc private func deleteBackward() {
        textDocumentProxy.deleteBackward()
    }
}
