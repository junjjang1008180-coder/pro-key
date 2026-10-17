import Foundation
import Testing
@testable import PaperKeyboardShared

/// 조합기가 내놓은 지우기/넣기를 실제 입력창처럼 적용해 보는 가짜 입력창.
struct FakeTextField {
    var text = ""
    var composer = HangulComposer()

    mutating func apply(_ edit: HangulComposer.Edit) {
        text.removeLast(min(edit.deleteCount, text.count))
        text += edit.insert
    }

    mutating func type(_ jamoOrText: String) {
        for character in jamoOrText {
            apply(composer.input(String(character)))
        }
    }

    mutating func backspace(times: Int = 1) {
        for _ in 0..<times { apply(composer.backspace()) }
    }
}

struct HangulComposerTests {
    @Test(arguments: [
        ("ㅎㅏㄴㄱㅡㄹ", "한글"),
        ("ㅇㅏㄴㄴㅕㅇㅎㅏㅅㅔㅇㅛ", "안녕하세요"),
        ("ㄱㅗㅏㅈㅏ", "과자"),          // 겹모음 ㅘ
        ("ㄷㅏㄹㄱ", "닭"),              // 겹받침 ㄺ
        ("ㄷㅏㄹㄱㅇㅣ", "닭이"),         // 겹받침 뒤 자음 초성
        ("ㅇㅣㄹㄱㅓ", "일거"),           // 겹받침 뒤 모음: 뒤 자음만 넘어감
        ("ㅎㅏㄴㅏ", "하나"),             // 받침이 다음 글자 초성으로
        ("ㅇㅓㅂㅅㅇㅓ", "없어"),
        ("ㄲㅗㅊ", "꽃"),                // 쌍자음 초성
        ("ㄱㅏㅆㄷㅏ", "갔다"),           // 쌍자음 받침
        ("ㅇㅢㅅㅏ", "의사"),             // ㅡ + ㅣ = ㅢ
        ("ㄱㅗㅐㄴㅊㅏㄴㅎ", "괜찮"),      // 겹모음 ㅙ + 겹받침 ㄶ (키로는 두 번씩 침)
    ])
    func 자모를_글자로_조합한다(jamo: String, expected: String) {
        var field = FakeTextField()
        field.type(jamo)
        #expect(field.text == expected)
    }

    @Test func 조합되는_동안_화면은_한_글자씩_바뀐다() {
        var field = FakeTextField()
        var steps: [String] = []
        for jamo in "ㅎㅏㄴㅏ" {
            field.type(String(jamo))
            steps.append(field.text)
        }
        #expect(steps == ["ㅎ", "하", "한", "하나"])
    }

    @Test func 받침이_될_수_없는_쌍자음은_새_글자가_된다() {
        var field = FakeTextField()
        field.type("ㄷㅏㄸ")
        #expect(field.text == "다ㄸ")
    }

    @Test func 겹받침_뒤_자음은_새_글자가_된다() {
        var field = FakeTextField()
        field.type("ㄷㅏㄹㄱㄱ")
        #expect(field.text == "닭ㄱ")
    }

    @Test func 자음끼리나_모음끼리는_따로_선다() {
        var field = FakeTextField()
        field.type("ㄱㄴ")
        #expect(field.text == "ㄱㄴ")
        field = FakeTextField()
        field.type("ㅏㅓ")
        #expect(field.text == "ㅏㅓ")
    }

    @Test func 백스페이스는_조합_중인_자모를_하나씩_지운다() {
        var field = FakeTextField()
        field.type("ㄱㅗㅏㄴ")
        #expect(field.text == "관")
        field.backspace()
        #expect(field.text == "과")
        field.backspace()
        #expect(field.text == "고")
        field.backspace()
        #expect(field.text == "ㄱ")
        field.backspace()
        #expect(field.text == "")
        #expect(!field.composer.isComposing)
    }

    @Test func 받침이_넘어간_뒤_백스페이스는_새_글자만_되돌린다() {
        var field = FakeTextField()
        field.type("ㄷㅏㄹㄱㅣ")
        #expect(field.text == "달기")
        field.backspace()
        #expect(field.text == "달ㄱ")
        field.backspace()
        #expect(field.text == "달")
    }

    @Test func 조합이_끝난_뒤_백스페이스는_앞_글자를_통째로_지운다() {
        var field = FakeTextField(text: "abc")
        field.backspace()
        #expect(field.text == "ab")
        field.type("ㅎㅏㄴ ")
        field.backspace()
        field.backspace()
        #expect(field.text == "ab")
    }

    @Test func 한글이_아닌_글자는_조합을_끝내고_그대로_들어간다() {
        var field = FakeTextField()
        field.type("ㅎㅏㄴ")
        field.type("a")
        field.type("ㅏ")
        #expect(field.text == "한aㅏ")
    }

    @Test func commit하면_다음_자모가_앞_글자에_붙지_않는다() {
        var field = FakeTextField()
        field.type("ㅎㅏ")
        field.composer.commit()
        field.type("ㄴ")
        #expect(field.text == "하ㄴ")
    }

    @Test func 자모_판별() {
        #expect(HangulComposer.isJamo("ㅂ"))
        #expect(HangulComposer.isJamo("ㅃ"))
        #expect(HangulComposer.isJamo("ㅢ"))
        #expect(!HangulComposer.isJamo("ㄳ"))   // 겹받침은 키로 칠 수 없음
        #expect(!HangulComposer.isJamo("한"))
        #expect(!HangulComposer.isJamo("a"))
        #expect(!HangulComposer.isJamo("ㅂㅂ"))
    }
}
