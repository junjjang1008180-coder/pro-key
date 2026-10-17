import Foundation

/// 눌린 종이 키를 실제로 보낼 입력으로 바꾼다. Shift(한 번), Caps Lock, 한/영 상태를 여기서만 관리한다.
/// 메인 앱이 `PressDetector`가 확정한 키마다 부르고, 결과를 이벤트 채널에 쓴다.
/// 수식 키(Shift, Caps Lock, 한/영)는 상태만 바꾸고 아무것도 내보내지 않는다.
public struct KeyInputResolver: Sendable {
    public enum Language: String, Sendable {
        case english
        case korean
    }

    /// 이벤트로 보낼 입력 한 건.
    public struct Output: Equatable, Sendable {
        public let kind: KeyKind
        /// `char`일 때만. 한글 모드면 자모 하나.
        public let value: String?

        public init(kind: KeyKind, value: String? = nil) {
            self.kind = kind
            self.value = value
        }
    }

    public private(set) var language: Language = .english
    /// 다음 글자 하나에만 적용되는 Shift.
    public private(set) var isShiftArmed = false
    public private(set) var isCapsLockOn = false

    public init() {}

    public mutating func resolve(_ key: KeyboardLayout.Key) -> Output? {
        switch key.kind {
        case .shift:
            isShiftArmed.toggle()
            return nil
        case .capsLock:
            isCapsLockOn.toggle()
            return nil
        case .languageToggle:
            language = language == .english ? .korean : .english
            return nil
        case .char:
            defer { isShiftArmed = false }
            return Output(kind: .char, value: character(for: key))
        case .space, .enter, .backspace, .tab, .cursorLeft, .cursorRight:
            // Shift 다음에 글자가 아닌 키를 누르면 Shift는 취소된다.
            isShiftArmed = false
            return Output(kind: key.kind)
        }
    }

    private func character(for key: KeyboardLayout.Key) -> String? {
        if language == .korean, let korean = key.koreanValue {
            // Caps Lock은 한글에 영향 없음. Shift는 쌍자음/ㅒㅖ.
            return isShiftArmed ? (key.koreanShiftValue ?? korean) : korean
        }
        guard let value = key.value else { return nil }
        let isLetter = value.lowercased() != value.uppercased()
        // 영문자: Shift와 Caps Lock 중 하나만 켜져 있으면 대문자. 숫자·기호는 Shift만 본다.
        let shifted = isLetter ? (isShiftArmed != isCapsLockOn) : isShiftArmed
        return shifted ? (key.shiftValue ?? value) : value
    }
}
