import Foundation
import PaperKeyboardShared

/// 누름(탭) 판정 상태 머신. 누름 판정은 이곳에서만 한다.
///
/// 비스듬한 카메라 하나로 손끝을 보면, 손끝을 **내리면** 종이 좌표가 "들어 올림 방향"의 반대로,
/// **들면** 그 방향으로 움직인다. 그래서 톡 치기는 "빠르게 내려왔다가 다시 올라감"으로 보이고,
/// 가장 낮은 곳이 실제로 닿은 자리다 (공중에 뜬 손끝은 종이 좌표로 실제보다 사용자 쪽에 찍힌다).
///
/// ```
/// TRACKING ── 최근 descentWindow초의 가장 높은 곳보다 descentDistance 내려옴 ──► TOUCHING(가장 낮은 곳)
/// TOUCHING ── 더 내려감 ───────────────────────────────────────────────────────► TOUCHING(새 가장 낮은 곳, 시각 갱신)
/// TOUCHING ── 가장 낮은 곳보다 liftDistance 올라감, 닿은 지 maxTapDuration 이내 ──► 입력 1회 → TRACKING
/// TOUCHING ── 손 사라짐, 닿은 지 maxTapDuration 이내 ─────────────────────────────► 입력 1회 → IDLE
/// TOUCHING ── maxTapDuration 넘게 머묾 ─────────────────────────────────────────► RESTING (올려 둠: 입력 없음)
/// RESTING  ── 다시 descentDistance 더 내려감 ─────────────────────────────────────► TOUCHING
/// RESTING  ── liftDistance 올라감 ───────────────────────────────────────────────► TRACKING (입력 없음)
/// ```
///
/// 입력할 키는 가장 낮은 곳(닿은 자리)의 키다. 키 사이 틈이면 `keySnapDistance` 안의 가장 가까운 키.
/// 같은 키를 다시 치려면 손을 들었다가 다시 내려와야 하므로 쿨다운이 필요 없다.
/// 들어 올림 방향을 모르면 판정하지 않는다 (앱은 종이 변환이 있으면 항상 방향을 넘긴다).
public struct PressDetector: Sendable {
    public enum State: Equatable, Sendable {
        /// 손이 안 보임.
        case idle
        /// 손끝이 보이고 내려오는 중이 아님. 키는 손끝 아래 키 (공중이면 실제보다 사용자 쪽).
        case hover(keyID: String?)
        /// 내려와 닿는 중: 이 상태에서 손을 들면 가장 낮은 곳의 키가 입력된다.
        case touching(keyID: String?)
        /// 오래 올려 둠: 손을 들어도 입력하지 않는다.
        case resting(keyID: String?)
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
        /// TRACKING: 최근 가장 높은 곳보다 내려온 거리 (mm).
        public var descent: Double?
        /// TOUCHING/RESTING: 가장 낮은 곳에 닿은 뒤 지난 시간 (초).
        public var touchDuration: Double?
        /// TOUCHING/RESTING: 가장 낮은 곳보다 올라간 거리 (mm).
        public var liftAmount: Double?
        public var confidence: Double
        /// 이번 프레임에 상태가 바뀌었다면 그 이유들.
        public var transitions: [String]
    }

    public let layout: KeyboardLayout
    public var settings: RecognitionSettings
    public private(set) var diagnostics: Diagnostics?

    /// 가장 낮은 곳 (닿은 자리)과 거기 닿은 시각.
    private struct Bottom: Sendable {
        var point: PaperPoint
        var height: Double
        var since: Double
    }

    private struct Sample: Sendable {
        var time: Double
        var height: Double
    }

    private enum Phase: Sendable {
        case idle
        case tracking
        case touching(Bottom)
        case resting(Bottom)
    }

    private var phase: Phase = .idle
    private var lastPoint: PaperPoint?
    /// 내려옴을 재기 위한 최근 높이 기록 (descentWindow 초).
    private var recent: [Sample] = []
    private var lastSample: (time: Double, point: PaperPoint)?

    public init(layout: KeyboardLayout, settings: RecognitionSettings) {
        self.layout = layout
        self.settings = settings
    }

    public var state: State {
        switch phase {
        case .idle: .idle
        case .tracking: .hover(keyID: lastPoint.flatMap { layout.key(at: $0)?.id })
        case .touching(let bottom): .touching(keyID: key(at: bottom.point)?.id)
        case .resting(let bottom): .resting(keyID: key(at: bottom.point)?.id)
        }
    }

    /// 처음 상태로. 재보정하거나 종이 변환이 없어졌을 때 부른다.
    public mutating func reset() {
        phase = .idle
        lastPoint = nil
        recent = []
        lastSample = nil
        diagnostics = nil
    }

    /// 프레임 하나를 넣는다. 입력이 확정된 프레임(손을 든 순간)에서만 키를 돌려준다.
    public mutating func process(_ observation: Observation) -> KeyboardLayout.Key? {
        var transitions: [String] = []
        var speed: Double?
        var typedKey: KeyboardLayout.Key?
        var descent: Double?
        var liftAmount: Double?

        if let point = observation.fingertip {
            // 신뢰도 낮은 프레임과 방향을 모르는 프레임은 버린다. 손이 사라진 것과 구분해 상태는 그대로 둔다.
            if observation.confidence >= settings.minConfidence, let lift = observation.liftDirection {
                if let last = lastSample, observation.time - last.time <= settings.maxSampleGap {
                    speed = point.distance(to: last.point) / max(observation.time - last.time, 1e-3)
                } else {
                    recent = []   // 오래 끊겼으면 내려옴도 새로 잰다
                }
                lastSample = (observation.time, point)
                lastPoint = point
                typedKey = advance(to: point, height: Self.height(point, along: lift), at: observation.time,
                                   descent: &descent, liftAmount: &liftAmount, transitions: &transitions)
            }
        } else {
            // 손이 사라짐 = 들어 올림으로 본다 (빠른 탭에서 인식이 끊기는 경우 포함).
            if case .touching(let bottom) = phase, observation.time - bottom.since <= settings.maxTapDuration,
               let key = key(at: bottom.point) {
                transitions.append("입력 (\(key.id), 손 사라짐)")
                typedKey = key
            } else if state != .idle {
                transitions.append("손 사라짐")
            }
            phase = .idle
            lastPoint = nil
            recent = []
            lastSample = nil
        }

        var touchDuration: Double?
        switch phase {
        case .touching(let bottom), .resting(let bottom): touchDuration = observation.time - bottom.since
        default: break
        }
        diagnostics = Diagnostics(
            time: observation.time,
            state: state,
            speed: speed,
            descent: descent,
            touchDuration: touchDuration,
            liftAmount: liftAmount,
            confidence: observation.confidence,
            transitions: transitions
        )
        return typedKey
    }

    private mutating func advance(
        to point: PaperPoint,
        height: Double,
        at time: Double,
        descent: inout Double?,
        liftAmount: inout Double?,
        transitions: inout [String]
    ) -> KeyboardLayout.Key? {
        recent.append(Sample(time: time, height: height))
        recent.removeAll { time - $0.time > settings.descentWindow }

        switch phase {
        case .idle, .tracking:
            let peak = recent.map(\.height).max() ?? height
            descent = peak - height
            if peak - height >= settings.descentDistance {
                phase = .touching(Bottom(point: point, height: height, since: time))
                transitions.append("내려옴 (\(key(at: point)?.id ?? "키 밖"))")
            } else {
                phase = .tracking
            }
            return nil

        case .touching(var bottom):
            Self.lower(&bottom, to: point, height: height, at: time)
            liftAmount = height - bottom.height
            if height - bottom.height >= settings.liftDistance {
                let duration = time - bottom.since
                restartTracking(at: time, height: height)
                guard let key = key(at: bottom.point) else {
                    transitions.append("키 밖에서 톡 (입력 없음)")
                    return nil
                }
                transitions.append("입력 (\(key.id), \(Self.format(height - bottom.height))mm 들어 올림, \(Self.format(duration))초 닿음)")
                return key
            }
            if time - bottom.since > settings.maxTapDuration {
                transitions.append("올려 둠 (\(key(at: bottom.point)?.id ?? "키 밖")) · 입력 안 함")
                phase = .resting(bottom)
            } else {
                phase = .touching(bottom)
            }
            return nil

        case .resting(var bottom):
            if bottom.height - height >= settings.descentDistance {
                phase = .touching(Bottom(point: point, height: height, since: time))
                transitions.append("다시 내려옴 (\(key(at: point)?.id ?? "키 밖"))")
                return nil
            }
            if height < bottom.height { (bottom.point, bottom.height) = (point, height) }
            liftAmount = height - bottom.height
            if height - bottom.height >= settings.liftDistance {
                transitions.append("들어 올림 (올려 둔 뒤라 입력 없음)")
                restartTracking(at: time, height: height)
            } else {
                phase = .resting(bottom)
            }
            return nil
        }
    }

    /// 손을 든 뒤: 다음 내려옴은 지금 높이부터 잰다.
    private mutating func restartTracking(at time: Double, height: Double) {
        phase = .tracking
        recent = [Sample(time: time, height: height)]
    }

    /// 닿은 자리의 키. 키 사이 틈이면 `keySnapDistance` 안의 가장 가까운 키.
    private func key(at point: PaperPoint) -> KeyboardLayout.Key? {
        if let key = layout.key(at: point) { return key }
        return layout.keys
            .map { (key: $0, distance: Self.distance(from: point, to: $0.frame)) }
            .filter { $0.distance <= settings.keySnapDistance }
            .min { $0.distance < $1.distance }?.key
    }

    /// 더 낮은 곳으로 내려갔으면 가장 낮은 곳을 옮긴다. 1mm 넘게 더 내려가면 닿은 시각도 새로 잰다
    /// (공중에서 잠깐 멈췄다가 마저 내려와 닿는 경우).
    private static func lower(_ bottom: inout Bottom, to point: PaperPoint, height: Double, at time: Double) {
        guard height < bottom.height else { return }
        if bottom.height - height > 1 { bottom.since = time }
        bottom.point = point
        bottom.height = height
    }

    /// 들어 올림 방향으로 잰 높이 (mm, 기준점은 의미 없음 — 차이만 쓴다).
    private static func height(_ point: PaperPoint, along lift: PaperPoint) -> Double {
        point.x * lift.x + point.y * lift.y
    }

    private static func distance(from point: PaperPoint, to rect: PaperRect) -> Double {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX)
        let dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return hypot(dx, dy)
    }

    private static func format(_ value: Double) -> String {
        String(format: "%.2f", value)
    }
}
