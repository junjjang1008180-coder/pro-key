import Foundation

/// 종이 키보드 레이아웃. `layout_qwerty.json` 하나에서 만들어지며,
/// 인쇄용 PDF와 인식 시 키 영역 계산이 모두 이 값을 쓴다. 좌표를 코드에 따로 적지 말 것.
public struct KeyboardLayout: Sendable {
    public struct Key: Equatable, Sendable {
        /// 글자 키는 글자 자체, 특수키는 종류 이름 (`space`, `enter` 등). 같은 종류가 둘이면 JSON의 `id`.
        public let id: String
        /// 종이에 인쇄할 글자.
        public let label: String
        public let kind: KeyKind
        /// 영어 모드 기본 글자.
        public let value: String?
        /// 영어 모드에서 Shift를 눌렀을 때 글자. 영문자는 대문자.
        public let shiftValue: String?
        /// 한글 모드 자모 (두벌식). 한글 자리가 없는 키(숫자·기호)는 nil이고, 한글 모드에서도 영어 값을 쓴다.
        public let koreanValue: String?
        /// 한글 모드에서 Shift를 눌렀을 때 자모 (ㅃ 등). 없으면 `koreanValue`.
        public let koreanShiftValue: String?
        public let frame: PaperRect
    }

    public let name: String
    public let paperWidth: Double
    public let paperHeight: Double
    /// 모서리 마커 영역 (검은 정사각형).
    public let markerFrames: CornerQuad<PaperRect>
    /// 왼쪽 위 마커 가운데의 흰 구멍. 네 마커 중 이것만 모양이 달라 종이 방향(어느 쪽이 위인지)을 구분한다.
    public let orientationHoleFrame: PaperRect
    public let keys: [Key]

    /// 원근 보정 기준점: 마커 중심 (mm).
    public var markerCenters: CornerQuad<PaperPoint> { markerFrames.map(\.center) }

    public func key(withID id: String) -> Key? {
        keys.first { $0.id == id }
    }

    /// 점이 들어 있는 키. `inset`이 양수면 키 안쪽 영역만 인정한다 (경계 떨림 방지용).
    public func key(at point: PaperPoint, inset: Double = 0) -> Key? {
        keys.first { $0.frame.insetBy(inset).contains(point) }
    }
}

// MARK: - 정의 파일 읽기

extension KeyboardLayout {
    public enum LayoutError: LocalizedError, Equatable {
        case unsupportedVersion(Int)
        case invalidDimensions(String)
        case invalidKey(String)
        case duplicateKeyID(String)
        case keyOutsidePaper(String)
        case keysOverlap(String, String)
        case keyOverlapsMarker(String)
        case resourceMissing

        public var errorDescription: String? {
            switch self {
            case .unsupportedVersion(let version): "지원하지 않는 레이아웃 버전: \(version)"
            case .invalidDimensions(let detail): "레이아웃 크기 값이 잘못됨: \(detail)"
            case .invalidKey(let detail): "키 정의가 잘못됨: \(detail)"
            case .duplicateKeyID(let id): "키 ID 중복: \(id)"
            case .keyOutsidePaper(let id): "키가 종이 밖으로 나감: \(id)"
            case .keysOverlap(let a, let b): "키가 서로 겹침: \(a), \(b)"
            case .keyOverlapsMarker(let id): "키가 모서리 마커와 겹침: \(id)"
            case .resourceMissing: "레이아웃 파일을 찾을 수 없음"
            }
        }
    }

    static let supportedVersion = 1

    /// 패키지에 들어 있는 기본 QWERTY 레이아웃.
    public static func bundledQWERTY() throws -> KeyboardLayout {
        guard let url = Bundle.module.url(forResource: "layout_qwerty", withExtension: "json") else {
            throw LayoutError.resourceMissing
        }
        return try KeyboardLayout(jsonData: Data(contentsOf: url))
    }

    public init(jsonData: Data) throws {
        let definition = try JSONDecoder().decode(Definition.self, from: jsonData)
        try self.init(definition: definition)
    }

    private init(definition d: Definition) throws {
        guard d.version == Self.supportedVersion else { throw LayoutError.unsupportedVersion(d.version) }
        guard d.paper.width > 0, d.paper.height > 0 else { throw LayoutError.invalidDimensions("paper") }
        guard d.markers.size > 0, d.markers.inset >= 0 else { throw LayoutError.invalidDimensions("markers") }
        // 구멍 둘레의 검은 테두리가 너무 얇으면 카메라에서 끊겨 보이므로 한쪽 2mm 이상 남긴다.
        guard d.markers.holeSize > 0, d.markers.holeSize <= d.markers.size - 4 else {
            throw LayoutError.invalidDimensions("markers.holeSize")
        }
        guard d.keyPitch > 0, d.keySize > 0, d.keySize <= d.keyPitch else {
            throw LayoutError.invalidDimensions("keyPitch/keySize")
        }

        let (w, h, s, m) = (d.paper.width, d.paper.height, d.markers.size, d.markers.inset)
        let markers = CornerQuad(
            topLeft: PaperRect(x: m, y: m, width: s, height: s),
            topRight: PaperRect(x: w - m - s, y: m, width: s, height: s),
            bottomRight: PaperRect(x: w - m - s, y: h - m - s, width: s, height: s),
            bottomLeft: PaperRect(x: m, y: h - m - s, width: s, height: s)
        )

        let hole = d.markers.holeSize
        let holeFrame = PaperRect(x: m + (s - hole) / 2, y: m + (s - hole) / 2, width: hole, height: hole)

        // 키 칸(cell) 하나는 pitch 크기, 실제 키는 그 안에서 gap/2씩 띄운다.
        let gap = d.keyPitch - d.keySize
        var keys: [Key] = []
        for row in d.rows {
            var cellX = row.x
            for spec in row.keys {
                let units = spec.units ?? 1
                guard units > 0 else { throw LayoutError.invalidKey("units는 0보다 커야 함") }
                let key = try Self.makeKey(
                    spec: spec,
                    frame: PaperRect(x: cellX + gap / 2, y: row.y + gap / 2, width: units * d.keyPitch - gap, height: d.keySize)
                )
                keys.append(key)
                cellX += units * d.keyPitch
            }
        }

        let paper = PaperRect(x: 0, y: 0, width: w, height: h)
        var seen = Set<String>()
        for (index, key) in keys.enumerated() {
            guard seen.insert(key.id).inserted else { throw LayoutError.duplicateKeyID(key.id) }
            guard paper.contains(PaperPoint(x: key.frame.minX, y: key.frame.minY)),
                  paper.contains(PaperPoint(x: key.frame.maxX, y: key.frame.maxY)) else {
                throw LayoutError.keyOutsidePaper(key.id)
            }
            if markers.all.contains(where: { $0.overlaps(key.frame) }) {
                throw LayoutError.keyOverlapsMarker(key.id)
            }
            for other in keys[(index + 1)...] where other.frame.overlaps(key.frame) {
                throw LayoutError.keysOverlap(key.id, other.id)
            }
        }

        self.name = d.name
        self.paperWidth = w
        self.paperHeight = h
        self.markerFrames = markers
        self.orientationHoleFrame = holeFrame
        self.keys = keys
    }

    private static func makeKey(spec: Definition.KeySpec, frame: PaperRect) throws -> Key {
        let kind = spec.kind ?? .char
        switch kind {
        case .char:
            guard let value = spec.value, value.count == 1 else {
                throw LayoutError.invalidKey("글자 키 value는 한 글자여야 함: \(spec.value ?? "없음")")
            }
            let isLetter = value.lowercased() != value.uppercased()
            let shiftValue = spec.shift ?? (isLetter ? value.uppercased() : nil)
            guard shiftValue.map({ $0.count == 1 }) ?? true else {
                throw LayoutError.invalidKey("\(value): shift는 한 글자여야 함")
            }
            for jamo in [spec.ko, spec.koShift].compactMap({ $0 }) where !HangulComposer.isJamo(jamo) {
                throw LayoutError.invalidKey("\(value): 한글 값은 자모 한 글자여야 함 (\(jamo))")
            }
            guard spec.koShift == nil || spec.ko != nil else {
                throw LayoutError.invalidKey("\(value): koShift만 있고 ko가 없음")
            }
            return Key(
                id: spec.id ?? value, label: spec.label ?? value.uppercased(), kind: .char,
                value: value, shiftValue: shiftValue, koreanValue: spec.ko, koreanShiftValue: spec.koShift, frame: frame
            )
        default:
            return Key(
                id: spec.id ?? kind.rawValue, label: spec.label ?? defaultLabel(kind), kind: kind,
                value: nil, shiftValue: nil, koreanValue: nil, koreanShiftValue: nil, frame: frame
            )
        }
    }

    private static func defaultLabel(_ kind: KeyKind) -> String {
        switch kind {
        case .char: ""
        case .space: ""
        case .enter: "Enter ⏎"
        case .backspace: "⌫ Backspace"
        case .tab: "Tab ⇥"
        case .cursorLeft: "←"
        case .cursorRight: "→"
        case .shift: "⇧ Shift"
        case .capsLock: "Caps Lock"
        case .languageToggle: "한/영"
        }
    }

    /// JSON 파일 구조. 단위는 모두 mm.
    struct Definition: Decodable {
        struct Paper: Decodable { let width: Double; let height: Double }
        /// size: 마커 한 변, inset: 종이 가장자리에서 마커까지 거리, holeSize: 왼쪽 위 마커의 흰 구멍 한 변.
        struct Markers: Decodable { let size: Double; let inset: Double; let holeSize: Double }
        /// x, y: 행의 첫 칸 왼쪽 위.
        struct Row: Decodable { let x: Double; let y: Double; let keys: [KeySpec] }
        /// kind 생략 시 글자 키. units: 키 폭 배수 (기본 1).
        /// shift: Shift 글자 (영문자는 생략하면 대문자), ko/koShift: 두벌식 자모, id: 같은 종류 특수키가 둘일 때 구분용.
        struct KeySpec: Decodable {
            let kind: KeyKind?
            let id: String?
            let value: String?
            let shift: String?
            let ko: String?
            let koShift: String?
            let label: String?
            let units: Double?
        }

        let name: String
        let version: Int
        let paper: Paper
        let markers: Markers
        let keyPitch: Double
        let keySize: Double
        let rows: [Row]
    }
}
