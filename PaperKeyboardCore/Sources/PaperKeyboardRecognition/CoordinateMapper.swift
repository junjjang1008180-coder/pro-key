import Foundation
import PaperKeyboardShared

// 좌표계가 섞이지 않도록 공간마다 타입을 따로 둔다.
// 키 판정 경로: Vision 정규화 → 카메라 픽셀 → (호모그래피) → 종이 mm.
// 마커와 손끝은 반드시 같은 이미지 공간(같은 orientation으로 Vision에 넘긴 이미지)에서 구해야 한다.

/// Vision 결과 좌표. 0~1 정규화, 원점은 이미지 **왼쪽 아래**, y는 위로 증가.
public struct NormalizedPoint: Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// 카메라 이미지 픽셀 좌표. 원점은 **왼쪽 위**, y는 아래로 증가. 미러링하지 않은 원본 기준.
public struct PixelPoint: Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct PixelSize: Equatable, Sendable {
    public var width: Double
    public var height: Double

    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

public enum CoordinateMapper {
    /// Vision 좌표 → 픽셀. y축을 뒤집는다.
    public static func pixel(fromVision point: NormalizedPoint, imageSize: PixelSize) -> PixelPoint {
        PixelPoint(x: point.x * imageSize.width, y: (1 - point.y) * imageSize.height)
    }

    public static func vision(fromPixel point: PixelPoint, imageSize: PixelSize) -> NormalizedPoint {
        NormalizedPoint(x: point.x / imageSize.width, y: 1 - point.y / imageSize.height)
    }

    /// Vision에 영상을 돌려서(`uprightRotation`도 시계 방향, 0/90/180/270) 넘겼을 때, 그 결과 좌표를 원본 버퍼 픽셀로.
    /// 맞은편 웹캠은 손이 거꾸로 찍히므로 180° 돌려 넘기면 Vision이 손을 더 잘 찾는다.
    /// `imageSize`는 돌리기 전 원본 버퍼 크기.
    public static func pixel(fromVision point: NormalizedPoint, imageSize: PixelSize, uprightRotation: Double) -> PixelPoint {
        let (w, h) = (imageSize.width, imageSize.height)
        let quarterTurns = Self.quarterTurns(uprightRotation)
        // 돌린 이미지(Vision이 본 이미지)의 크기와 그 안의 픽셀 좌표 (원점 왼쪽 위)
        let rotatedSize = quarterTurns.isMultiple(of: 2) ? (w, h) : (h, w)
        let (u, v) = (point.x * rotatedSize.0, (1 - point.y) * rotatedSize.1)
        // 원본을 시계 방향으로 돌린 것이 Vision 이미지이므로, 반대로 되돌린다.
        switch quarterTurns {
        case 1: return PixelPoint(x: v, y: h - u)        // 90°: 원본 (x, y) → (h − y, x)
        case 2: return PixelPoint(x: w - u, y: h - v)    // 180°
        case 3: return PixelPoint(x: w - v, y: u)        // 270°: 원본 (x, y) → (y, w − x)
        default: return PixelPoint(x: u, y: v)
        }
    }

    /// `pixel(fromVision:imageSize:uprightRotation:)`의 반대. 테스트와 디버그용.
    public static func vision(fromPixel point: PixelPoint, imageSize: PixelSize, uprightRotation: Double) -> NormalizedPoint {
        let (w, h) = (imageSize.width, imageSize.height)
        let quarterTurns = Self.quarterTurns(uprightRotation)
        let rotatedSize = quarterTurns.isMultiple(of: 2) ? (w, h) : (h, w)
        let (u, v): (Double, Double)
        switch quarterTurns {
        case 1: (u, v) = (h - point.y, point.x)
        case 2: (u, v) = (w - point.x, h - point.y)
        case 3: (u, v) = (point.y, w - point.x)
        default: (u, v) = (point.x, point.y)
        }
        return NormalizedPoint(x: u / rotatedSize.0, y: 1 - v / rotatedSize.1)
    }

    /// 0/90/180/270 → 0/1/2/3. 90의 배수가 아니면 가장 가까운 값.
    static func quarterTurns(_ degrees: Double) -> Int {
        ((Int((degrees / 90).rounded()) % 4) + 4) % 4
    }

    /// **화면 오버레이 전용.** 전면 카메라 프리뷰는 좌우 반전되어 보이므로 그릴 때만 뒤집는다.
    /// 키 판정에 이 값을 쓰면 엉뚱한 키가 눌린다.
    public static func mirroredForDisplay(_ point: PixelPoint, imageSize: PixelSize) -> PixelPoint {
        PixelPoint(x: imageSize.width - point.x, y: point.y)
    }
}

/// 카메라 픽셀 ↔ 종이 mm 변환.
/// 네 마커 중심의 픽셀 위치(검출값)와 레이아웃의 마커 중심(mm)을 짝지어 만든다.
public struct PaperMapping: Equatable, Sendable {
    public let pixelToPaper: Homography
    public let paperToPixel: Homography

    /// 마커가 한 직선 위에 몰려 있는 등 변환을 만들 수 없으면 nil.
    public init?(markerPixels: CornerQuad<PixelPoint>, markerPaper: CornerQuad<PaperPoint>) {
        let source = markerPixels.all.map { SIMD2($0.x, $0.y) }
        let destination = markerPaper.all.map { SIMD2($0.x, $0.y) }
        guard let forward = Homography(mapping: source, to: destination),
              let inverse = forward.inverted() else { return nil }
        self.pixelToPaper = forward
        self.paperToPixel = inverse
    }

    public func paper(fromPixel point: PixelPoint) -> PaperPoint? {
        pixelToPaper.map(SIMD2(point.x, point.y)).map { PaperPoint(x: $0.x, y: $0.y) }
    }

    public func pixel(fromPaper point: PaperPoint) -> PixelPoint? {
        paperToPixel.map(SIMD2(point.x, point.y)).map { PixelPoint(x: $0.x, y: $0.y) }
    }

    /// 종이 위 사각형(키 등)의 네 모서리를 카메라 픽셀로. 화면에 키 테두리를 겹쳐 그릴 때 쓴다.
    /// 순서는 왼쪽 위, 오른쪽 위, 오른쪽 아래, 왼쪽 아래. 하나라도 변환할 수 없으면 nil.
    public func pixelCorners(of rect: PaperRect) -> [PixelPoint]? {
        let corners = [
            PaperPoint(x: rect.minX, y: rect.minY), PaperPoint(x: rect.maxX, y: rect.minY),
            PaperPoint(x: rect.maxX, y: rect.maxY), PaperPoint(x: rect.minX, y: rect.maxY),
        ]
        let mapped = corners.compactMap(pixel(fromPaper:))
        return mapped.count == 4 ? mapped : nil
    }

    /// 화면에서 종이가 똑바로(종이 위쪽이 화면 위쪽) 보이려면 영상을 시계 방향으로 몇 도 돌려야 하는지.
    /// 0, 90, 180, 270 중 가장 가까운 값. 웹캠이 사용자 맞은편에 있으면 종이가 거꾸로 찍히므로 180이 나온다.
    /// 버퍼는 y가 아래로 커지므로, 시계 방향 θ 회전은 (x, y) → (x·cosθ − y·sinθ, x·sinθ + y·cosθ).
    public func uprightRotationDegrees(paperWidth: Double, paperHeight: Double) -> Double? {
        guard let top = pixel(fromPaper: PaperPoint(x: paperWidth / 2, y: 0)),
              let bottom = pixel(fromPaper: PaperPoint(x: paperWidth / 2, y: paperHeight)) else { return nil }
        // 버퍼에서 종이 "위쪽" 방향의 각도. 화면 위쪽은 -90°.
        let up = atan2(top.y - bottom.y, top.x - bottom.x) * 180 / .pi
        let snapped = ((-90 - up) / 90).rounded() * 90
        return (snapped.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
    }

    /// Vision 손끝 좌표를 바로 종이 좌표로. `imageSize`는 Vision에 넘긴 방향 기준 이미지 크기.
    public func paper(fromVision point: NormalizedPoint, imageSize: PixelSize) -> PaperPoint? {
        paper(fromPixel: CoordinateMapper.pixel(fromVision: point, imageSize: imageSize))
    }
}
