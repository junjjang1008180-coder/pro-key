import Foundation

/// 키 종류. 레이아웃 정의 파일과 이벤트 포맷이 같은 이름을 쓴다.
/// `shift`, `capsLock`, `languageToggle`은 상태만 바꾸는 키라 메인 앱(`KeyInputResolver`)에서 처리하고
/// 이벤트로는 보내지 않는다. 키보드 확장이 받는 것은 나머지 종류뿐이다.
public enum KeyKind: String, Codable, Sendable, CaseIterable {
    case char
    case space
    case enter
    case backspace
    case tab
    case shift
    case capsLock
    /// 한/영 전환.
    case languageToggle

    /// 상태만 바꾸고 글자를 내보내지 않는 키.
    public var isModifier: Bool {
        switch self {
        case .shift, .capsLock, .languageToggle: true
        default: false
        }
    }
}

/// 메인 앱이 확정한 키 입력 한 건. `events.log`에 JSON 한 줄로 기록된다.
public struct KeyEvent: Codable, Equatable, Sendable {
    /// 단조 증가 순번. 키보드는 마지막으로 처리한 순번보다 큰 것만 입력한다.
    public let seq: UInt64
    public let kind: KeyKind
    /// `char`일 때만 글자가 들어간다. 한글 모드에서는 자모 하나(예: "ㅂ")이고, 글자로 조합하는 것은 키보드 확장(`HangulComposer`)이 한다.
    public let value: String?
    /// 1970년 기준 초. 오래된 이벤트를 버릴 때 쓴다.
    public let timestamp: Double

    public init(seq: UInt64, kind: KeyKind, value: String?, timestamp: Double) {
        self.seq = seq
        self.kind = kind
        self.value = value
        self.timestamp = timestamp
    }
}
