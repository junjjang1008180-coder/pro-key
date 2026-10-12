// swift-tools-version: 6.2
import PackageDescription

// 카메라/UI와 무관한 순수 로직 패키지.
// iPad 없이 Mac에서 `swift test`로 검증하고, 나중에 메인 앱/키보드 확장 Xcode 타겟이 이 패키지를 가져다 쓴다.
let package = Package(
    name: "PaperKeyboardCore",
    platforms: [.iOS(.v26), .macOS(.v26)],
    products: [
        // 키보드 확장도 링크한다. 카메라/Vision 코드 금지.
        .library(name: "PaperKeyboardShared", targets: ["PaperKeyboardShared"]),
        // 메인 앱 전용 인식 로직 (순수 계산만, Vision 호출은 앱 타겟에서).
        .library(name: "PaperKeyboardRecognition", targets: ["PaperKeyboardRecognition"]),
    ],
    targets: [
        .target(
            name: "PaperKeyboardShared",
            resources: [.copy("Resources/layout_qwerty.json")]
        ),
        .target(
            name: "PaperKeyboardRecognition",
            dependencies: ["PaperKeyboardShared"]
        ),
        .testTarget(
            name: "PaperKeyboardSharedTests",
            dependencies: ["PaperKeyboardShared"]
        ),
        .testTarget(
            name: "PaperKeyboardRecognitionTests",
            dependencies: ["PaperKeyboardRecognition", "PaperKeyboardShared"]
        ),
    ]
)
