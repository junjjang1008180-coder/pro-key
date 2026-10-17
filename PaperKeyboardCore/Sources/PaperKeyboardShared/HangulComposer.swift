import Foundation

/// 두벌식 한글 조합기. 자모를 하나씩 받아 글자(음절)로 모은다.
/// 결과는 "앞에서 몇 글자 지우고 무엇을 넣을지"(`Edit`)로 돌려준다. 키보드 확장은 이것을
/// `deleteBackward()` 반복 + `insertText()`로 그대로 적용하면 된다.
///
/// 조합 중인 글자는 이미 화면(입력창)에 들어가 있고, 자모가 더 오면 지우고 바뀐 글자로 다시 넣는다.
/// 예: ㅎ → "ㅎ", ㅏ → "ㅎ" 지우고 "하", ㄴ → "하" 지우고 "한".
///
/// 조합 상태는 지금 입력창에만 의미가 있다. 사용자가 커서를 옮기거나 다른 입력창/앱으로 가면
/// 키보드 확장은 `commit()`을 불러 조합을 끝내야 한다 (안 그러면 엉뚱한 글자를 지운다).
public struct HangulComposer: Sendable {
    public struct Edit: Equatable, Sendable {
        /// 커서 앞에서 지울 글자 수.
        public var deleteCount: Int
        public var insert: String

        public init(deleteCount: Int, insert: String) {
            self.deleteCount = deleteCount
            self.insert = insert
        }
    }

    /// 조합 중인 글자의 변화 기록. 맨 뒤가 지금 모양이고, 백스페이스는 하나씩 되돌린다.
    private var history: [Syllable] = []

    public init() {}

    public var isComposing: Bool { !history.isEmpty }

    /// 조합 중인 글자 (없으면 빈 문자열).
    public var composingText: String { history.last?.text ?? "" }

    /// 글자 입력. 자모 한 글자면 조합하고, 그 밖의 글자(영문, 숫자, 공백 등)는 조합을 끝내고 그대로 넣는다.
    public mutating func input(_ text: String) -> Edit {
        guard text.count == 1, let jamo = text.first, Self.isJamo(text) else {
            history.removeAll()
            return Edit(deleteCount: 0, insert: text)
        }
        return Self.isVowel(jamo) ? inputVowel(jamo) : inputConsonant(jamo)
    }

    /// 백스페이스. 조합 중이면 마지막 자모만 지우고, 아니면 앞 글자 하나를 지운다.
    public mutating func backspace() -> Edit {
        guard !history.isEmpty else { return Edit(deleteCount: 1, insert: "") }
        history.removeLast()
        return Edit(deleteCount: 1, insert: composingText)
    }

    /// 조합을 끝낸다. 화면의 글자는 그대로 두고 상태만 비운다 (엔터, 커서 이동, 입력창 바뀜 등).
    public mutating func commit() {
        history.removeAll()
    }

    // MARK: - 조합 규칙

    private mutating func inputVowel(_ vowel: Character) -> Edit {
        let current = history.last ?? Syllable()
        let shown = current.text.isEmpty ? 0 : 1

        // 초성만 있음 → 초성 + 중성
        if current.initial != nil, current.vowels.isEmpty {
            return push(current.adding(vowel: vowel), deleting: shown)
        }
        // 중성 하나 + 받침 없음 → 겹모음이 되면 합친다 (ㅗ + ㅏ = ㅘ)
        if current.vowels.count == 1, current.finals.isEmpty, Self.compoundVowels[String(current.vowels + [vowel])] != nil {
            return push(current.adding(vowel: vowel), deleting: shown)
        }
        // 받침 있음 → 마지막 받침이 다음 글자 초성으로 넘어간다 (닭 + ㅣ = 달기, 한 + ㅏ = 하나)
        if current.initial != nil, let moving = current.finals.last {
            var remaining = current
            remaining.finals.removeLast()
            let start = Syllable(initial: moving)
            let next = start.adding(vowel: vowel)
            history = [start, next]
            return Edit(deleteCount: shown, insert: remaining.text + next.text)
        }
        // 그 밖: 지금 글자를 확정하고 모음만 있는 새 글자 시작
        return startNew(Syllable(vowels: [vowel]))
    }

    private mutating func inputConsonant(_ consonant: Character) -> Edit {
        let current = history.last ?? Syllable()
        let shown = current.text.isEmpty ? 0 : 1

        if current.initial != nil, !current.vowels.isEmpty {
            // 받침 없음 → 받침이 될 수 있는 자음이면 받침으로 (ㄸ ㅃ ㅉ는 받침이 될 수 없음)
            if current.finals.isEmpty, Self.jongseong.contains(consonant) {
                return push(current.adding(final: consonant), deleting: shown)
            }
            // 받침 하나 → 겹받침이 되면 합친다 (ㄹ + ㄱ = ㄺ)
            if current.finals.count == 1, Self.compoundFinals[String(current.finals + [consonant])] != nil {
                return push(current.adding(final: consonant), deleting: shown)
            }
        }
        // 그 밖: 지금 글자를 확정하고 새 글자의 초성으로
        return startNew(Syllable(initial: consonant))
    }

    private mutating func push(_ syllable: Syllable, deleting shown: Int) -> Edit {
        history.append(syllable)
        return Edit(deleteCount: shown, insert: syllable.text)
    }

    /// 지금 글자는 화면에 그대로 두고(확정) 새 글자를 시작한다.
    private mutating func startNew(_ syllable: Syllable) -> Edit {
        history = [syllable]
        return Edit(deleteCount: 0, insert: syllable.text)
    }

    // MARK: - 자모 표

    /// 초성 19자 (유니코드 음절 계산 순서).
    static let choseong = Array("ㄱㄲㄴㄷㄸㄹㅁㅂㅃㅅㅆㅇㅈㅉㅊㅋㅌㅍㅎ")
    /// 중성 21자.
    static let jungseong = Array("ㅏㅐㅑㅒㅓㅔㅕㅖㅗㅘㅙㅚㅛㅜㅝㅞㅟㅠㅡㅢㅣ")
    /// 종성 27자 (받침 없음은 0번이라 여기 순서 + 1).
    static let jongseong = Array("ㄱㄲㄳㄴㄵㄶㄷㄹㄺㄻㄼㄽㄾㄿㅀㅁㅂㅄㅅㅆㅇㅈㅊㅋㅌㅍㅎ")
    static let compoundVowels: [String: Character] = [
        "ㅗㅏ": "ㅘ", "ㅗㅐ": "ㅙ", "ㅗㅣ": "ㅚ", "ㅜㅓ": "ㅝ", "ㅜㅔ": "ㅞ", "ㅜㅣ": "ㅟ", "ㅡㅣ": "ㅢ",
    ]
    static let compoundFinals: [String: Character] = [
        "ㄱㅅ": "ㄳ", "ㄴㅈ": "ㄵ", "ㄴㅎ": "ㄶ", "ㄹㄱ": "ㄺ", "ㄹㅁ": "ㄻ", "ㄹㅂ": "ㄼ",
        "ㄹㅅ": "ㄽ", "ㄹㅌ": "ㄾ", "ㄹㅍ": "ㄿ", "ㄹㅎ": "ㅀ", "ㅂㅅ": "ㅄ",
    ]

    /// 키보드로 칠 수 있는 자모 한 글자인지 (초성 자음 또는 모음).
    public static func isJamo(_ text: String) -> Bool {
        guard text.count == 1, let c = text.first else { return false }
        return choseong.contains(c) || isVowel(c)
    }

    static func isVowel(_ c: Character) -> Bool { jungseong.contains(c) }

    /// 조합 중인 글자 하나: 초성, 중성(겹모음이면 둘), 받침(겹받침이면 둘).
    struct Syllable: Sendable {
        var initial: Character?
        var vowels: [Character] = []
        var finals: [Character] = []

        func adding(vowel: Character) -> Syllable {
            var copy = self
            copy.vowels.append(vowel)
            return copy
        }

        func adding(final: Character) -> Syllable {
            var copy = self
            copy.finals.append(final)
            return copy
        }

        /// 화면에 보일 글자. 초성+중성이 있으면 완성형 음절, 아니면 자모 하나.
        var text: String {
            let vowel = vowels.count == 2 ? HangulComposer.compoundVowels[String(vowels)] : vowels.first
            let final = finals.count == 2 ? HangulComposer.compoundFinals[String(finals)] : finals.first
            switch (initial, vowel) {
            case (nil, nil): return ""
            case (let initial?, nil): return String(initial)
            case (nil, let vowel?): return String(vowel)
            case (let initial?, let vowel?):
                let cho = HangulComposer.choseong.firstIndex(of: initial)!
                let jung = HangulComposer.jungseong.firstIndex(of: vowel)!
                let jong = final.map { HangulComposer.jongseong.firstIndex(of: $0)! + 1 } ?? 0
                return String(UnicodeScalar(0xAC00 + (cho * 21 + jung) * 28 + jong)!)
            }
        }
    }
}
