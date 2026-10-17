import Foundation
import Testing
@testable import PaperKeyboardShared

struct KeyboardLayoutTests {
    @Test func 기본_QWERTY_레이아웃을_읽는다() throws {
        let layout = try KeyboardLayout.bundledQWERTY()
        #expect(layout.paperWidth == 297)
        #expect(layout.paperHeight == 210)
        let letters = Set(layout.keys.filter { $0.kind == .char }.compactMap(\.value))
        for letter in "abcdefghijklmnopqrstuvwxyz" {
            #expect(letters.contains(String(letter)), "\(letter) 키 없음")
        }
        for kind in KeyKind.allCases where kind != .char {
            #expect(layout.key(withID: kind.rawValue)?.kind == kind, "\(kind) 키 없음")
        }
        // 숫자 줄과 기호
        for character in "`1234567890-=[]\\;',./" {
            #expect(layout.key(withID: String(character))?.shiftValue != nil, "\(character) 키 또는 Shift 글자 없음")
        }
        #expect(layout.key(withID: "shiftRight")?.kind == .shift)
        #expect(layout.keys.count == 57)
    }

    @Test func 두벌식_자모가_표준_자리에_있다() throws {
        let layout = try KeyboardLayout.bundledQWERTY()
        let expected: [String: (String, String?)] = [
            "q": ("ㅂ", "ㅃ"), "w": ("ㅈ", "ㅉ"), "e": ("ㄷ", "ㄸ"), "r": ("ㄱ", "ㄲ"), "t": ("ㅅ", "ㅆ"),
            "y": ("ㅛ", nil), "u": ("ㅕ", nil), "i": ("ㅑ", nil), "o": ("ㅐ", "ㅒ"), "p": ("ㅔ", "ㅖ"),
            "a": ("ㅁ", nil), "s": ("ㄴ", nil), "d": ("ㅇ", nil), "f": ("ㄹ", nil), "g": ("ㅎ", nil),
            "h": ("ㅗ", nil), "j": ("ㅓ", nil), "k": ("ㅏ", nil), "l": ("ㅣ", nil),
            "z": ("ㅋ", nil), "x": ("ㅌ", nil), "c": ("ㅊ", nil), "v": ("ㅍ", nil), "b": ("ㅠ", nil), "n": ("ㅜ", nil), "m": ("ㅡ", nil),
        ]
        for (id, (korean, shifted)) in expected {
            let key = try #require(layout.key(withID: id))
            #expect(key.koreanValue == korean, "\(id)")
            #expect(key.koreanShiftValue == shifted, "\(id)")
        }
        // 영문자 26개에만 한글이 있다
        #expect(layout.keys.filter { $0.koreanValue != nil }.count == 26)
    }

    @Test func 영문자의_Shift는_대문자() throws {
        let layout = try KeyboardLayout.bundledQWERTY()
        #expect(layout.key(withID: "q")?.shiftValue == "Q")
        #expect(layout.key(withID: "1")?.shiftValue == "!")
    }

    @Test func 키_치수가_정의대로_계산된다() throws {
        let layout = try KeyboardLayout.bundledQWERTY()
        let q = try #require(layout.key(withID: "q"))
        // 행 x 13.5 + Tab 1.5칸(27), pitch 18, keySize 16 → gap 2, 키는 칸 안에서 1mm 띄움
        #expect(q.frame == PaperRect(x: 41.5, y: 79, width: 16, height: 16))
        let backspace = try #require(layout.key(withID: "backspace"))
        #expect(backspace.frame.width == 2 * 18 - 2)
        #expect(q.label == "Q")
    }

    @Test func 마커_중심은_모서리에서_inset_더하기_반변() throws {
        let layout = try KeyboardLayout.bundledQWERTY()
        #expect(layout.markerCenters.topLeft == PaperPoint(x: 17.5, y: 17.5))
        #expect(layout.markerCenters.topRight == PaperPoint(x: 279.5, y: 17.5))
        #expect(layout.markerCenters.bottomRight == PaperPoint(x: 279.5, y: 192.5))
        #expect(layout.markerCenters.bottomLeft == PaperPoint(x: 17.5, y: 192.5))
    }

    @Test func 왼쪽_위_마커에만_가운데_구멍이_있다() throws {
        let layout = try KeyboardLayout.bundledQWERTY()
        let hole = layout.orientationHoleFrame
        #expect(hole.center == layout.markerCenters.topLeft)
        #expect(hole.width == 7)
        #expect(hole.minX > layout.markerFrames.topLeft.minX && hole.maxX < layout.markerFrames.topLeft.maxX)
    }

    @Test func 구멍이_마커만큼_크면_거부한다() {
        #expect(throws: KeyboardLayout.LayoutError.invalidDimensions("markers.holeSize")) {
            try KeyboardLayout(jsonData: Self.json(rows: "[]", holeSize: 13))
        }
    }

    @Test func 점으로_키를_찾고_안쪽_여백을_반영한다() throws {
        let layout = try KeyboardLayout.bundledQWERTY()
        let f = try #require(layout.key(withID: "f"))
        #expect(layout.key(at: f.frame.center)?.id == "f")
        // 키 사이 틈은 어떤 키도 아님
        #expect(layout.key(at: PaperPoint(x: f.frame.maxX + 1, y: f.frame.center.y)) == nil)
        // 가장자리 0.5mm 안쪽은 inset 0이면 키, inset 1.5면 키 아님
        let nearEdge = PaperPoint(x: f.frame.maxX - 0.5, y: f.frame.center.y)
        #expect(layout.key(at: nearEdge)?.id == "f")
        #expect(layout.key(at: nearEdge, inset: 1.5) == nil)
    }

    @Test func 중복_키는_거부한다() {
        #expect(throws: KeyboardLayout.LayoutError.duplicateKeyID("a")) {
            try KeyboardLayout(jsonData: Self.json(rows: #"[{"x": 40, "y": 60, "keys": [{"value": "a"}, {"value": "a"}]}]"#))
        }
    }

    @Test func 종이_밖으로_나간_키는_거부한다() {
        #expect(throws: KeyboardLayout.LayoutError.keyOutsidePaper("a")) {
            try KeyboardLayout(jsonData: Self.json(rows: #"[{"x": 290, "y": 60, "keys": [{"value": "a"}]}]"#))
        }
    }

    @Test func 마커와_겹친_키는_거부한다() {
        #expect(throws: KeyboardLayout.LayoutError.keyOverlapsMarker("a")) {
            try KeyboardLayout(jsonData: Self.json(rows: #"[{"x": 5, "y": 5, "keys": [{"value": "a"}]}]"#))
        }
    }

    @Test func 겹친_키는_거부한다() {
        #expect(throws: KeyboardLayout.LayoutError.keysOverlap("a", "b")) {
            try KeyboardLayout(jsonData: Self.json(rows: #"[{"x": 40, "y": 60, "keys": [{"value": "a"}]}, {"x": 45, "y": 65, "keys": [{"value": "b"}]}]"#))
        }
    }

    @Test func 자모가_아닌_한글_값은_거부한다() {
        #expect(throws: KeyboardLayout.LayoutError.invalidKey("a: 한글 값은 자모 한 글자여야 함 (가)")) {
            try KeyboardLayout(jsonData: Self.json(rows: #"[{"x": 40, "y": 60, "keys": [{"value": "a", "ko": "가"}]}]"#))
        }
    }

    @Test func 같은_종류_특수키가_둘이면_id로_구분해야_한다() {
        #expect(throws: KeyboardLayout.LayoutError.duplicateKeyID("shift")) {
            try KeyboardLayout(jsonData: Self.json(rows: #"[{"x": 40, "y": 60, "keys": [{"kind": "shift"}, {"kind": "shift"}]}]"#))
        }
    }

    @Test func 버전이_다르면_거부한다() {
        #expect(throws: KeyboardLayout.LayoutError.unsupportedVersion(2)) {
            try KeyboardLayout(jsonData: Self.json(rows: "[]", version: 2))
        }
    }

    static func json(rows: String, version: Int = 1, holeSize: Double = 7) -> Data {
        Data("""
        {"name": "test", "version": \(version), "paper": {"width": 297, "height": 210},
         "markers": {"size": 15, "inset": 10, "holeSize": \(holeSize)}, "keyPitch": 19, "keySize": 17, "rows": \(rows)}
        """.utf8)
    }
}
