import Foundation
import PaperKeyboardPrinting
import PaperKeyboardShared
@testable import PaperKeyboardRecognition

/// 실기기 없이 마커 검출을 시험하기 위한 가짜 카메라 이미지.
/// 인쇄용 PDF와 같은 그리기 코드로 종이를 그리고, 정해 둔 네 모서리 위치로 원근 변환해 "찍은 것처럼" 만든다.
enum SyntheticCamera {
    static let layout = try! KeyboardLayout.bundledQWERTY()
    static let pixelsPerMillimeter = 3.0
    static let paperBitmap = PrintableLayoutRenderer(layout: layout).grayscaleBitmap(pixelsPerMillimeter: pixelsPerMillimeter)!

    struct Shot {
        let image: GrayImage
        /// 정답: 종이 mm → 카메라 픽셀.
        let paperToPixel: Homography

        func expectedPixel(_ point: PaperPoint) -> PixelPoint {
            let p = paperToPixel.map(SIMD2(point.x, point.y))!
            return PixelPoint(x: p.x, y: p.y)
        }
    }

    /// - paperCorners: 종이 네 모서리(왼쪽 위, 오른쪽 위, 오른쪽 아래, 왼쪽 아래)가 카메라 이미지에 보일 픽셀 위치.
    /// - lighting: 이미지 위치(0~1, 0~1)별 밝기 배율. 조명 불균일 흉내.
    /// - noise: 픽셀마다 ±noise 범위의 고정된 잡음.
    /// - editPaper: 원근 변환 전에 종이 그림을 고친다 (mm 사각형을 특정 밝기로 칠하기 등).
    static func shot(
        width: Int = 960,
        height: Int = 540,
        paperCorners: [SIMD2<Double>],
        background: Double = 90,
        lighting: (Double, Double) -> Double = { _, _ in 1 },
        noise: Int = 0,
        paint: [(rect: PaperRect, value: UInt8)] = []
    ) -> Shot {
        let paperSize = [SIMD2(0, 0), SIMD2(layout.paperWidth, 0), SIMD2(layout.paperWidth, layout.paperHeight), SIMD2(0, layout.paperHeight)]
        let paperToPixel = Homography(mapping: paperSize, to: paperCorners)!
        let pixelToPaper = paperToPixel.inverted()!

        var paper = paperBitmap.pixels
        let (pw, ph) = (paperBitmap.width, paperBitmap.height)
        let ppm = pixelsPerMillimeter
        for (rect, value) in paint {
            for y in max(0, Int(rect.minY * ppm))..<min(ph, Int(rect.maxY * ppm)) {
                for x in max(0, Int(rect.minX * ppm))..<min(pw, Int(rect.maxX * ppm)) {
                    paper[y * pw + x] = value
                }
            }
        }

        var random = UInt64(12345)
        var pixels = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                var value = background
                let mm = pixelToPaper.map(SIMD2(Double(x) + 0.5, Double(y) + 0.5))!
                if mm.x >= 0, mm.y >= 0, mm.x < layout.paperWidth, mm.y < layout.paperHeight {
                    value = bilinear(paper, pw, ph, mm.x * ppm - 0.5, mm.y * ppm - 0.5)
                }
                value *= lighting(Double(x) / Double(width), Double(y) / Double(height))
                if noise > 0 {
                    random = random &* 6364136223846793005 &+ 1442695040888963407
                    value += Double(Int(random >> 33) % (2 * noise + 1) - noise)
                }
                pixels[y * width + x] = UInt8(max(0, min(255, value.rounded())))
            }
        }
        return Shot(image: GrayImage(width: width, height: height, pixels: pixels)!, paperToPixel: paperToPixel)
    }

    private static func bilinear(_ p: [UInt8], _ w: Int, _ h: Int, _ u: Double, _ v: Double) -> Double {
        let x0 = max(0, min(w - 1, Int(floor(u)))), y0 = max(0, min(h - 1, Int(floor(v))))
        let x1 = min(w - 1, x0 + 1), y1 = min(h - 1, y0 + 1)
        let fx = max(0, min(1, u - Double(x0))), fy = max(0, min(1, v - Double(y0)))
        let top = Double(p[y0 * w + x0]) * (1 - fx) + Double(p[y0 * w + x1]) * fx
        let bottom = Double(p[y1 * w + x0]) * (1 - fx) + Double(p[y1 * w + x1]) * fx
        return top * (1 - fy) + bottom * fy
    }
}
