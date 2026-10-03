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
| `CameraService` | 메인 앱 | 전면 카메라 캡처, 프레임 드롭 허용, 멀티태스킹 카메라 활성화 시도, 중단(interruption) 처리 |
| `KeyboardLayout` | Shared | JSON(mm 단위) 레이아웃 로드, 키 영역/마커 위치 제공 |
| `PrintableLayoutRenderer` | 메인 앱 | 같은 레이아웃으로 인쇄용 PDF 생성 |
| `PaperKeyboardDetector` | 메인 앱 | 모서리 마커 검출 → 호모그래피(3x3 원근 변환) 계산 → 안정 시 고정 |
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

## 5. 보정 고정 (`PaperKeyboardDetector`)
- 네 마커가 모두 보이고, 연속 N프레임 동안 위치 변화가 작으면 호모그래피를 **고정(lock)** 한다.
- 고정 후에는 손이 마커를 가려도 고정값을 계속 쓴다. 마커가 다시 보일 때 위치 차이가 크면(종이가 밀림) "재보정 필요" 상태로 알린다.
- 사용자가 누르는 "재보정" 버튼으로 언제든 다시 잡을 수 있다.
- 마커 검출 방법 후보: Vision `VNDetectRectanglesRequest`로 종이 외곽 검출, 또는 인쇄된 검은 사각형 마커를 Vision/Core Image로 검출. 1~2단계에서 실험 후 결정하고 결과를 이 문서에 기록.

## 6. 앱 ↔ 키보드 이벤트 채널
### 포맷
```
KeyEvent { seq: UInt64(단조 증가), kind: char|space|enter|backspace|shift, value: String?, timestamp: Double }
```
### 쓰기 (메인 앱)
- App Group 컨테이너의 `events.log`에 한 줄씩 추가 (JSON Lines). 쓰기 후 Darwin 알림 발송.
- 파일이 너무 커지지 않게 오래된 줄은 주기적으로 잘라낸다.
### 읽기 (키보드 확장)
- Darwin 알림을 받으면 파일을 읽고 **`seq`가 마지막 처리 순번보다 큰 것만** 입력한다. 처리 후 마지막 순번을 저장.
- 오래된 이벤트(예: 3초 초과)는 입력하지 않고 건너뛴다. 키보드가 안 보이는 동안 쌓인 입력이 나중에 한꺼번에 쏟아지는 것을 막기 위함.
- 키보드가 처음 나타날 때는 현재 마지막 순번으로 맞추고 시작 (과거 이벤트 재생 금지).
- iOS는 앱마다 키보드 컨트롤러를 새로 만들 수 있으므로 **상태를 컨트롤러 인스턴스에 의존하지 않는다.** 알림 옵저버는 `viewWillAppear`/`viewDidDisappear`에서 등록/해제해 중복 등록을 막는다.
- Darwin 알림은 데이터를 실어 나르지 못하므로 "깨우기" 용도로만 쓰고, 데이터는 항상 파일에서 읽는다. 알림을 놓칠 경우를 대비해 키보드가 보이는 동안 짧은 주기 폴링을 보조로 둔다.
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

## 10. 테스트 전략
- 시뮬레이터에는 카메라가 없다. 인식은 **실제 iPad**에서 검증한다.
- 카메라 없이 테스트할 수 있게 인식 파이프라인 입력을 `CVPixelBuffer` 프레임 스트림으로 추상화하고, 저장된 샘플 이미지로 돌릴 수 있게 한다.
- 단위 테스트 필수 대상:
  - `CoordinateMapper`: 마커/키 중심 왕복 변환
  - `PressDetector`: 손끝 좌표 시퀀스를 넣어 "올려두기만 함 → 입력 0회", "한 번 누름 → 1회", "누른 채 유지 → 1회", "경계 떨림 → 오입력 없음" 검증
  - `EventChannel`: 순번 중복/역순/오래된 이벤트 처리
- 키보드 확장 디버깅: Xcode에서 확장 스킴을 선택하고 실행할 호스트 앱(예: 메모)을 지정하면 확장에 디버거를 붙일 수 있다.
