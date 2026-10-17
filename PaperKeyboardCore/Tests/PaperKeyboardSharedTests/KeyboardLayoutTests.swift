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
        for kind in [KeyKind.space, .enter, .backspace, .shift] {
            #expect(layout.key(withID: kind.rawValue)?.kind == kind)
        }
    }

    @Test func 키_치수가_정의대로_계산된다() throws {
        let layout = try KeyboardLayout.bundledQWERTY()
        let q = try #require(layout.key(withID: "q"))
        // 행 x 39.25, pitch 19, keySize 17 → gap 2, 키는 칸 안에서 1mm 띄움
        #expect(q.frame == PaperRect(x: 40.25, y: 68, width: 17, height: 17))
        let backspace = try #require(layout.key(withID: "backspace"))
        #expect(backspace.frame.width == 1.5 * 19 - 2)
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
