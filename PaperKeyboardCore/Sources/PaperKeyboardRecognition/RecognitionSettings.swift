import Foundation

/// 인식/누름 판정 임계값을 한곳에 모은 설정. 코드 다른 곳에 숫자를 적지 말 것.
/// 기본값은 출발점일 뿐이며, 실기기에서 디버그 화면으로 조절한 결과를 여기에 반영한다.
public struct RecognitionSettings: Equatable, Sendable {
    /// 이보다 신뢰도가 낮은 손끝 프레임은 버린다 (손이 사라진 것으로 보지 않음).
    public var minConfidence: Double = 0.5
    /// 손끝 스무딩(지수 이동 평균)에서 새 값의 비중. 1이면 스무딩 없음.
    public var smoothingFactor: Double = 0.5
    /// 유효 프레임 간격이 이보다 길면 스무딩과 속도 계산을 새로 시작한다 (초).
    public var maxSampleGap: Double = 0.25

    /// 이 속도 이하이면 "멈춤"으로 본다 (mm/s).
    public var maxStillSpeed: Double = 50
    /// 같은 키 위에서 멈춘 채 이만큼 지나면 누름으로 확정한다 (초).
    public var dwellDuration: Double = 0.12
    /// 키 진입은 키 영역을 이만큼 안쪽으로 줄여서 판정한다 (mm).
    public var entryInset: Double = 1.5
    /// 키 이탈은 키 영역을 이만큼 바깥으로 넓혀서 판정한다 (mm).
    public var exitMargin: Double = 2
    /// 누른 위치에서 이보다 멀어지면 손을 든 것으로 보고 다음 입력을 허용한다 (mm).
    public var releaseDistance: Double = 8

    public init() {}
}
