import Foundation
import Testing
import PaperKeyboardShared
@testable import PaperKeyboardRecognition

/// ARCHITECTURE.md 10절 시나리오. 30fps로 손끝 좌표(종이 mm)를 흘려 넣는다.
struct PressDetectorTests {
    let layout: KeyboardLayout
    let settings = RecognitionSettings()

    init() throws {
        layout = try KeyboardLayout.bundledQWERTY()
    }

    func center(_ id: String) -> PaperPoint {
        layout.key(withID: id)!.frame.center
    }

    /// 키보드 위쪽 빈 공간 (어떤 키도 아님).
    var offKeyboard: PaperPoint { PaperPoint(x: 150, y: 40) }

    func run(_ script: Script) -> [String] {
        var detector = PressDetector(layout: layout, settings: settings)
        return script.observations.compactMap { detector.process($0)?.id }
    }

    // MARK: 시나리오

    @Test func 키_위를_지나가기만_하면_입력_0회() {
        var s = Script(start: offKeyboard)
        s.move(to: center("a"), speed: 300)
        s.move(to: center("l"), speed: 300)
        s.move(to: offKeyboard, speed: 300)
        s.noHand(seconds: 0.2)
        #expect(run(s) == [])
    }

    /// 맞은편 웹캠에서 손끝을 들면 종이 좌표로는 사용자 쪽(+y)으로 움직인다.
    static let up = PaperPoint(x: 0, y: 1)

    func lifted(_ point: PaperPoint, by mm: Double) -> PaperPoint {
        PaperPoint(x: point.x, y: point.y + mm)
    }

    /// 손끝이 떠 있을 때 보이는 자리: 실제 키보다 사용자 쪽(+y)으로 밀려 찍힌다.
    func air(_ id: String, _ mm: Double = 12) -> PaperPoint {
        lifted(center(id), by: mm)
    }

    @Test func 톡_치면_손을_드는_순간_1회() {
        var s = Script(start: air("f"))
        s.hold(seconds: 0.1)
        s.tap(down: center("f"), up: air("f"))
        #expect(run(s) == ["f"])
    }

    @Test func 빠르게_톡_치면_멈추지_않아도_1회() {
        // 실기기 버그: 빠른 탭은 "멈춤 0.12초" 조건을 못 채워 "위에 있음"에서 안 넘어감
        var s = Script(start: air("f"))
        s.tap(down: center("f"), up: air("f"), hold: 0)
        #expect(run(s) == ["f"])
    }

    @Test func 올려_두기만_하면_0회() {
        // PRD 9절 성공 기준: 손가락을 키 위에 올려만 두었을 때는 입력되지 않는다.
        var s = Script(start: air("f"))
        s.move(to: center("f"), speed: 300)
        s.hold(seconds: 3)
        #expect(run(s) == [])
    }

    @Test func 올려_뒀다가_들어도_0회() {
        var s = Script(start: air("f"))
        s.move(to: center("f"), speed: 300)
        s.hold(seconds: 1.5)
        s.move(to: air("f"), speed: 300)
        #expect(run(s) == [])
    }

    @Test func 같은_키를_두_번_톡톡_치면_2회() {
        // 실기기 버그: l → l이 한 번만 입력됨
        var s = Script(start: air("l"))
        s.tap(down: center("l"), up: air("l"))
        s.hold(seconds: 0.1)
        s.tap(down: center("l"), up: air("l"))
        #expect(run(s) == ["l", "l"])
    }

    @Test func 공중_손끝은_밀려_보여도_닿은_자리의_키를_입력한다() {
        // r 위 공중의 손끝은 한 줄 아래(f) 위에 있는 것처럼 찍힌다. 입력은 내려와 닿은 r.
        var detector = PressDetector(layout: layout, settings: settings)
        _ = detector.process(.fingertip(air("r"), liftDirection: Self.up, at: 0))
        #expect(detector.state == .hover(keyID: "f"))
        var s = Script(start: air("r"))
        s.tap(down: center("r"), up: air("r"))
        #expect(run(s) == ["r"])
    }

    @Test func 조금만_들면_아직_닿은_것으로_본다() {
        var detector = PressDetector(layout: layout, settings: settings)
        var s = Script(start: air("f"))
        s.move(to: center("f"), speed: 300)
        s.hold(seconds: 0.1)
        s.move(to: lifted(center("f"), by: 2), speed: 150)
        #expect(s.observations.compactMap { detector.process($0)?.id } == [])
        #expect(detector.state == .touching(keyID: "f"))
    }

    @Test func 닿은_채_옆으로_조금_흔들리다_들면_1회() {
        var s = Script(start: air("f"))
        s.move(to: center("f"), speed: 300)
        let c = center("f")
        s.jitter(between: PaperPoint(x: c.x - 2, y: c.y), and: PaperPoint(x: c.x + 2, y: c.y), seconds: 0.2)
        s.move(to: air("f"), speed: 300)
        #expect(run(s) == ["f"])
    }

    @Test func 공중에서_잠깐_멈췄다가_내려와_치면_1회() {
        var s = Script(start: air("f"))
        s.move(to: air("f", 6), speed: 300)   // 반쯤 내려와서
        s.hold(seconds: 0.3)                    // 잠깐 멈춤
        s.tap(down: center("f"), up: air("f"))  // 마저 내려와 톡
        #expect(run(s) == ["f"])
    }

    @Test func 공중에서_오래_멈췄다가_내려와_쳐도_1회() {
        var s = Script(start: air("f"))
        s.move(to: air("f", 6), speed: 300)
        s.hold(seconds: 1)                      // 올려 둠으로 바뀔 만큼 오래
        s.tap(down: center("f"), up: air("f"))
        #expect(run(s) == ["f"])
    }

    @Test func 닿은_뒤_손이_사라지면_들어_올린_것으로_본다() {
        var s = Script(start: air("f"))
        s.move(to: center("f"), speed: 300)
        s.hold(seconds: 0.1)
        s.noHand(seconds: 0.2)
        s.jump(to: air("f"))
        s.tap(down: center("f"), up: air("f"))
        #expect(run(s) == ["f", "f"])
    }

    @Test func 키_사이_틈에_닿으면_가까운_키() throws {
        let f = try #require(layout.key(withID: "f"))
        let gap = PaperPoint(x: f.frame.maxX + 0.7, y: f.frame.center.y)   // f와 g 사이 2mm 틈, f에 더 가까움
        var s = Script(start: lifted(gap, by: 12))
        s.tap(down: gap, up: lifted(gap, by: 12))
        #expect(run(s) == ["f"])
    }

    @Test func 키_밖에서_치면_0회() {
        var s = Script(start: lifted(offKeyboard, by: 12))
        s.tap(down: offKeyboard, up: lifted(offKeyboard, by: 12))
        #expect(run(s) == [])
    }

    @Test func 공중에서_옆으로만_옮겨_다니면_0회() {
        var s = Script(start: air("a"))
        s.move(to: air("l"), speed: 300)
        s.move(to: air("s"), speed: 300)
        s.hold(seconds: 0.5)
        #expect(run(s) == [])
    }

    @Test func 들어_올림_방향을_모르면_판정하지_않는다() {
        var s = Script(start: air("f"), lift: nil)
        s.tap(down: center("f"), up: air("f"))
        #expect(run(s) == [])
    }

    @Test func 키_경계에서_빠르게_떨리면_오입력_없음() throws {
        let f = try #require(layout.key(withID: "f"))
        var s = Script(start: PaperPoint(x: f.frame.maxX - 2, y: f.frame.center.y))
        // 닿은 채 f 안쪽과 f/g 사이 틈을 옆으로 오감: 위아래 움직임이 없으니 입력도 없다
        s.jitter(between: PaperPoint(x: f.frame.maxX - 2, y: f.frame.center.y),
                 and: PaperPoint(x: f.frame.maxX + 1.5, y: f.frame.center.y), seconds: 1.5)
        #expect(run(s) == [])
    }

    @Test func 재설정하면_닿아_있던_것은_입력하지_않는다() {
        var detector = PressDetector(layout: layout, settings: settings)
        var s = Script(start: air("f"))
        s.move(to: center("f"), speed: 300)
        s.hold(seconds: 0.1)
        #expect(s.observations.compactMap { detector.process($0)?.id } == [])
        #expect(detector.state == .touching(keyID: "f"))

        detector.reset()
        #expect(detector.state == .idle)
        #expect(detector.diagnostics == nil)
        let after = detector.process(.fingertip(air("f"), liftDirection: Self.up, at: 10))
        #expect(after == nil)
    }

    @Test func 신뢰도_낮은_프레임은_무시하고_상태를_유지한다() {
        var s = Script(start: air("f"))
        s.move(to: center("f"), speed: 300)
        s.hold(seconds: 0.05)
        s.hold(seconds: 0.1, confidence: 0.1)
        s.move(to: air("f"), speed: 300)
        #expect(run(s) == ["f"])
    }

    @Test func 신뢰도_낮은_프레임만으로는_누름이_되지_않는다() {
        var s = Script(start: air("f"), confidence: 0.1)
        s.move(to: center("f"), speed: 300, confidence: 0.1)
        s.hold(seconds: 0.1, confidence: 0.1)
        s.move(to: air("f"), speed: 300, confidence: 0.1)
        #expect(run(s) == [])
    }

    @Test func 상태와_진단값을_남긴다() throws {
        var detector = PressDetector(layout: layout, settings: settings)
        let dt = 1.0 / 30
        _ = detector.process(.fingertip(air("f"), liftDirection: Self.up, at: 0))
        guard case .hover = detector.state else { Issue.record("처음엔 hover"); return }

        // 6mm씩 내려옴: 첫 프레임에서 내려옴(4mm 이상) 감지
        _ = detector.process(.fingertip(air("f", 6), liftDirection: Self.up, at: dt))
        #expect(detector.state == .touching(keyID: "f"))
        #expect(detector.diagnostics?.transitions == ["내려옴 (f)"])
        _ = detector.process(.fingertip(center("f"), liftDirection: Self.up, at: 2 * dt))
        #expect(detector.diagnostics?.liftAmount == 0)

        let typed = detector.process(.fingertip(air("f", 6), liftDirection: Self.up, at: 3 * dt))
        #expect(typed?.id == "f")
        let lift = try #require(detector.diagnostics?.liftAmount)
        #expect(abs(lift - 6) < 1e-9)
        #expect(detector.diagnostics?.transitions.first?.hasPrefix("입력 (f, 6.00mm 들어 올림") == true)

        _ = detector.process(.noHand(at: 4 * dt))
        #expect(detector.state == .idle)
        #expect(detector.diagnostics?.transitions == ["손 사라짐"])
    }
}

/// 30fps 손끝 관측 시퀀스를 만드는 도우미.
struct Script {
    static let frameInterval = 1.0 / 30

    private(set) var observations: [PressDetector.Observation] = []
    private var time = 0.0
    private var position: PaperPoint
    /// 손끝 들어 올림 방향. 기본은 맞은편 웹캠 (+y). nil이면 모른다고 넘긴다.
    private let lift: PaperPoint?

    init(start: PaperPoint, confidence: Double = 1, lift: PaperPoint? = PaperPoint(x: 0, y: 1)) {
        position = start
        self.lift = lift
        emit(confidence: confidence)
    }

    /// 지정 속도(mm/s)로 직선 이동.
    mutating func move(to target: PaperPoint, speed: Double, confidence: Double = 1) {
        let start = position
        let frames = max(1, Int((start.distance(to: target) / speed / Self.frameInterval).rounded(.up)))
        for i in 1...frames {
            let t = Double(i) / Double(frames)
            position = PaperPoint(x: start.x + (target.x - start.x) * t, y: start.y + (target.y - start.y) * t)
            emit(confidence: confidence)
        }
    }

    /// 공중(`up`)에서 `down`으로 빠르게 내려와 `hold`초 닿았다가 다시 올라감.
    mutating func tap(down: PaperPoint, up: PaperPoint, hold seconds: Double = 0.05, speed: Double = 300) {
        move(to: down, speed: speed)
        hold(seconds: seconds)
        move(to: up, speed: speed)
    }

    mutating func hold(seconds: Double, confidence: Double = 1) {
        for _ in 0..<frames(seconds) { emit(confidence: confidence) }
    }

    /// 두 점을 프레임마다 번갈아 오간다.
    mutating func jitter(between a: PaperPoint, and b: PaperPoint, seconds: Double) {
        for i in 0..<frames(seconds) {
            position = i.isMultiple(of: 2) ? b : a
            emit(confidence: 1)
        }
    }

    mutating func noHand(seconds: Double) {
        for _ in 0..<frames(seconds) {
            time += Self.frameInterval
            observations.append(.noHand(at: time))
        }
    }

    /// 손이 안 보이던 사이 다른 곳에서 다시 나타남 (이동 프레임 없이).
    mutating func jump(to point: PaperPoint) {
        position = point
        emit(confidence: 1)
    }

    private func frames(_ seconds: Double) -> Int {
        Int((seconds / Self.frameInterval).rounded())
    }

    private mutating func emit(confidence: Double) {
        time += Self.frameInterval
        observations.append(.fingertip(position, confidence: confidence, liftDirection: lift, at: time))
    }
}
