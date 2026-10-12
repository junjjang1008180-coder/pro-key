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

    /// Vision 손끝 좌표를 바로 종이 좌표로. `imageSize`는 Vision에 넘긴 방향 기준 이미지 크기.
    public func paper(fromVision point: NormalizedPoint, imageSize: PixelSize) -> PaperPoint? {
        paper(fromPixel: CoordinateMapper.pixel(fromVision: point, imageSize: imageSize))
    }
}
