import Foundation
import Testing
@testable import PaperKeyboardShared

struct KeyInputResolverTests {
    static let layout = try! KeyboardLayout.bundledQWERTY()

    static func key(_ id: String) -> KeyboardLayout.Key { layout.key(withID: id)! }

    /// 키 ID 순서대로 눌러 내보낸 글자/종류를 모은다.
    static func press(_ ids: [String], resolver: inout KeyInputResolver) -> [String] {
        ids.compactMap { id in
            resolver.resolve(key(id)).map { $0.value ?? $0.kind.rawValue }
        }
    }

    @Test func 영어_기본은_소문자() {
        var r = KeyInputResolver()
        #expect(Self.press(["h", "i"], resolver: &r) == ["h", "i"])
    }

    @Test func Shift는_다음_글자_하나에만() {
        var r = KeyInputResolver()
        #expect(Self.press(["shift", "h", "i"], resolver: &r) == ["H", "i"])
    }

    @Test func Shift를_두_번_누르면_취소() {
        var r = KeyInputResolver()
        #expect(Self.press(["shift", "shiftRight", "a"], resolver: &r) == ["a"])
    }

    @Test func Shift_뒤에_글자가_아닌_키를_누르면_Shift는_사라진다() {
        var r = KeyInputResolver()
        #expect(Self.press(["shift", "space", "a"], resolver: &r) == ["space", "a"])
    }

    @Test func 숫자와_기호는_Shift로_윗글자() {
        var r = KeyInputResolver()
        #expect(Self.press(["shift", "1", "1", "shift", "/", "shift", "'"], resolver: &r) == ["!", "1", "?", "\""])
    }

    @Test func CapsLock은_영문자만_대문자로_하고_Shift와_만나면_소문자() {
        var r = KeyInputResolver()
        #expect(Self.press(["capsLock", "a", "1", "shift", "b", "capsLock", "c"], resolver: &r) == ["A", "1", "b", "c"])
    }

    @Test func 한영_전환_후에는_두벌식_자모() {
        var r = KeyInputResolver()
        #expect(Self.press(["languageToggle", "g", "k", "s"], resolver: &r) == ["ㅎ", "ㅏ", "ㄴ"])
        #expect(r.language == .korean)
        #expect(Self.press(["languageToggle", "g"], resolver: &r) == ["g"])
    }

    @Test func 한글_Shift는_쌍자음과_ㅒㅖ_없으면_그대로() {
        var r = KeyInputResolver()
        #expect(Self.press(["languageToggle", "shift", "r", "shift", "o", "shift", "a", "r"], resolver: &r) == ["ㄲ", "ㅒ", "ㅁ", "ㄱ"])
    }

    @Test func 한글_모드에서도_숫자와_기호는_그대로() {
        var r = KeyInputResolver()
        #expect(Self.press(["languageToggle", "1", "shift", "1", "."], resolver: &r) == ["1", "!", "."])
    }

    @Test func 한글_모드에서_CapsLock은_영향이_없다() {
        var r = KeyInputResolver()
        #expect(Self.press(["languageToggle", "capsLock", "q"], resolver: &r) == ["ㅂ"])
    }

    @Test func 수식키는_아무것도_내보내지_않고_나머지_특수키는_종류로_나간다() {
        var r = KeyInputResolver()
        for id in ["shift", "shiftRight", "capsLock", "languageToggle"] {
            #expect(r.resolve(Self.key(id)) == nil, "\(id)")
        }
        for kind in [KeyKind.space, .enter, .backspace, .tab, .cursorLeft, .cursorRight] {
            #expect(r.resolve(Self.key(kind.rawValue)) == KeyInputResolver.Output(kind: kind))
        }
    }

    @Test func 레이아웃과_조합기를_이으면_한글_문장이_된다() {
        var r = KeyInputResolver()
        var field = FakeTextField()
        // 한/영 → "dkssudgktpdy" = 안녕하세요
        for id in ["languageToggle"] + "dkssudgktpdy".map(String.init) {
            guard let output = r.resolve(Self.key(id)), let value = output.value else { continue }
            field.apply(field.composer.input(value))
        }
        #expect(field.text == "안녕하세요")
    }
}
