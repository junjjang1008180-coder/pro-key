import Foundation
import Testing
import PaperKeyboardShared
@testable import PaperKeyboardRecognition

struct CoordinateMapperTests {
    static let imageSize = PixelSize(width: 1920, height: 1080)
    /// 비스듬히 놓인 종이를 찍었을 때 마커 중심이 보이는 위치 (사다리꼴).
    static let markerPixels = CornerQuad(
        topLeft: PixelPoint(x: 420, y: 310),
        topRight: PixelPoint(x: 1500, y: 290),
        bottomRight: PixelPoint(x: 1780, y: 1010),
        bottomLeft: PixelPoint(x: 160, y: 1050)
    )

    // MARK: Vision ↔ 픽셀

    @Test func Vision은_원점이_왼쪽_아래라_y를_뒤집는다() {
        let size = Self.imageSize
        #expect(CoordinateMapper.pixel(fromVision: NormalizedPoint(x: 0, y: 0), imageSize: size) == PixelPoint(x: 0, y: 1080))
        #expect(CoordinateMapper.pixel(fromVision: NormalizedPoint(x: 0, y: 1), imageSize: size) == PixelPoint(x: 0, y: 0))
        #expect(CoordinateMapper.pixel(fromVision: NormalizedPoint(x: 0.25, y: 0.75), imageSize: size) == PixelPoint(x: 480, y: 270))
    }

    @Test func Vision_픽셀_왕복() {
        let original = NormalizedPoint(x: 0.3125, y: 0.8)
        let pixel = CoordinateMapper.pixel(fromVision: original, imageSize: Self.imageSize)
        let back = CoordinateMapper.vision(fromPixel: pixel, imageSize: Self.imageSize)
        #expect(abs(back.x - original.x) < 1e-12)
        #expect(abs(back.y - original.y) < 1e-12)
    }

    @Test func 돌리지_않으면_기존_변환과_같다() {
        let point = NormalizedPoint(x: 0.25, y: 0.75)
        #expect(CoordinateMapper.pixel(fromVision: point, imageSize: Self.imageSize, uprightRotation: 0)
            == CoordinateMapper.pixel(fromVision: point, imageSize: Self.imageSize))
    }

    /// 원본 버퍼의 왼쪽 위 모서리(0, 0)가 돌린 이미지(Vision 좌표, 원점 왼쪽 아래)에서 어디로 가는지.
    @Test(arguments: [
        (90.0, NormalizedPoint(x: 1, y: 1)),    // 시계 방향 90°: 왼쪽 위 → 오른쪽 위
        (180.0, NormalizedPoint(x: 1, y: 0)),   // 180°: 왼쪽 위 → 오른쪽 아래
        (270.0, NormalizedPoint(x: 0, y: 0)),   // 270°: 왼쪽 위 → 왼쪽 아래
    ])
    func 돌린_이미지의_모서리가_원본_왼쪽_위로_돌아온다(rotation: Double, cornerInVision: NormalizedPoint) {
        let pixel = CoordinateMapper.pixel(fromVision: cornerInVision, imageSize: Self.imageSize, uprightRotation: rotation)
        #expect(abs(pixel.x) < 1e-9 && abs(pixel.y) < 1e-9, "\(rotation)°: \(pixel)")
    }

    @Test(arguments: [0.0, 90.0, 180.0, 270.0])
    func 돌린_Vision_좌표와_원본_픽셀_왕복(rotation: Double) {
        for original in [PixelPoint(x: 300, y: 200), PixelPoint(x: 1919, y: 5), PixelPoint(x: 960, y: 1079)] {
            let vision = CoordinateMapper.vision(fromPixel: original, imageSize: Self.imageSize, uprightRotation: rotation)
            #expect((0...1).contains(vision.x) && (0...1).contains(vision.y), "\(rotation)°: 범위 밖 \(vision)")
            let back = CoordinateMapper.pixel(fromVision: vision, imageSize: Self.imageSize, uprightRotation: rotation)
            #expect(abs(back.x - original.x) < 1e-9 && abs(back.y - original.y) < 1e-9, "\(rotation)°: \(original) → \(back)")
        }
    }

    @Test func 맞은편_웹캠처럼_180도_돌리면_화면_가운데_아래가_원본_가운데_위() {
        // 돌린 이미지(사용자 시점)의 아래쪽 가운데 = 사용자 쪽 = 원본 버퍼의 위쪽 가운데
        let pixel = CoordinateMapper.pixel(fromVision: NormalizedPoint(x: 0.5, y: 0), imageSize: Self.imageSize, uprightRotation: 180)
        #expect(pixel == PixelPoint(x: 960, y: 0))
    }

    @Test func 화면용_미러링은_x만_뒤집고_두_번_하면_원래대로() {
        let point = PixelPoint(x: 300, y: 200)
        let mirrored = CoordinateMapper.mirroredForDisplay(point, imageSize: Self.imageSize)
        #expect(mirrored == PixelPoint(x: 1620, y: 200))
        #expect(CoordinateMapper.mirroredForDisplay(mirrored, imageSize: Self.imageSize) == point)
    }

    // MARK: 호모그래피

    @Test func 같은_네_점이면_항등_변환() throws {
        let points = [SIMD2<Double>(10, 20), SIMD2(300, 25), SIMD2(310, 400), SIMD2(5, 390)]
        let h = try #require(Homography(mapping: points, to: points))
        let mapped = try #require(h.map(SIMD2(123, 234)))
        #expect(Self.close(mapped, SIMD2(123, 234)))
    }

    @Test func 단순_확대도_정확히_계산한다() throws {
        let square = [SIMD2<Double>(0, 0), SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1)]
        let doubled = square.map { $0 * 2 + SIMD2(5, 7) }
        let h = try #require(Homography(mapping: square, to: doubled))
        #expect(Self.close(try #require(h.map(SIMD2(0.5, 0.25))), SIMD2(6, 7.5)))
    }

    @Test func 세_점이_한_직선이면_만들지_않는다() {
        let collinear = [SIMD2<Double>(0, 0), SIMD2(1, 1), SIMD2(2, 2), SIMD2(0, 5)]
        let square = [SIMD2<Double>(0, 0), SIMD2(1, 0), SIMD2(1, 1), SIMD2(0, 1)]
        #expect(Homography(mapping: collinear, to: square) == nil)
        #expect(Homography(mapping: square, to: collinear) == nil)
    }

    @Test func 역변환을_곱하면_항등() throws {
        let layout = try KeyboardLayout.bundledQWERTY()
        let mapping = try #require(PaperMapping(markerPixels: Self.markerPixels, markerPaper: layout.markerCenters))
        let product = mapping.paperToPixel.multiplied(by: mapping.pixelToPaper)
        let scale = product.matrix[8]
        for (value, expected) in zip(product.matrix.map { $0 / scale }, Homography.identity.matrix) {
            #expect(abs(value - expected) < 1e-9)
        }
    }

    // MARK: 픽셀 ↔ 종이 (실제 레이아웃)

    @Test func 마커_픽셀은_레이아웃의_마커_중심으로_간다() throws {
        let layout = try KeyboardLayout.bundledQWERTY()
        let mapping = try #require(PaperMapping(markerPixels: Self.markerPixels, markerPaper: layout.markerCenters))
        for (pixel, paper) in zip(Self.markerPixels.all, layout.markerCenters.all) {
            let mapped = try #require(mapping.paper(fromPixel: pixel))
            #expect(mapped.distance(to: paper) < 1e-6)
        }
    }

    @Test func 모든_키_중심이_왕복_변환된다() throws {
        let layout = try KeyboardLayout.bundledQWERTY()
        let mapping = try #require(PaperMapping(markerPixels: Self.markerPixels, markerPaper: layout.markerCenters))
        for key in layout.keys {
            let pixel = try #require(mapping.pixel(fromPaper: key.frame.center))
            #expect(pixel.x > 0 && pixel.x < Self.imageSize.width && pixel.y > 0 && pixel.y < Self.imageSize.height)
            let back = try #require(mapping.paper(fromPixel: pixel))
            #expect(back.distance(to: key.frame.center) < 1e-6, "\(key.id) 왕복 오차")
        }
    }

    @Test func Vision_손끝_좌표로_올바른_키를_찾는다() throws {
        let layout = try KeyboardLayout.bundledQWERTY()
        let mapping = try #require(PaperMapping(markerPixels: Self.markerPixels, markerPaper: layout.markerCenters))
        for id in ["q", "p", "a", "l", "z", "space", "enter"] {
            let key = try #require(layout.key(withID: id))
            let pixel = try #require(mapping.pixel(fromPaper: key.frame.center))
            let vision = CoordinateMapper.vision(fromPixel: pixel, imageSize: Self.imageSize)
            let paper = try #require(mapping.paper(fromVision: vision, imageSize: Self.imageSize))
            #expect(layout.key(at: paper)?.id == id)
        }
    }

    /// 회귀 방지: 화면용(미러링) 좌표를 판정에 넣으면 다른 키가 나온다는 것을 고정해 둔다.
    @Test func 미러링된_좌표로_판정하면_틀린_키가_나온다() throws {
        let layout = try KeyboardLayout.bundledQWERTY()
        let mapping = try #require(PaperMapping(markerPixels: Self.markerPixels, markerPaper: layout.markerCenters))
        let q = try #require(layout.key(withID: "q"))
        let pixel = try #require(mapping.pixel(fromPaper: q.frame.center))
        let mirrored = CoordinateMapper.mirroredForDisplay(pixel, imageSize: Self.imageSize)
        let wrong = mapping.paper(fromPixel: mirrored).flatMap { layout.key(at: $0) }
        #expect(wrong?.id != "q")
    }

    static func close(_ a: SIMD2<Double>, _ b: SIMD2<Double>, tolerance: Double = 1e-9) -> Bool {
        abs(a.x - b.x) < tolerance && abs(a.y - b.y) < tolerance
    }
}
