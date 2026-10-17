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

    @Test func 톡_치면_손을_드는_순간_1회() {
        var s = Script(start: offKeyboard)
        s.move(to: center("f"), speed: 200)
        s.hold(seconds: 0.25)
        s.move(to: lifted(center("f"), by: 6), speed: 150)
        #expect(run(s) == ["f"])
    }

    @Test func 올려_두기만_하면_0회() {
        // PRD 9절 성공 기준: 손가락을 키 위에 올려만 두었을 때는 입력되지 않는다.
        var s = Script(start: offKeyboard)
        s.move(to: center("f"), speed: 200)
        s.hold(seconds: 3)
        #expect(run(s) == [])
    }

    @Test func 올려_뒀다가_들어도_0회() {
        var s = Script(start: offKeyboard)
        s.move(to: center("f"), speed: 200)
        s.hold(seconds: 1.5)
        s.move(to: lifted(center("f"), by: 6), speed: 150)
        s.move(to: offKeyboard, speed: 200)
        #expect(run(s) == [])
    }

    @Test func 같은_키를_두_번_톡톡_치면_2회() {
        // 실기기 버그: l → l이 한 번만 입력됨 (손을 조금만 들면 8mm 이동 기준을 못 넘음)
        var s = Script(start: offKeyboard)
        s.move(to: center("l"), speed: 200)
        s.hold(seconds: 0.2)
        s.move(to: lifted(center("l"), by: 6), speed: 150)
        s.move(to: center("l"), speed: 150)
        s.hold(seconds: 0.2)
        s.move(to: lifted(center("l"), by: 6), speed: 150)
        #expect(run(s) == ["l", "l"])
    }

    @Test func 조금만_들면_아직_닿은_것으로_본다() {
        var detector = PressDetector(layout: layout, settings: settings)
        var s = Script(start: offKeyboard)
        s.move(to: center("f"), speed: 200)
        s.hold(seconds: 0.2)
        s.move(to: lifted(center("f"), by: 2), speed: 150)
        s.hold(seconds: 0.1)
        #expect(s.observations.compactMap { detector.process($0)?.id } == [])
        #expect(detector.state == .touching(keyID: "f"))
    }

    @Test func 닿은_채_옆으로_조금_흔들리다_들면_1회() {
        var s = Script(start: offKeyboard)
        s.move(to: center("f"), speed: 200)
        s.hold(seconds: 0.2)
        let c = center("f")
        s.jitter(between: PaperPoint(x: c.x - 2, y: c.y), and: PaperPoint(x: c.x + 2, y: c.y), seconds: 0.2)
        s.move(to: lifted(c, by: 6), speed: 150)
        #expect(run(s) == ["f"])
    }

    @Test func 공중에서_멈췄다가_내려와_닿고_들면_1회() {
        // 공중에서 멈춘 것도 "닿음"으로 잡히지만, 기준이 가장 낮은 위치로 내려가므로 한 번만 입력된다.
        var s = Script(start: offKeyboard)
        s.move(to: lifted(center("f"), by: 5), speed: 200)
        s.hold(seconds: 0.15)
        s.move(to: center("f"), speed: 150)
        s.hold(seconds: 0.1)
        s.move(to: lifted(center("f"), by: 6), speed: 150)
        #expect(run(s) == ["f"])
    }

    @Test func 닿은_뒤_손이_사라지면_들어_올린_것으로_본다() {
        var s = Script(start: offKeyboard)
        s.move(to: center("f"), speed: 200)
        s.hold(seconds: 0.2)
        s.noHand(seconds: 0.2)
        s.jump(to: offKeyboard)
        s.move(to: center("f"), speed: 200)
        s.hold(seconds: 0.2)
        s.noHand(seconds: 0.2)
        #expect(run(s) == ["f", "f"])
    }

    @Test func 옆_키로_미끄러지면_앞_키가_입력되고_다음_키는_톡_쳐야_입력() {
        var s = Script(start: offKeyboard)
        s.move(to: center("f"), speed: 200)
        s.hold(seconds: 0.2)
        s.move(to: center("g"), speed: 150)
        s.hold(seconds: 0.2)
        s.move(to: lifted(center("g"), by: 6), speed: 150)
        #expect(run(s) == ["f", "g"])
    }

    @Test func 들어_올림_방향을_모르면_거리로_판단한다() {
        var s = Script(start: offKeyboard, lift: nil)
        s.move(to: center("f"), speed: 200)
        s.hold(seconds: 0.2)
        s.move(to: lifted(center("f"), by: 9), speed: 150)   // releaseDistance 8mm 초과
        #expect(run(s) == ["f"])
    }

    @Test func 키_경계에서_빠르게_떨리면_오입력_없음() throws {
        let f = try #require(layout.key(withID: "f"))
        var s = Script(start: offKeyboard)
        s.move(to: PaperPoint(x: f.frame.maxX - 2, y: f.frame.center.y), speed: 200)
        // f 안쪽과 f/g 사이 틈을 오감 (프레임당 3.5mm ≈ 105mm/s)
        s.jitter(between: PaperPoint(x: f.frame.maxX - 2, y: f.frame.center.y),
                 and: PaperPoint(x: f.frame.maxX + 1.5, y: f.frame.center.y), seconds: 1.5)
        #expect(run(s) == [])
    }

    @Test func 키_경계에서_느리게_떨리다_들면_원래_키만_1회() throws {
        let f = try #require(layout.key(withID: "f"))
        var s = Script(start: offKeyboard)
        s.move(to: PaperPoint(x: f.frame.maxX - 2, y: f.frame.center.y), speed: 200)
        // 경계를 1mm씩 넘나듦 (30mm/s): 옆 키 g로 넘어가면 안 된다
        s.jitter(between: PaperPoint(x: f.frame.maxX - 0.5, y: f.frame.center.y),
                 and: PaperPoint(x: f.frame.maxX + 0.5, y: f.frame.center.y), seconds: 0.4)
        s.move(to: PaperPoint(x: f.frame.maxX - 0.5, y: f.frame.center.y + 6), speed: 150)
        #expect(run(s) == ["f"])
    }

    @Test func 재설정하면_닿아_있던_것은_입력하지_않는다() {
        var detector = PressDetector(layout: layout, settings: settings)
        var s = Script(start: center("f"))
        s.hold(seconds: 0.3)
        #expect(s.observations.compactMap { detector.process($0)?.id } == [])
        #expect(detector.state == .touching(keyID: "f"))

        detector.reset()
        #expect(detector.state == .idle)
        #expect(detector.diagnostics == nil)
        let after = detector.process(.fingertip(lifted(center("f"), by: 6), liftDirection: Self.up, at: 10))
        #expect(after == nil)
    }

    @Test func 신뢰도_낮은_프레임은_무시하고_상태를_유지한다() {
        var s = Script(start: offKeyboard)
        s.move(to: center("f"), speed: 200)
        s.hold(seconds: 0.2)
        s.hold(seconds: 0.1, confidence: 0.1)
        s.move(to: lifted(center("f"), by: 6), speed: 150)
        #expect(run(s) == ["f"])
    }

    @Test func 신뢰도_낮은_프레임만으로는_누름이_되지_않는다() {
        var s = Script(start: offKeyboard, confidence: 0.1)
        s.move(to: center("f"), speed: 200, confidence: 0.1)
        s.hold(seconds: 1, confidence: 0.1)
        s.move(to: lifted(center("f"), by: 6), speed: 150, confidence: 0.1)
        #expect(run(s) == [])
    }

    @Test func 상태와_진단값을_남긴다() throws {
        var detector = PressDetector(layout: layout, settings: settings)
        let f = center("f")
        _ = detector.process(.fingertip(f, liftDirection: Self.up, at: 0))
        #expect(detector.state == .hover(keyID: "f"))
        #expect(detector.diagnostics?.transitions == ["키 진입 (f)"])

        var t = 0.0
        while detector.state != .touching(keyID: "f"), t < 1 {
            t += 1.0 / 30
            #expect(detector.process(.fingertip(f, liftDirection: Self.up, at: t)) == nil)
        }
        #expect(detector.state == .touching(keyID: "f"))
        #expect(detector.diagnostics?.transitions == ["닿음 (f)"])
        #expect(detector.diagnostics?.speed == 0)

        let typed = detector.process(.fingertip(lifted(f, by: 6), liftDirection: Self.up, at: t + 1.0 / 30))
        #expect(typed?.id == "f")
        let lift = try #require(detector.diagnostics?.liftAmount)
        #expect(abs(lift - 6) < 1e-9)
        #expect(detector.diagnostics?.transitions.first?.hasPrefix("입력 (f, 들어 올림") == true)
        #expect(detector.state == .hover(keyID: "f"))

        _ = detector.process(.noHand(at: t + 0.2))
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
