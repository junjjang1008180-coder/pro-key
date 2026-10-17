import CoreGraphics
import Foundation
import Testing
import PaperKeyboardPrinting
import PaperKeyboardShared
@testable import PaperKeyboardRecognition

struct MarkerDetectorTests {
    typealias Camera = SyntheticCamera
    static let layout = Camera.layout

    /// 카메라 이미지에서 종이 네 모서리가 보일 위치 (왼쪽 위, 오른쪽 위, 오른쪽 아래, 왼쪽 아래).
    static let nearlyFrontal = [SIMD2<Double>(150, 70), SIMD2(810, 80), SIMD2(800, 500), SIMD2(160, 480)]
    /// 책상 위 종이를 비스듬히 내려다본 모양: 먼 쪽(위)이 좁다.
    static let steepPerspective = [SIMD2<Double>(260, 60), SIMD2(700, 60), SIMD2(900, 500), SIMD2(60, 500)]
    /// 종이가 카메라에 거꾸로(180도) 비침: 종이 왼쪽 위가 이미지 오른쪽 아래에 보인다.
    static let upsideDown = [SIMD2<Double>(810, 480), SIMD2(150, 480), SIMD2(150, 60), SIMD2(810, 60)]

    // MARK: 인쇄 그림 자체

    @Test func 인쇄_그림의_마커와_구멍이_제자리에_있다() {
        let bitmap = Camera.paperBitmap
        let ppm = Camera.pixelsPerMillimeter
        func value(_ p: PaperPoint) -> UInt8 { bitmap.pixels[Int(p.y * ppm) * bitmap.width + Int(p.x * ppm)] }
        let markers = Self.layout.markerFrames
        // 구멍 난 왼쪽 위: 가운데는 흰색, 테두리는 검정
        #expect(value(markers.topLeft.center) > 200)
        #expect(value(PaperPoint(x: markers.topLeft.minX + 1, y: markers.topLeft.center.y)) < 50)
        // 나머지 셋은 가운데까지 검정
        for marker in [markers.topRight, markers.bottomRight, markers.bottomLeft] {
            #expect(value(marker.center) < 50)
        }
        // 종이 바탕은 흰색
        #expect(value(PaperPoint(x: 148, y: 180)) > 240)
    }

    @Test func PDF가_A4_가로_한_장으로_만들어진다() throws {
        let data = try #require(PrintableLayoutRenderer(layout: Self.layout).pdfData())
        let document = try #require(CGPDFDocument(CGDataProvider(data: data as CFData)!))
        #expect(document.numberOfPages == 1)
        let box = try #require(document.page(at: 1)?.getBoxRect(.mediaBox))
        let points = PrintableLayoutRenderer.pointsPerMillimeter
        #expect(abs(Double(box.width) - 297 * points) < 0.01)
        #expect(abs(Double(box.height) - 210 * points) < 0.01)
    }

    // MARK: 검출 성공

    @Test(arguments: [
        ("거의 정면", nearlyFrontal),
        ("비스듬한 원근", steepPerspective),
        ("거꾸로 놓인 종이", upsideDown),
    ])
    func 네_마커를_제자리에서_찾는다(name: String, corners: [SIMD2<Double>]) throws {
        let shot = Camera.shot(paperCorners: corners)
        let found = try #require(MarkerDetector(layout: Self.layout).detect(in: shot.image).markers, "\(name): 검출 실패")
        Self.expectClose(found, Self.layout.markerCenters.map(shot.expectedPixel), tolerance: 1.5, name)
    }

    @Test func 조명이_고르지_않고_잡음이_있어도_찾는다() throws {
        // 왼쪽은 밝고 오른쪽으로 갈수록 45% 어두워짐
        let shot = Camera.shot(paperCorners: Self.nearlyFrontal, lighting: { x, _ in 1 - 0.45 * x }, noise: 12)
        let found = try #require(MarkerDetector(layout: Self.layout).detect(in: shot.image).markers)
        Self.expectClose(found, Self.layout.markerCenters.map(shot.expectedPixel), tolerance: 1.5, "조명")
    }

    @Test func 앱에서_줄인_저해상도_이미지에서도_찾는다() throws {
        let corners = Self.steepPerspective.map { $0 * (2.0 / 3.0) }
        let shot = Camera.shot(width: 640, height: 360, paperCorners: corners)
        let found = try #require(MarkerDetector(layout: Self.layout).detect(in: shot.image).markers)
        Self.expectClose(found, Self.layout.markerCenters.map(shot.expectedPixel), tolerance: 1.5, "640×360")
    }

    @Test func 찾은_마커로_만든_변환으로_키를_정확히_가리킨다() throws {
        for corners in [Self.steepPerspective, Self.upsideDown] {
            let shot = Camera.shot(paperCorners: corners)
            let found = try #require(MarkerDetector(layout: Self.layout).detect(in: shot.image).markers)
            let mapping = try #require(PaperMapping(markerPixels: found, markerPaper: Self.layout.markerCenters))
            for id in ["q", "f", "m", "backspace", "space"] {
                let key = try #require(Self.layout.key(withID: id))
                // 카메라에서 키 가운데가 보이는 픽셀 → 다시 종이 좌표
                let paper = try #require(mapping.paper(fromPixel: shot.expectedPixel(key.frame.center)))
                #expect(paper.distance(to: key.frame.center) < 1, "\(id): \(paper.distance(to: key.frame.center))mm 어긋남")
                #expect(Self.layout.key(at: paper, inset: 1.5)?.id == id)
            }
        }
    }

    // MARK: 검출 실패와 이유

    @Test func 손이_마커를_가리면_틀린_위치를_내놓지_않는다() {
        // 오른쪽 아래 모서리 부근을 피부색(밝은 회색)으로 덮음
        let hand = PaperRect(x: 250, y: 160, width: 47, height: 50)
        let shot = Camera.shot(paperCorners: Self.nearlyFrontal, paint: [(hand, 175)])
        let detection = MarkerDetector(layout: Self.layout).detect(in: shot.image)
        #expect(detection.markers == nil)
        #expect(detection.result == .failure(.notEnoughMarkers(found: 3)))
    }

    @Test func 마커가_반쯤_가려져도_틀린_위치를_내놓지_않는다() {
        // 왼쪽 아래 마커의 오른쪽 절반을 손가락이 덮음. 찾지 못하는 것은 괜찮지만, 찾았다면 정확해야 한다.
        let bottomLeft = Self.layout.markerFrames.bottomLeft
        let finger = PaperRect(x: bottomLeft.center.x, y: bottomLeft.minY - 5, width: 40, height: 30)
        let shot = Camera.shot(paperCorners: Self.nearlyFrontal, paint: [(finger, 175)])
        if let found = MarkerDetector(layout: Self.layout).detect(in: shot.image).markers {
            Self.expectClose(found, Self.layout.markerCenters.map(shot.expectedPixel), tolerance: 1.5, "반쯤 가림")
        }
    }

    @Test func 구멍_난_마커가_없으면_방향을_모른다고_알린다() {
        let filledHole = Self.layout.orientationHoleFrame
        let shot = Camera.shot(paperCorners: Self.nearlyFrontal, paint: [(filledHole, 0)])
        let detection = MarkerDetector(layout: Self.layout).detect(in: shot.image)
        #expect(detection.result == .failure(.orientationMarkerNotFound))
    }

    @Test func 종이가_없으면_찾지_못한다() {
        let blank = GrayImage(width: 320, height: 180, pixels: [UInt8](repeating: 128, count: 320 * 180))!
        #expect(MarkerDetector(layout: Self.layout).detect(in: blank).result == .failure(.notEnoughMarkers(found: 0)))
    }

    // MARK: 모서리 순서

    @Test func 볼록하지_않은_네_점은_모서리로_인정하지_않는다() {
        // 한 점이 나머지 셋이 만든 삼각형 안쪽에 있음
        let ring = PixelPoint(x: 0, y: 0)
        let others = [PixelPoint(x: 100, y: 0), PixelPoint(x: 50, y: 100), PixelPoint(x: 50, y: 30)]
        #expect(MarkerDetector.clockwiseCorners(ring: ring, others: others) == nil)
    }

    // MARK: 도우미

    static func expectClose(_ found: CornerQuad<PixelPoint>, _ expected: CornerQuad<PixelPoint>, tolerance: Double, _ name: String) {
        for (index, (f, e)) in zip(found.all, expected.all).enumerated() {
            let error = hypot(f.x - e.x, f.y - e.y)
            #expect(error < tolerance, "\(name): 모서리 \(index) 오차 \(error)px (찾음 \(f), 정답 \(e))")
        }
    }
}
