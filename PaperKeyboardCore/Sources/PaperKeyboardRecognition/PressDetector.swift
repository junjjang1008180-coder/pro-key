import Foundation
import PaperKeyboardShared

/// 누름 판정 상태 머신. 누름 판정은 이곳에서만 한다.
///
/// ```
/// IDLE    ── 손끝이 키 안쪽 영역에 진입 ──────────────► HOVER(key)
/// HOVER   ── 같은 키 위에서 멈춘 채 dwell 시간 유지 ──► PRESSED(key) → 이벤트 1회
/// HOVER   ── 키 바깥 영역 이탈 ───────────────────────► IDLE (다른 키 안쪽이면 바로 HOVER(newKey))
/// PRESSED ── 키 바깥 영역 이탈 / 누른 위치에서 멀어짐 / 손 사라짐 ─► IDLE (재입력 허용)
/// PRESSED ── 그대로 머묾 ─────────────────────────────► PRESSED (추가 입력 없음)
/// ```
///
/// PRESSED 이후에는 손을 떼거나 영역을 벗어나야만 다음 입력이 가능하다. 쿨다운으로 막지 않는다.
public struct PressDetector: Sendable {
    public enum State: Equatable, Sendable {
        case idle
        case hover(keyID: String)
        case pressed(keyID: String)
    }

    /// 프레임 하나의 손끝 관측값. 좌표는 이미 종이 mm로 변환·스무딩된 값.
    public struct Observation: Sendable {
        public var time: Double
        /// nil이면 손이 보이지 않는 프레임.
        public var fingertip: PaperPoint?
        public var confidence: Double

        public init(time: Double, fingertip: PaperPoint?, confidence: Double) {
            self.time = time
            self.fingertip = fingertip
            self.confidence = confidence
        }

        public static func fingertip(_ point: PaperPoint, confidence: Double = 1, at time: Double) -> Observation {
            Observation(time: time, fingertip: point, confidence: confidence)
        }

        public static func noHand(at time: Double) -> Observation {
            Observation(time: time, fingertip: nil, confidence: 0)
        }
    }

    /// 튜닝용: 마지막 프레임에서 판정에 쓰인 값.
    public struct Diagnostics: Equatable, Sendable {
        public var time: Double
        public var state: State
        /// mm/s. 직전 유효 프레임이 없으면 nil.
        public var speed: Double?
        /// HOVER에서 멈춘 채 지난 시간 (초).
        public var stillDuration: Double?
        public var confidence: Double
        /// 이번 프레임에 상태가 바뀌었다면 그 이유들.
        public var transitions: [String]
    }

    public let layout: KeyboardLayout
    public var settings: RecognitionSettings
    public private(set) var diagnostics: Diagnostics?

    private enum Phase: Sendable {
        case idle
        case hover(KeyboardLayout.Key, stillSince: Double?)
        case pressed(KeyboardLayout.Key, anchor: PaperPoint)
    }

    private var phase: Phase = .idle
    private var lastSample: (time: Double, point: PaperPoint)?

    public init(layout: KeyboardLayout, settings: RecognitionSettings) {
        self.layout = layout
        self.settings = settings
    }

    public var state: State {
        switch phase {
        case .idle: .idle
        case .hover(let key, _): .hover(keyID: key.id)
        case .pressed(let key, _): .pressed(keyID: key.id)
        }
    }

    /// 처음 상태로. 재보정하거나 종이 변환이 없어졌을 때 부른다.
    public mutating func reset() {
        phase = .idle
        lastSample = nil
        diagnostics = nil
    }

    /// 프레임 하나를 넣는다. 누름이 확정된 프레임에서만 키를 돌려준다.
    public mutating func process(_ observation: Observation) -> KeyboardLayout.Key? {
        var transitions: [String] = []
        var speed: Double?
        var pressedKey: KeyboardLayout.Key?

        if let point = observation.fingertip {
            if let last = lastSample, observation.time - last.time > settings.maxSampleGap {
                lastSample = nil
            }
            // 신뢰도 낮은 프레임은 버린다. 손이 사라진 것과 구분해 상태는 그대로 둔다.
            if observation.confidence >= settings.minConfidence {
                if let last = lastSample {
                    speed = point.distance(to: last.point) / max(observation.time - last.time, 1e-3)
                }
                lastSample = (observation.time, point)
                pressedKey = advance(to: point, at: observation.time, speed: speed, transitions: &transitions)
            }
        } else {
            if state != .idle { transitions.append("손 사라짐") }
            phase = .idle
            lastSample = nil
        }

        var stillDuration: Double?
        if case .hover(_, let since?) = phase { stillDuration = observation.time - since }
        diagnostics = Diagnostics(
            time: observation.time,
            state: state,
            speed: speed,
            stillDuration: stillDuration,
            confidence: observation.confidence,
            transitions: transitions
        )
        return pressedKey
    }

    private mutating func advance(
        to point: PaperPoint,
        at time: Double,
        speed: Double?,
        transitions: inout [String]
    ) -> KeyboardLayout.Key? {
        switch phase {
        case .pressed(let key, let anchor):
            if !outerFrame(of: key).contains(point) {
                transitions.append("키 이탈 (\(key.id))")
            } else if point.distance(to: anchor) > settings.releaseDistance {
                transitions.append("들림: 누른 위치에서 \(Self.format(point.distance(to: anchor)))mm 이동")
            } else {
                return nil
            }
            phase = .idle
            enterKeyIfInside(point, transitions: &transitions)
            return nil

        case .hover(let key, let stillSince):
            guard outerFrame(of: key).contains(point) else {
                transitions.append("키 이탈 (\(key.id))")
                phase = .idle
                enterKeyIfInside(point, transitions: &transitions)
                return nil
            }
            guard let speed, speed <= settings.maxStillSpeed else {
                phase = .hover(key, stillSince: nil)
                return nil
            }
            let since = stillSince ?? time
            if time - since >= settings.dwellDuration {
                transitions.append("누름 확정 (\(key.id), \(Self.format(time - since))초 머묾)")
                phase = .pressed(key, anchor: point)
                return key
            }
            phase = .hover(key, stillSince: since)
            return nil

        case .idle:
            enterKeyIfInside(point, transitions: &transitions)
            return nil
        }
    }

    /// 진입은 안쪽 영역 기준 (경계 떨림 방지).
    private mutating func enterKeyIfInside(_ point: PaperPoint, transitions: inout [String]) {
        guard let key = layout.key(at: point, inset: settings.entryInset) else { return }
        transitions.append("키 진입 (\(key.id))")
        phase = .hover(key, stillSince: nil)
    }

    /// 이탈은 바깥 영역 기준.
    private func outerFrame(of key: KeyboardLayout.Key) -> PaperRect {
        key.frame.insetBy(-settings.exitMargin)
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}
