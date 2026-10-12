import Foundation

/// 키 종류. 레이아웃 정의 파일과 이벤트 포맷이 같은 이름을 쓴다.
public enum KeyKind: String, Codable, Sendable, CaseIterable {
    case char
    case space
    case enter
    case backspace
    case shift
}

/// 메인 앱이 확정한 키 입력 한 건. `events.log`에 JSON 한 줄로 기록된다.
public struct KeyEvent: Codable, Equatable, Sendable {
    /// 단조 증가 순번. 키보드는 마지막으로 처리한 순번보다 큰 것만 입력한다.
    public let seq: UInt64
    public let kind: KeyKind
    /// `char`일 때만 글자가 들어간다.
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
