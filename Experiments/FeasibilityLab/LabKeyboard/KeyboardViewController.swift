import UIKit

/// 실험 2용 최소 키보드. 카메라/Vision 코드는 넣지 않는다.
/// 앱이 App Group에 쓴 글을 읽어 표시하고, 버튼으로 현재 입력창에 넣는다.
final class KeyboardViewController: UIInputViewController {
    private let statusLabel = UILabel()
    private let globeButton = UIButton(type: .system)
    private var pollTimer: Timer?
    private var appMessage: String?

    override func viewDidLoad() {
        super.viewDidLoad()

        statusLabel.numberOfLines = 0
        statusLabel.font = .preferredFont(forTextStyle: .footnote)

        globeButton.setImage(UIImage(systemName: "globe"), for: .normal)
        globeButton.addTarget(self, action: #selector(handleInputModeList(from:with:)), for: .allTouchEvents)

        let buttons = UIStackView(arrangedSubviews: [
            globeButton,
            makeButton("앱 글 넣기", #selector(insertAppMessage)),
            makeButton("키보드→앱 쓰기", #selector(writeToApp)),
            makeButton("스페이스", #selector(insertSpace)),
            makeButton("⌫", #selector(deleteBackward)),
        ])
        buttons.axis = .horizontal
        buttons.spacing = 8
        buttons.distribution = .fillProportionally

        let stack = UIStackView(arrangedSubviews: [statusLabel, buttons])
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)

        let height = view.heightAnchor.constraint(equalToConstant: 220)
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

    private func refreshStatus(extra: String? = nil) {
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
        if let extra { lines.append(extra) }
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
            refreshStatus(extra: "넣을 글이 없음 (앱에서 먼저 'App Group에 쓰기')")
            return
        }
        textDocumentProxy.insertText(appMessage)
    }

    @objc private func writeToApp() {
        let text = "키보드가 씀 \(LabShared.timestamp()), Full Access=\(hasFullAccess)"
        do {
            try LabShared.write(text, to: LabShared.keyboardMessageFile)
            refreshStatus(extra: "✅ 키보드→앱 쓰기 성공")
        } catch {
            refreshStatus(extra: "❌ 키보드→앱 쓰기 실패: \(error.localizedDescription)")
        }
    }

    @objc private func insertSpace() {
        textDocumentProxy.insertText(" ")
    }

    @objc private func deleteBackward() {
        textDocumentProxy.deleteBackward()
    }
}
