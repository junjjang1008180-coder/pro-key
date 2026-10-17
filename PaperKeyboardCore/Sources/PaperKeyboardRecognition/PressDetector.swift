import Foundation
import PaperKeyboardShared

/// 누름(탭) 판정 상태 머신. 누름 판정은 이곳에서만 한다.
///
/// 카메라 하나로는 "닿음"과 "올려 둠"이 같아 보이므로, **닿았다가 곧 손을 들어야** 입력한다 (탭).
/// 손끝을 키 위에 오래 올려 두면 입력하지 않는다 (PRD 9절: 올려만 두면 입력되지 않음).
///
/// ```
/// IDLE     ── 손끝이 키 안쪽 영역에 진입 ──────────────────► HOVER(key)
/// HOVER    ── 같은 키 위에서 멈춘 채 dwell 시간 유지 ─────► TOUCHING(key)   (아직 입력 안 함)
/// HOVER    ── 키 바깥 영역 이탈 ───────────────────────────► IDLE (다른 키 안쪽이면 바로 HOVER)
/// TOUCHING ── 들림(위로 liftDistance / 키 이탈 / 손 사라짐),
///             닿은 지 maxTapDuration 이내 ────────────────► 입력 1회 → IDLE
/// TOUCHING ── maxTapDuration 넘게 머묾 ────────────────────► RESTING(key)   (올려 둠: 입력 없음)
/// RESTING  ── 들림 ────────────────────────────────────────► IDLE (입력 없음)
/// ```
///
/// 들림 판정: 비스듬한 카메라에서는 손끝을 들면 영상에서 위로 움직이고, 종이 좌표로는
/// "들어 올림 방향"(`Observation.liftDirection`)으로 움직인다. 닿은 동안 그 방향으로 가장 낮았던
/// 위치를 기준으로 `liftDistance` 넘게 올라가면 든 것으로 본다. 방향을 모르면 `releaseDistance`를 쓴다.
public struct PressDetector: Sendable {
    public enum State: Equatable, Sendable {
        case idle
        case hover(keyID: String)
        /// 닿음: 이 상태에서 손을 들면 입력된다.
        case touching(keyID: String)
        /// 오래 올려 둠: 손을 들어도 입력하지 않는다.
        case resting(keyID: String)
    }

    /// 프레임 하나의 손끝 관측값. 좌표는 이미 종이 mm로 변환·스무딩된 값.
    public struct Observation: Sendable {
        public var time: Double
        /// nil이면 손이 보이지 않는 프레임.
        public var fingertip: PaperPoint?
        public var confidence: Double
        /// 손끝을 들어 올리면 종이 좌표에서 움직이는 방향 (단위 벡터, x·y 성분). 모르면 nil.
        public var liftDirection: PaperPoint?

        public init(time: Double, fingertip: PaperPoint?, confidence: Double, liftDirection: PaperPoint? = nil) {
            self.time = time
            self.fingertip = fingertip
            self.confidence = confidence
            self.liftDirection = liftDirection
        }

        public static func fingertip(_ point: PaperPoint, confidence: Double = 1, liftDirection: PaperPoint? = nil, at time: Double) -> Observation {
            Observation(time: time, fingertip: point, confidence: confidence, liftDirection: liftDirection)
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
        /// TOUCHING에서 닿은 뒤 지난 시간 (초).
        public var touchDuration: Double?
        /// TOUCHING/RESTING에서 가장 낮았던 위치보다 들어 올림 방향으로 올라간 거리 (mm).
        public var liftAmount: Double?
        public var confidence: Double
        /// 이번 프레임에 상태가 바뀌었다면 그 이유들.
        public var transitions: [String]
    }

    public let layout: KeyboardLayout
    public var settings: RecognitionSettings
    public private(set) var diagnostics: Diagnostics?

    /// 닿은 동안의 기준: 처음 멈춘 시각, 들어 올림 방향으로 가장 낮았던 위치.
    private struct Contact: Sendable {
        var since: Double
        var lowest: PaperPoint
    }

    private enum Phase: Sendable {
        case idle
        case hover(KeyboardLayout.Key, stillSince: Double?)
        case touching(KeyboardLayout.Key, Contact)
        case resting(KeyboardLayout.Key, Contact)
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
        case .touching(let key, _): .touching(keyID: key.id)
        case .resting(let key, _): .resting(keyID: key.id)
        }
    }

    /// 처음 상태로. 재보정하거나 종이 변환이 없어졌을 때 부른다.
    public mutating func reset() {
        phase = .idle
        lastSample = nil
        diagnostics = nil
    }

    /// 프레임 하나를 넣는다. 입력이 확정된 프레임(손을 든 순간)에서만 키를 돌려준다.
    public mutating func process(_ observation: Observation) -> KeyboardLayout.Key? {
        var transitions: [String] = []
        var speed: Double?
        var typedKey: KeyboardLayout.Key?
        var liftAmount: Double?

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
                typedKey = advance(to: point, at: observation.time, speed: speed, lift: observation.liftDirection,
                                   liftAmount: &liftAmount, transitions: &transitions)
            }
        } else {
            // 손이 사라짐 = 들어 올림으로 본다 (빠른 탭에서 인식이 끊기는 경우 포함).
            if case .touching(let key, let contact) = phase, observation.time - contact.since <= settings.maxTapDuration {
                transitions.append("입력 (\(key.id), 손 사라짐)")
                typedKey = key
            } else if state != .idle {
                transitions.append("손 사라짐")
            }
            phase = .idle
            lastSample = nil
        }

        var stillDuration: Double?
        var touchDuration: Double?
        switch phase {
        case .hover(_, let since?): stillDuration = observation.time - since
        case .touching(_, let contact): touchDuration = observation.time - contact.since
        default: break
        }
        diagnostics = Diagnostics(
            time: observation.time,
            state: state,
            speed: speed,
            stillDuration: stillDuration,
            touchDuration: touchDuration,
            liftAmount: liftAmount,
            confidence: observation.confidence,
            transitions: transitions
        )
        return typedKey
    }

    private mutating func advance(
        to point: PaperPoint,
        at time: Double,
        speed: Double?,
        lift: PaperPoint?,
        liftAmount: inout Double?,
        transitions: inout [String]
    ) -> KeyboardLayout.Key? {
        switch phase {
        case .touching(let key, var contact):
            contact.lowest = Self.lower(contact.lowest, point, along: lift)
            liftAmount = lift.map { Self.height(of: point, above: contact.lowest, along: $0) }
            if let reason = release(from: key, contact: contact, to: point, lift: lift) {
                let duration = time - contact.since
                phase = .idle
                enterKeyIfInside(point, transitions: &transitions)
                guard duration <= settings.maxTapDuration else { return nil }
                transitions.insert("입력 (\(key.id), \(reason), \(Self.format(duration))초 닿음)", at: 0)
                return key
            }
            if time - contact.since > settings.maxTapDuration {
                transitions.append("올려 둠 (\(key.id)) · 입력 안 함")
                phase = .resting(key, contact)
            } else {
                phase = .touching(key, contact)
            }
            return nil

        case .resting(let key, var contact):
            contact.lowest = Self.lower(contact.lowest, point, along: lift)
            liftAmount = lift.map { Self.height(of: point, above: contact.lowest, along: $0) }
            if let reason = release(from: key, contact: contact, to: point, lift: lift) {
                transitions.append("\(reason) (올려 둔 뒤라 입력 없음)")
                phase = .idle
                enterKeyIfInside(point, transitions: &transitions)
            } else {
                phase = .resting(key, contact)
            }
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
                transitions.append("닿음 (\(key.id))")
                phase = .touching(key, Contact(since: since, lowest: point))
            } else {
                phase = .hover(key, stillSince: since)
            }
            return nil

        case .idle:
            enterKeyIfInside(point, transitions: &transitions)
            return nil
        }
    }

    /// 손을 들었는지. 들었다면 이유.
    private func release(from key: KeyboardLayout.Key, contact: Contact, to point: PaperPoint, lift: PaperPoint?) -> String? {
        if !outerFrame(of: key).contains(point) { return "키 이탈" }
        if let lift {
            let height = Self.height(of: point, above: contact.lowest, along: lift)
            if height > settings.liftDistance { return "들어 올림 \(Self.format(height))mm" }
            return nil
        }
        let distance = point.distance(to: contact.lowest)
        return distance > settings.releaseDistance ? "닿은 곳에서 \(Self.format(distance))mm 이동" : nil
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

    /// 들어 올림 방향으로 `base`보다 얼마나 높은지 (mm).
    private static func height(of point: PaperPoint, above base: PaperPoint, along lift: PaperPoint) -> Double {
        (point.x - base.x) * lift.x + (point.y - base.y) * lift.y
    }

    /// 들어 올림 방향으로 더 낮은 쪽. 방향을 모르면 처음 위치를 그대로 둔다.
    private static func lower(_ a: PaperPoint, _ b: PaperPoint, along lift: PaperPoint?) -> PaperPoint {
        guard let lift else { return a }
        return height(of: b, above: a, along: lift) < 0 ? b : a
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}
