import Foundation

/// 메인 앱과 키보드 확장이 함께 쓰는 App Group 실험용 상수와 파일 입출력.
/// 실험 2: 두 타겟이 같은 App Group 컨테이너의 파일을 읽고 쓸 수 있는지 확인한다.
enum LabShared {
    static let appGroupID = "group.com.junjjang.PaperKeyboardLab"
    static let appMessageFile = "app_message.txt"
    static let keyboardMessageFile = "keyboard_message.txt"

    enum Failure: LocalizedError {
        case noContainer

        var errorDescription: String? {
            "App Group 컨테이너를 열 수 없음 (그룹 미등록, 서명 문제, 또는 키보드 Full Access 꺼짐)"
        }
    }

    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    static func write(_ text: String, to fileName: String) throws {
        guard let directory = containerURL else { throw Failure.noContainer }
        try text.write(to: directory.appendingPathComponent(fileName), atomically: true, encoding: .utf8)
    }

    static func read(_ fileName: String) throws -> String {
        guard let directory = containerURL else { throw Failure.noContainer }
        return try String(contentsOf: directory.appendingPathComponent(fileName), encoding: .utf8)
    }

    static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: Date())
    }
}
