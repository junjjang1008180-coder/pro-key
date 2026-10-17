import Foundation
import Testing
import PaperKeyboardShared
@testable import PaperKeyboardRecognition

struct GrayImageCameraTests {
    @Test func 밝기_평면을_칸_평균으로_줄이고_줄_끝_여백은_건너뛴다() throws {
        // 6×4 이미지, 한 줄 8바이트(끝 2바이트는 버퍼 여백 = 255로 채워 섞이면 티가 나게)
        let width = 6, height = 4, bytesPerRow = 8
        var bytes = [UInt8](repeating: 255, count: bytesPerRow * height)
        for y in 0..<height {
            for x in 0..<width { bytes[y * bytesPerRow + x] = UInt8(x * 10 + y) }
        }
        let image = try #require(bytes.withUnsafeBytes {
            GrayImage(luma: $0, width: width, height: height, bytesPerRow: bytesPerRow, step: 2)
        })
        #expect(image.width == 3 && image.height == 2)
        // 왼쪽 위 2×2: 0, 10, 1, 11 → 평균 5
        #expect(image.pixels[0] == 5)
        // 오른쪽 아래 2×2: x 4~5, y 2~3 → 42, 52, 43, 53 → 47
        #expect(image.pixels[5] == 47)
    }

    @Test func BGRA는_밝기로_바꾼다() throws {
        // 2×1: 흰색, 순수 빨강 (B, G, R, A 순서)
        let bytes: [UInt8] = [255, 255, 255, 255, 0, 0, 255, 255]
        let image = try #require(bytes.withUnsafeBytes {
            GrayImage(bgra: $0, width: 2, height: 1, bytesPerRow: 8, step: 1)
        })
        #expect(image.pixels[0] == 255)
        #expect(image.pixels[1] == 76)   // 77 × 255 >> 8
    }

    @Test func 버퍼가_모자라면_만들지_않는다() {
        let bytes = [UInt8](repeating: 0, count: 10)
        let image = bytes.withUnsafeBytes { GrayImage(luma: $0, width: 6, height: 4, bytesPerRow: 8, step: 2) }
        #expect(image == nil)
    }

    @Test func 키_사각형_네_모서리를_카메라_픽셀로_옮긴다() throws {
        let paper = CornerQuad(
            topLeft: PaperPoint(x: 0, y: 0), topRight: PaperPoint(x: 100, y: 0),
            bottomRight: PaperPoint(x: 100, y: 50), bottomLeft: PaperPoint(x: 0, y: 50)
        )
        // 종이 1mm = 2픽셀, (10, 20)만큼 이동한 단순 변환
        let pixels = paper.map { PixelPoint(x: $0.x * 2 + 10, y: $0.y * 2 + 20) }
        let mapping = try #require(PaperMapping(markerPixels: pixels, markerPaper: paper))
        let corners = try #require(mapping.pixelCorners(of: PaperRect(x: 5, y: 5, width: 10, height: 4)))
        let expected = [(20.0, 30.0), (40.0, 30.0), (40.0, 38.0), (20.0, 38.0)]
        for (corner, (x, y)) in zip(corners, expected) {
            #expect(abs(corner.x - x) < 1e-9 && abs(corner.y - y) < 1e-9)
        }
    }

    @Test(arguments: [
        // 종이 네 모서리(왼쪽 위, 오른쪽 위, 오른쪽 아래, 왼쪽 아래)가 버퍼에 찍힌 위치 → 돌려야 할 각도
        ([(100.0, 100.0), (397.0, 100.0), (397.0, 310.0), (100.0, 310.0)], 0.0),    // 똑바로
        ([(397.0, 310.0), (100.0, 310.0), (100.0, 100.0), (397.0, 100.0)], 180.0),  // 맞은편 웹캠: 거꾸로
        ([(310.0, 100.0), (310.0, 397.0), (100.0, 397.0), (100.0, 100.0)], 270.0),  // 종이 위쪽이 버퍼 오른쪽
        ([(100.0, 397.0), (100.0, 100.0), (310.0, 100.0), (310.0, 397.0)], 90.0),   // 종이 위쪽이 버퍼 왼쪽
        ([(110.0, 90.0), (400.0, 120.0), (390.0, 320.0), (95.0, 300.0)], 0.0),      // 조금 기울어도 가까운 쪽
    ])
    func 종이가_똑바로_보이도록_돌릴_각도(corners: [(Double, Double)], expected: Double) throws {
        let paper = CornerQuad(
            topLeft: PaperPoint(x: 0, y: 0), topRight: PaperPoint(x: 297, y: 0),
            bottomRight: PaperPoint(x: 297, y: 210), bottomLeft: PaperPoint(x: 0, y: 210)
        )
        let p = corners.map { PixelPoint(x: $0.0, y: $0.1) }
        let pixels = CornerQuad(topLeft: p[0], topRight: p[1], bottomRight: p[2], bottomLeft: p[3])
        let mapping = try #require(PaperMapping(markerPixels: pixels, markerPaper: paper))
        #expect(mapping.uprightRotationDegrees(paperWidth: 297, paperHeight: 210) == expected)
    }

    @Test func 영상의_위쪽이_종이에서_어느_방향인지() throws {
        let paper = CornerQuad(
            topLeft: PaperPoint(x: 0, y: 0), topRight: PaperPoint(x: 297, y: 0),
            bottomRight: PaperPoint(x: 297, y: 210), bottomLeft: PaperPoint(x: 0, y: 210)
        )
        func mapping(_ corners: [(Double, Double)]) throws -> PaperMapping {
            let p = corners.map { PixelPoint(x: $0.0, y: $0.1) }
            return try #require(PaperMapping(markerPixels: CornerQuad(topLeft: p[0], topRight: p[1], bottomRight: p[2], bottomLeft: p[3]), markerPaper: paper))
        }
        let up = (x: 0.0, y: -1.0)
        // 똑바로 찍힘: 영상 위쪽 = 종이 위쪽(-y)
        let upright = try mapping([(100, 100), (397, 100), (397, 310), (100, 310)])
        let a = try #require(upright.paperDirection(at: PixelPoint(x: 250, y: 200), pixelDirection: up))
        #expect(abs(a.x) < 1e-9 && abs(a.y + 1) < 1e-9)
        // 맞은편 웹캠: 종이가 거꾸로 찍힘 → 영상 위쪽 = 종이 아래쪽(+y, 사용자 쪽). 손끝을 들면 +y로 움직인다.
        let opposite = try mapping([(397, 310), (100, 310), (100, 100), (397, 100)])
        let b = try #require(opposite.paperDirection(at: PixelPoint(x: 250, y: 200), pixelDirection: up))
        #expect(abs(b.x) < 1e-9 && abs(b.y - 1) < 1e-9)
    }
}
