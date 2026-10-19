import Foundation

/// 인식/누름 판정 임계값을 한곳에 모은 설정. 코드 다른 곳에 숫자를 적지 말 것.
/// 기본값은 출발점일 뿐이며, 실기기에서 디버그 화면으로 조절한 결과를 여기에 반영한다.
public struct RecognitionSettings: Equatable, Sendable {
    /// 이보다 신뢰도가 낮은 손끝 프레임은 버린다 (손이 사라진 것으로 보지 않음).
    public var minConfidence: Double = 0.5
    /// 손끝 스무딩(지수 이동 평균)에서 새 값의 비중. 1이면 스무딩 없음.
    /// 톡 치는 동작의 오르내림이 너무 깎이지 않도록 새 값 비중을 높게 둔다.
    public var smoothingFactor: Double = 0.7
    /// 유효 프레임 간격이 이보다 길면 스무딩과 속도 계산을 새로 시작한다 (초).
    public var maxSampleGap: Double = 0.25

    // MARK: 누름(탭) 판정 (PressDetector)
    // 비스듬한 카메라에서 손끝을 내리면 종이 좌표가 "들어 올림 방향"의 반대로, 들면 그 방향으로 움직인다.
    // 거리는 모두 그 방향으로 잰 값 (mm).

    /// 최근 `descentWindow`초 안의 가장 높은 곳보다 이만큼 내려오면 "내려와 닿는 중"으로 본다.
    public var descentDistance: Double = 4
    /// 내려옴을 잴 때 돌아보는 시간 (초). 천천히 내려오는 것은 톡 치기로 보지 않는다.
    public var descentWindow: Double = 0.5
    /// 내려온 가장 낮은 곳에서 이만큼 다시 올라가면 손을 든 것으로 보고 입력한다.
    public var liftDistance: Double = 4
    /// 가장 낮은 곳에 닿은 뒤 이 시간 안에 들어야 입력한다 (초). 더 오래 머물면 "올려 둔 것"으로 보고 입력하지 않는다.
    public var maxTapDuration: Double = 0.6
    /// 닿은 곳이 키 사이 틈이면 이 거리 안의 가장 가까운 키로 본다 (mm). 틈은 2mm이므로 반쯤이면 충분.
    public var keySnapDistance: Double = 1.5

    // MARK: 마커 검출 (MarkerDetector)

    /// 카메라 영상을 이 폭 정도로 줄여서 마커를 찾는다 (픽셀). 1920 폭이면 3칸씩 묶어 640.
    public var detectionImageWidth: Int = 640
    /// 보정이 고정된 뒤에는 밀림 확인만 하면 되므로 이 프레임 수마다 한 번만 검출한다.
    public var lockedDetectionInterval: Int = 3

    /// 주변 평균 밝기를 구하는 창의 한 변. 이미지 짧은 변에 대한 비율. 마커보다 충분히 커야 마커 속이 검게 잡힌다.
    public var markerThresholdWindowFraction: Double = 0.25
    /// 주변 평균보다 이 비율 이상 어두우면 "검은 픽셀"로 본다 (0.4 = 40% 더 어두움).
    /// 마커는 새까맣고 피부·그림자·옅은 키 테두리는 덜 어두우므로, 크게 잡아야 손이 마커와 합쳐져 보이지 않는다.
    public var markerThresholdOffset: Double = 0.4
    /// 마커 덩어리 한 변의 최소/최대 크기. 이미지 짧은 변에 대한 비율.
    public var markerMinSizeFraction: Double = 0.015
    public var markerMaxSizeFraction: Double = 0.25
    /// 덩어리가 자기 외곽 상자를 채우는 최소 비율. 글자나 키 테두리(얇은 선)를 걸러낸다.
    public var markerMinFillRatio: Double = 0.35
    /// 외곽 상자의 긴 변 / 짧은 변 최대값. 비스듬히 찍혀 납작해진 마커까지 허용한다.
    public var markerMaxAspectRatio: Double = 2.5
    /// 고른 네 마커의 면적 최대/최소 비율. 원근 때문에 먼 마커가 작게 보이는 정도까지 허용한다.
    public var markerMaxAreaRatio: Double = 8
    /// 네 후보로 변환을 만든 뒤, 마커가 있어야 할 자리는 검고 그 바깥은 흰지 확인한다.
    /// 확인 지점 중 이 비율 이상이 맞아야 종이로 인정한다 (글자 네 개가 우연히 사각형을 이룬 경우를 걸러냄).
    public var markerVerifyMinRatio: Double = 0.9
    /// "마커 바깥은 흰 종이" 확인 지점을 마커 가장자리에서 얼마나 떨어뜨릴지. 마커 한 변에 대한 비율.
    public var markerVerifyMarginFraction: Double = 0.2

    // MARK: 보정 고정 (CalibrationLock)

    /// 마커가 이 프레임 수만큼 연속으로 안정되면 보정을 고정한다.
    public var lockFrameCount: Int = 10
    /// 안정 판정 허용 흔들림. 마커 대각선(왼쪽 위↔오른쪽 아래) 길이에 대한 비율.
    public var lockMaxJitter: Double = 0.006
    /// 고정 후 마커가 고정 위치에서 이 비율 이상 벗어나면 밀린 것으로 본다 (대각선 대비).
    /// 마커 하나만 벗어난 것은 손에 일부 가려 중심이 흔들린 것일 수 있으므로 두 개 이상일 때만 센다.
    public var driftThreshold: Double = 0.015
    /// 밀림이 이 프레임 수만큼 연속되면 "재보정 필요"로 바꾼다 (한두 프레임 오검출은 무시).
    public var driftFrameCount: Int = 5

    public init() {}
}
