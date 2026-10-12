import Foundation

/// 메인 앱과 키보드 확장이 함께 쓰는 App Group 정보.
/// App Group: 같은 개발자의 앱/확장끼리 파일을 공유할 수 있게 해 주는 공용 폴더.
public enum AppGroup {
    /// 무료 계정에서 등록 가능한지는 1단계 실험 2에서 확인한다. 결과에 따라 바뀔 수 있다.
    public static let identifier = "group.com.junjjang.PaperKeyboard"

    /// 컨테이너를 열 수 없으면 nil. 키보드 확장은 Full Access가 꺼져 있으면 여기서 실패할 수 있다.
    public static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: identifier)
    }
}
