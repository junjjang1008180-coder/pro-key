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

    @Test func 한_번_누르면_1회() {
        var s = Script(start: offKeyboard)
        s.move(to: center("f"), speed: 200)
        s.hold(seconds: 0.4)
        s.move(to: offKeyboard, speed: 200)
        #expect(run(s) == ["f"])
    }

    @Test func 누른_채_유지하면_1회() {
        var s = Script(start: offKeyboard)
        s.move(to: center("f"), speed: 200)
        s.hold(seconds: 3)
        #expect(run(s) == ["f"])
    }

    @Test func 누른_채_조금_흔들려도_1회() {
        var s = Script(start: offKeyboard)
        s.move(to: center("f"), speed: 200)
        s.hold(seconds: 0.3)
        let c = center("f")
        s.jitter(between: PaperPoint(x: c.x - 3, y: c.y + 2), and: PaperPoint(x: c.x + 3, y: c.y - 2), seconds: 1)
        #expect(run(s) == ["f"])
    }

    @Test func 손을_뗐다가_다시_누르면_2회() {
        var s = Script(start: offKeyboard)
        s.move(to: center("f"), speed: 200)
        s.hold(seconds: 0.3)
        s.noHand(seconds: 0.2)
        s.jump(to: offKeyboard)
        s.move(to: center("f"), speed: 200)
        s.hold(seconds: 0.3)
        #expect(run(s) == ["f", "f"])
    }

    @Test func 누른_위치에서_들어올리듯_멀어지면_다시_누를_수_있다() {
        var s = Script(start: offKeyboard)
        s.move(to: center("f"), speed: 200)
        s.hold(seconds: 0.3)
        // 키 밖(위쪽)으로 들었다가 같은 키로 다시
        s.move(to: PaperPoint(x: center("f").x, y: center("f").y - 30), speed: 200)
        s.move(to: center("f"), speed: 200)
        s.hold(seconds: 0.3)
        #expect(run(s) == ["f", "f"])
    }

    @Test func 옆_키로_미끄러져_멈추면_각각_1회() {
        var s = Script(start: offKeyboard)
        s.move(to: center("f"), speed: 200)
        s.hold(seconds: 0.3)
        s.move(to: center("g"), speed: 150)
        s.hold(seconds: 0.3)
        #expect(run(s) == ["f", "g"])
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

    @Test func 키_경계에서_느리게_떨리면_원래_키만_1회() throws {
        let f = try #require(layout.key(withID: "f"))
        var s = Script(start: offKeyboard)
        s.move(to: PaperPoint(x: f.frame.maxX - 2, y: f.frame.center.y), speed: 200)
        // 경계를 1mm씩 넘나듦 (30mm/s): 옆 키 g로 넘어가면 안 된다
        s.jitter(between: PaperPoint(x: f.frame.maxX - 0.5, y: f.frame.center.y),
                 and: PaperPoint(x: f.frame.maxX + 0.5, y: f.frame.center.y), seconds: 1.5)
        #expect(run(s) == ["f"])
    }

    @Test func 재설정하면_누른_상태가_풀려_같은_키를_다시_누를_수_있다() {
        var detector = PressDetector(layout: layout, settings: settings)
        var hold = Script(start: center("f"))
        hold.hold(seconds: 0.3)
        let first = hold.observations.compactMap { detector.process($0)?.id }
        #expect(first == ["f"])
        #expect(detector.state == .pressed(keyID: "f"))

        detector.reset()
        #expect(detector.state == .idle)
        #expect(detector.diagnostics == nil)
        let second = hold.observations.map { PressDetector.Observation(time: $0.time + 10, fingertip: $0.fingertip, confidence: $0.confidence) }
            .compactMap { detector.process($0)?.id }
        #expect(second == ["f"])
    }

    @Test func 신뢰도_낮은_프레임은_무시하고_상태를_유지한다() {
        var s = Script(start: offKeyboard)
        s.move(to: center("f"), speed: 200)
        s.hold(seconds: 0.3)
        s.hold(seconds: 0.6, confidence: 0.1)
        s.hold(seconds: 0.3)
        #expect(run(s) == ["f"])
    }

    @Test func 신뢰도_낮은_프레임만으로는_누름이_되지_않는다() {
        var s = Script(start: offKeyboard, confidence: 0.1)
        s.move(to: center("f"), speed: 200, confidence: 0.1)
        s.hold(seconds: 1, confidence: 0.1)
        #expect(run(s) == [])
    }

    @Test func 상태와_진단값을_남긴다() {
        var detector = PressDetector(layout: layout, settings: settings)
        let f = center("f")
        _ = detector.process(.fingertip(f, at: 0))
        #expect(detector.state == .hover(keyID: "f"))
        #expect(detector.diagnostics?.transitions == ["키 진입 (f)"])

        var t = 0.0
        var pressedAt: Double?
        while pressedAt == nil, t < 1 {
            t += 1.0 / 30
            if detector.process(.fingertip(f, at: t)) != nil { pressedAt = t }
        }
        #expect(detector.state == .pressed(keyID: "f"))
        #expect(pressedAt != nil)
        #expect(detector.diagnostics?.speed == 0)

        _ = detector.process(.noHand(at: t + 0.1))
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

    init(start: PaperPoint, confidence: Double = 1) {
        position = start
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
        observations.append(.fingertip(position, confidence: confidence, at: time))
    }
}
