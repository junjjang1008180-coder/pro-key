# ARCHITECTURE: 종이 키보드 인식 iPad 키보드 (v2)

## 1. 전체 구조
키보드 확장은 카메라를 쓸 수 없으므로, **인식은 메인 앱, 입력은 키보드 확장**으로 역할을 완전히 나눈다.

```
┌───────────────────────────────┐                      ┌───────────────────────────────┐
│ 메인 앱 (카메라 + 인식)         │                      │ Keyboard Extension (입력만)     │
│                               │   App Group 컨테이너   │                               │
│ CameraService                 │  ┌────────────────┐  │ KeyboardViewController        │
│   → PaperKeyboardDetector     │  │ events.log     │  │   → EventConsumer             │
│   → FingertipTracker          │─►│ (순번 붙은 이벤트)│─►│   → textDocumentProxy         │
│   → PressDetector             │  │ composed.txt   │  │      .insertText / delete     │
│   → EventPublisher            │  │ (모드 B 버퍼)   │  │                               │
│                               │  └────────────────┘  │ 지구본 / 연결 상태 / 넣기 버튼   │
│                               │  Darwin 알림 (깨우기)  │                               │
└───────────────────────────────┘ ───────────────────► └───────────────────────────────┘
```

- 키보드 확장에는 AVFoundation, Vision 코드를 넣지 않는다 (카메라 불가 + 메모리 한도 약 60MB).
- 인식 코드는 메인 앱 전용, 이벤트 포맷과 채널 코드만 `Shared/`로 두 타겟이 공유한다.

## 2. 모듈
| 모듈 | 위치 | 역할 |
|---|---|---|
| `CameraService` | 메인 앱 | 카메라 캡처 (USB 웹캠이 있으면 웹캠, 없으면 전면 초광각), 웹캠 연결/분리 처리, 프레임 드롭 허용, 멀티태스킹 카메라 활성화 시도, 중단(interruption) 처리 |
| `KeyboardLayout` | Shared | JSON(mm 단위) 레이아웃 로드, 키 영역/마커 위치 제공 |
| `PrintableLayoutRenderer` | 코어 패키지 (`PaperKeyboardPrinting`) | 같은 레이아웃으로 인쇄용 PDF 생성. 메인 앱만 링크 |
| `PaperKeyboardDetector` | 메인 앱 | 카메라 프레임 → `MarkerDetector` → `CalibrationLock`을 잇는 얇은 층 (아래 5절) |
| `CoordinateMapper` | 메인 앱 | Vision 정규화 좌표 ↔ 이미지 픽셀 ↔ 종이 mm 좌표 변환 (순수 함수) |
| `FingertipTracker` | 메인 앱 | `VNDetectHumanHandPoseRequest`로 검지 끝(`indexTip`) 추출, 신뢰도 필터, 스무딩 |
| `PressDetector` | 메인 앱 | 누름 판정 상태 머신 (아래 4절) |
| `EventPublisher` | 메인 앱 | 확정된 키 이벤트를 App Group에 기록 + Darwin 알림 발송 |
| `KeyEvent`, `EventChannel` | Shared | 이벤트 포맷, 파일 읽기/쓰기, 알림 이름 상수 |
| `EventConsumer` | 키보드 확장 | 알림 수신 시 새 이벤트만 읽어 입력, 마지막 처리 순번 관리 |
| `KeyboardViewController` | 키보드 확장 | 최소 UI (지구본, 상태, 모드 B 넣기 버튼, 백업용 백스페이스/스페이스) |

## 3. 좌표계 (버그가 가장 많이 나는 곳)
- Vision 결과 좌표는 **0~1 정규화 + 원점이 왼쪽 아래**다. UIKit 화면은 원점이 왼쪽 위다.
- 전면 카메라 프리뷰는 보통 **좌우 반전(미러링)** 되어 보인다. 인식은 반전되지 않은 원본 버퍼 기준으로 하고, 화면 오버레이에서만 반전을 반영한다.
- 카메라 버퍼 방향과 기기 방향(가로/세로)이 다를 수 있다. Vision 요청에 올바른 `orientation`을 넘긴다.
- 원칙: **키 판정은 화면 좌표가 아니라 "카메라 원본 픽셀 → 호모그래피 → 종이 mm 좌표"로만 한다.** 화면 좌표는 디버그 표시에만 쓴다.
- `CoordinateMapper`는 순수 함수로 작성하고, 알려진 점(마커 중심, 키 중심)으로 왕복 변환 단위 테스트를 반드시 작성한다.
- 구현 (`PaperKeyboardCore`): 좌표 공간마다 타입을 나눠 섞이지 않게 한다. `NormalizedPoint`(Vision, 왼쪽 아래 원점) → `PixelPoint`(원본 픽셀, 왼쪽 위 원점) → `PaperPoint`(종이 mm, 왼쪽 위 원점). 미러링은 `CoordinateMapper.mirroredForDisplay`에서만 하고, 미러링 좌표로 판정하면 틀린 키가 나온다는 회귀 테스트가 있다.
- 마커와 손끝은 **같은 orientation으로 Vision에 넘긴 같은 이미지 공간**에서 구해야 한다. 호모그래피가 회전을 흡수하므로 공간만 같으면 버퍼 방향과 무관하게 맞는다.
- 종이 좌표: 원점은 종이 왼쪽 위, x 오른쪽, y 아래, 단위 mm. 레이아웃 JSON도 같은 좌표계다.

## 4. 누름 판정 상태 머신 (`PressDetector`)
```
IDLE ──손끝이 키 영역 진입──► HOVER(key)
HOVER ──같은 키 위에서 손끝 속도가 임계값 이하로 dwell 시간 유지──► PRESSED(key) → 이벤트 1회 발행
HOVER ──다른 키로 이동──► HOVER(newKey)
PRESSED ──손끝이 키 영역 이탈 or 위로 들림(이동량 임계 초과) or 손 사라짐──► IDLE (재입력 허용)
PRESSED ──그대로 머묾──► PRESSED (추가 입력 없음)
```
- 핵심: **PRESSED 이후에는 손을 떼거나 영역을 벗어나야만 다음 입력**이 가능하다. 쿨다운만으로 막으면 손가락을 올려둘 때 반복 입력된다.
- 키 경계 떨림 방지: 키 영역에 작은 여백(hysteresis)을 두고, 진입은 안쪽 영역 기준, 이탈은 바깥 영역 기준으로 판정.
- 손끝 좌표는 지수 이동 평균 등으로 스무딩하고, 신뢰도가 낮은 프레임은 버린다 (손이 사라진 것과 구분).
- 모든 임계값(dwell 시간, 속도, 여백, 신뢰도)은 설정 구조체 하나에 모으고 디버그 화면에서 조절 가능하게 한다.
- 판정에 쓰인 값(속도, 머문 시간, 상태 전이)을 디버그 로그로 남겨 튜닝에 쓴다.
- v1은 **검지 하나**만 추적한다 (양손 중 신뢰도가 높은 손). 여러 손가락은 v2 이후.
- 구현 세부 (`PressDetector`, 설정은 `RecognitionSettings`):
  - 입력은 프레임마다 `Observation`(시각, 종이 mm 손끝 또는 "손 없음", 신뢰도). 스무딩은 그 전에 `FingertipSmoother`가 한다.
  - 신뢰도가 `minConfidence` 미만인 프레임은 버리고 상태를 유지한다. 상태를 IDLE로 되돌리는 것은 "손 없음" 프레임뿐이다.
  - 유효 프레임 간격이 `maxSampleGap`을 넘으면 속도 계산만 새로 시작한다 (끊긴 사이의 이동을 속도로 오해하지 않게).
  - 멈춤 판정 속도는 직전 유효 프레임과의 거리/시간(mm/s). dwell 시간은 처음 멈춘 프레임부터 잰다.
  - 들림 판정은 누른 위치(anchor)에서 `releaseDistance` 이상 멀어진 경우.
- **열린 문제**: 단일 전면 카메라는 깊이를 알 수 없어, "키 위에 손가락을 멈춰 올려 둠"과 "눌렀다가 멈춤"이 화면상 같다. 현재 설계(dwell)에서는 손끝을 키 위에 멈추면 1회 입력된다. PRD 9절 성공 기준 "올려만 두었을 때는 입력되지 않는다"와 충돌하므로 4단계 실기기 튜닝 때 다른 신호(손끝/관절 각도, 접근 방향 등)를 검토한다. 현재 테스트는 "지나가기만 함 → 0회", "누른 채 유지 → 1회"로 해석했다.

## 5. 마커 검출과 보정 고정 (`PaperKeyboardDetector`)
- 네 마커가 모두 보이고, 연속 N프레임 동안 위치 변화가 작으면 호모그래피를 **고정(lock)** 한다.
- 고정 후에는 손이 마커를 가려도 고정값을 계속 쓴다. 마커가 다시 보일 때 위치 차이가 크면(종이가 밀림) "재보정 필요" 상태로 알린다.
- 사용자가 누르는 "재보정" 버튼으로 언제든 다시 잡을 수 있다.
- **결정 (2026-10-17): 왼쪽 위 마커에만 흰 정사각형 구멍.** 네 마커가 같으면 종이가 거꾸로 비칠 때 키가 뒤바뀌므로, 구멍 난 마커를 왼쪽 위로 정하고 거기서 시계 방향으로 나머지를 정한다. 거치 방향을 고정하는 방법보다 사용자가 신경 쓸 것이 적다. 구멍 크기는 레이아웃 JSON `markers.holeSize`(7mm)에 있다.
- **결정: 마커 검출은 Vision 대신 직접 구현한 `MarkerDetector`(순수 Swift).** 인쇄물 모양을 정확히 알고 있으므로 그에 맞춘 검사가 더 확실하고, Mac에서 가짜 카메라 이미지로 끝까지 테스트할 수 있다. 실기기에서 부족하면 Vision `VNDetectRectanglesRequest`를 후보 찾기에 섞는 것을 검토한다.
  1. 주변 평균(적분 이미지, 짧은 변의 25% 창)보다 40% 이상 어두운 픽셀만 고른다. 피부·그림자·옅은 키 테두리는 여기서 빠진다.
  2. 이어진 덩어리 중 크기·가로세로비·채움 비율이 맞는 것을 후보로 하고, 중심이 밝으면 "구멍 있음".
  3. 구멍 있는 후보 1개 + 꽉 찬 후보 3개 중 면적이 비슷하고 볼록 사각형을 이루는 조합을 만든다.
  4. **검증**: 그 조합으로 만든 변환으로 레이아웃의 마커 자리를 이미지에 되돌려 보고, 마커 안(구멍 마커는 테두리 띠)은 검고 마커 바로 바깥과 구멍은 흰지 본다. 마커 하나가 가려졌을 때 키 글자 네 개가 우연히 사각형을 이뤄 통과하던 문제를 이 단계로 막았다 (회귀 테스트 있음).
  5. 통과한 조합 중 면적 합이 가장 큰 것. 실패하면 화면 안내용 이유(`notEnoughMarkers`, `orientationMarkerNotFound`, `noConsistentQuad`)를 돌려준다.
- 입력 `GrayImage`는 카메라 버퍼의 밝기(Y) 평면을 **미러링하지 않은 채** 넣는다. 좌우가 뒤집히면 시계 방향이 반대가 되어 모서리 순서가 틀어진다. 640×360으로 줄여 넣는 것을 기본으로 한다 (Mac release 빌드 기준 1프레임 약 1.6ms).
- `CalibrationLock`: `lockFrameCount`(10) 프레임 연속 흔들림이 대각선의 0.6% 이내면 그 평균으로 고정. 고정 후 검출 실패 프레임은 무시(가림). 마커 **두 개 이상**이 대각선의 1.5% 넘게 벗어난 프레임이 `driftFrameCount`(5)번 연속되면 `needsRecalibration` (기존 변환은 계속 쓰고, `reset()` 전까지 유지). 하나만 벗어난 것은 손에 일부 가려 중심이 흔들린 경우로 본다. 임계값은 모두 `RecognitionSettings`.
- 호모그래피 계산은 `Homography`(점 정규화 + 8x8 연립방정식)로 구현되어 있다. 세 마커가 거의 한 직선이면 계산을 거부한다 (`nil`).

## 6. 앱 ↔ 키보드 이벤트 채널
### 포맷
```
KeyEvent { seq: UInt64(단조 증가), kind: char|space|enter|backspace|tab, value: String?, timestamp: Double }
```
- 글자를 내지 않는 키(shift, languageToggle, control, alt)는 **메인 앱의 `KeyInputResolver`**가 처리하고 이벤트로 보내지 않는다. control/alt는 지금은 동작 없음(iPad 제약). `char`의 `value`는 이미 Shift/한영이 반영된 글자이고, 한글 모드면 자모 하나(예: "ㅂ")다.
- **한글 조합은 키보드 확장에서** `HangulComposer`로 한다. 조합기가 돌려주는 `Edit`(지울 글자 수 + 넣을 글자)를 `deleteBackward()` 반복 + `insertText()`로 적용한다. 조합 상태는 지금 입력창에만 의미가 있으므로, 메인 앱이 아니라 입력창 변화를 아는 키보드가 들고 있어야 한다. `textWillChange`/`selectionDidChange`(사용자가 커서를 옮기거나 입력창이 바뀜), `viewWillAppear`, 그리고 enter/tab 전에 `commit()`해서 엉뚱한 글자를 지우지 않게 한다. 컨트롤러가 새로 만들어지면 조합 상태도 새로 시작하는 것이 맞다.
- `setMarkedText`(밑줄 조합 표시) 대신 지우고 다시 넣는 방식을 쓴다. 앱마다 marked text 처리가 달라 동작이 고르지 않기 때문이다. 실기기에서 문제가 있으면 다시 검토한다.
### 쓰기 (메인 앱)
- App Group 컨테이너의 `events.log`에 한 줄씩 추가 (JSON Lines). 쓰기 후 Darwin 알림 발송.
- 파일이 너무 커지지 않게 오래된 줄은 주기적으로 잘라낸다.
### 읽기 (키보드 확장)
- Darwin 알림을 받으면 파일을 읽고 **`seq`가 마지막 처리 순번보다 큰 것만** 입력한다. 처리 후 마지막 순번을 저장.
- 오래된 이벤트(예: 3초 초과)는 입력하지 않고 건너뛴다. 키보드가 안 보이는 동안 쌓인 입력이 나중에 한꺼번에 쏟아지는 것을 막기 위함.
- 키보드가 처음 나타날 때는 현재 마지막 순번으로 맞추고 시작 (과거 이벤트 재생 금지).
- iOS는 앱마다 키보드 컨트롤러를 새로 만들 수 있으므로 **상태를 컨트롤러 인스턴스에 의존하지 않는다.** 알림 옵저버는 `viewWillAppear`/`viewDidDisappear`에서 등록/해제해 중복 등록을 막는다.
- Darwin 알림은 데이터를 실어 나르지 못하므로 "깨우기" 용도로만 쓰고, 데이터는 항상 파일에서 읽는다. 알림을 놓칠 경우를 대비해 키보드가 보이는 동안 짧은 주기 폴링을 보조로 둔다.
- 구현 (`EventChannel`, `EventLogWriter`, `EventCursor`):
  - 쓰는 쪽은 메인 앱 하나. 시작할 때 파일의 마지막 순번에서 이어 쓴다. 이전 쓰기가 줄 중간에서 끊겼으면 새 줄에서 시작한다.
  - 저장 개수가 `maxStoredEvents`의 두 배를 넘으면 최근 `maxStoredEvents`개만 남기고 파일을 원자적으로 교체한다.
  - 읽기 결과는 해석 못 한 줄 수(`unreadableLines`)를 함께 돌려준다. 쓰는 중인 마지막 줄은 다음 읽기에서 정상으로 읽힌다.
  - 파일의 최대 순번이 커서보다 작으면 (앱 재설치 등으로 순번이 처음부터 다시 시작) 재생 없이 커서를 다시 맞춘다.
  - 커서(`EventCursor.lastSeq`)는 컨트롤러가 아니라 App Group 저장소에 보관한다 (5단계에서 구현).
### 권한
- 키보드 확장의 App Group 쓰기/읽기는 **Full Access(`RequestsOpenAccess = YES`)** 가 없으면 조용히 실패할 수 있다. 키보드 UI에 Full Access 상태(`hasFullAccess`)를 표시하고, 꺼져 있으면 켜는 방법을 안내한다.
### 모드 B
- 메인 앱 입력창의 텍스트를 `composed.txt`에 저장, 키보드의 "보낸 텍스트 넣기" 버튼이 읽어서 `insertText` 후 비운다.

## 7. 키보드 확장 필수 사항
- `needsInputModeSwitchKey`가 true면 지구본 버튼을 표시하고 `handleInputModeList(from:with:)`로 연결.
- 비밀번호 칸 등 서드파티 키보드가 막힌 입력창에서는 시스템 키보드로 바뀌는 것이 정상이다.
- 메모리를 거의 쓰지 않도록 이미지, 큰 리소스를 넣지 않는다.

## 8. 메인 앱 필수 사항
- `Info.plist`: `NSCameraUsageDescription`
- 인식 중 `UIApplication.shared.isIdleTimerDisabled = true`, 종료 시 false
- 카메라 세션 시작/정지는 메인 스레드가 아닌 전용 큐에서, Vision 처리는 별도 직렬 큐에서. `alwaysDiscardsLateVideoFrames = true`로 밀린 프레임 버림.
- 세션 중단 알림(`AVCaptureSession.wasInterruptedNotification`)을 받아 이유를 화면에 표시 (특히 멀티태스킹으로 카메라가 꺼진 경우).
- iOS 16+이면 `isMultitaskingCameraAccessSupported` 확인 후 `isMultitaskingCameraAccessEnabled = true` 설정. 지원 여부를 디버그 화면에 표시.

## 9. 디렉터리 구조
```
PaperKeyboard/
├── CLAUDE.md
├── PRD.md / ARCHITECTURE.md / ESSENTIALS.md
├── PaperKeyboardApp/                 # 메인 앱 타겟
│   ├── App/
│   ├── Camera/CameraService.swift
│   ├── Recognition/
│   │   ├── PaperKeyboardDetector.swift
│   │   ├── CoordinateMapper.swift
│   │   ├── FingertipTracker.swift
│   │   └── PressDetector.swift
│   ├── Layout/PrintableLayoutRenderer.swift
│   ├── Publishing/EventPublisher.swift
│   └── Views/ (온보딩, 디버그 오버레이, 설정, 모드 B 입력창)
├── PaperKeyboardExtension/           # 키보드 확장 타겟 (카메라/Vision 코드 금지)
│   ├── KeyboardViewController.swift
│   └── EventConsumer.swift
├── Shared/                           # 두 타겟 공유
│   ├── KeyEvent.swift
│   ├── EventChannel.swift
│   ├── AppGroup.swift                # 그룹 ID 상수
│   └── KeyboardLayout.swift
├── Resources/layout_qwerty.json
└── Tests/                            # CoordinateMapper, PressDetector, EventChannel 단위 테스트
```

### 실제 배치 (2026-10-12 결정)
카메라·UI와 무관한 순수 로직은 Swift 패키지 `PaperKeyboardCore/`로 분리했다. iPad 없이 Mac에서 `swift test`로 검증할 수 있고, 나중에 앱/확장 Xcode 타겟이 로컬 패키지로 가져다 쓴다. 위 구조의 `Shared/`, `Recognition/` 순수 부분, `Resources/layout_qwerty.json`, `Tests/`가 여기로 옮겨졌다.
```
PaperKeyboardCore/
├── Package.swift
├── Sources/
│   ├── PaperKeyboardShared/          # 앱 + 키보드 확장 공용 (카메라/Vision 금지)
│   │   ├── AppGroup.swift
│   │   ├── KeyEvent.swift            # KeyKind, KeyEvent
│   │   ├── KeyInputResolver.swift    # Shift·한/영 상태 → 보낼 글자 (메인 앱이 사용)
│   │   ├── HangulComposer.swift      # 두벌식 한글 조합 (키보드 확장, 모드 B 입력창이 사용)
│   │   ├── EventChannel.swift        # EventChannel, EventLogWriter, EventCursor
│   │   ├── Geometry.swift            # PaperPoint, PaperRect, CornerQuad
│   │   ├── KeyboardLayout.swift
│   │   └── Resources/layout_qwerty.json
│   ├── PaperKeyboardRecognition/     # 메인 앱 전용 순수 계산 (Vision 호출은 앱 타겟에서)
│   │   ├── CoordinateMapper.swift    # 좌표 타입, Vision↔픽셀, PaperMapping
│   │   ├── Homography.swift
│   │   ├── MarkerDetector.swift      # GrayImage, 모서리 마커 검출 + 검증
│   │   ├── CalibrationLock.swift     # 보정 고정 / 재보정 필요 판정
│   │   ├── FingertipSmoother.swift
│   │   ├── PressDetector.swift
│   │   └── RecognitionSettings.swift # 임계값 모음
│   ├── PaperKeyboardPrinting/        # 메인 앱 전용: 인쇄용 PDF / 흑백 비트맵 그리기
│   │   └── PrintableLayoutRenderer.swift
│   └── layout-pdf/                   # Mac 도구: swift run layout-pdf <출력.pdf>
└── Tests/
    ├── PaperKeyboardSharedTests/
    └── PaperKeyboardRecognitionTests/  # SyntheticCamera: 인쇄 그림을 원근 변환한 가짜 카메라 이미지
Printables/paper_keyboard_qwerty_a4.pdf  # 인쇄용 (layout-pdf로 다시 만들 수 있음)
```
`CameraService`, Vision을 부르는 `FingertipTracker`, 카메라 프레임을 검출기에 잇는 `PaperKeyboardDetector`, `EventPublisher`(Darwin 알림 포함), 키보드 확장 코드는 모드 결정 후 앱 타겟에 만든다.

### 레이아웃 정의 파일 형식 (`layout_qwerty.json`, 단위 mm)
- `paper`: 종이 폭/높이. 현재 A4 가로(297 x 210).
- `markers`: `size`(마커 한 변), `inset`(종이 가장자리에서 마커까지), `holeSize`(왼쪽 위 마커의 흰 구멍 한 변, 테두리가 한쪽 2mm 이상 남아야 함). 마커 중심이 호모그래피 기준점.
- `keyPitch`(키 칸 간격), `keySize`(실제 키 크기). 둘의 차이가 키 사이 틈.
- `rows[]`: `x`, `y`(행 첫 칸의 왼쪽 위)와 `keys[]`. 키는 `kind`(생략 시 `char`), `value`(글자 하나), `shift`(Shift 글자, 영문자는 생략 시 대문자), `ko`/`koShift`(두벌식 자모), `label`(생략 시 대문자), `units`(폭 배수, 기본 1), `id`(같은 종류 특수키가 둘일 때, 예: `shiftRight`). 키 사이가 비는 줄은 같은 `y`로 행을 둘로 나눈다.
- `kind`: `char`, `space`, `enter`, `backspace`, `tab`, `shift`, `languageToggle`, `control`, `alt`.
- 읽을 때 검사: 버전, 키 ID 중복, 종이 밖, 키끼리 겹침, 마커와 겹침, 글자/Shift 값은 한 글자, 한글 값은 자모 한 글자.
- 현재 레이아웃(`qwerty-ko-a4-landscape`): 사용자 키보드 주 영역과 같은 배열, 키 간격 18mm·키 16mm, 키 56개. 방향키·Caps Lock은 사용자 요청으로 뺐고, Ctrl·Alt는 인쇄만 한다.
- 종이 크기와 키 크기는 1단계 실험 3(거치 화각) 결과에 따라 바꿀 수 있다.

## 10. 테스트 전략
- 시뮬레이터에는 카메라가 없다. 인식은 **실제 iPad**에서 검증한다.
- 카메라 없이 테스트할 수 있게 인식 파이프라인 입력을 `CVPixelBuffer` 프레임 스트림으로 추상화하고, 저장된 샘플 이미지로 돌릴 수 있게 한다.
- 단위 테스트 필수 대상:
  - `CoordinateMapper`: 마커/키 중심 왕복 변환
  - `PressDetector`: 손끝 좌표 시퀀스를 넣어 "올려두기만 함 → 입력 0회", "한 번 누름 → 1회", "누른 채 유지 → 1회", "경계 떨림 → 오입력 없음" 검증
  - `EventChannel`: 순번 중복/역순/오래된 이벤트 처리
- 키보드 확장 디버깅: Xcode에서 확장 스킴을 선택하고 실행할 호스트 앱(예: 메모)을 지정하면 확장에 디버거를 붙일 수 있다.
- 순수 로직 테스트 실행: `PaperKeyboardCore` 폴더에서 `swift test` (Mac에서 바로 실행, iPad 불필요). Swift Testing 사용.
