import CoreGraphics
import CoreText
import Foundation
import PaperKeyboardShared

/// 레이아웃 정의 하나로 인쇄용 PDF를 만든다. 인식 쪽과 같은 `KeyboardLayout` 값을 쓰므로
/// 인쇄물과 인식 좌표가 어긋나지 않는다. 테스트용 흑백 비트맵도 같은 그리기 코드로 만든다.
public struct PrintableLayoutRenderer: Sendable {
    public static let pointsPerMillimeter = 72.0 / 25.4

    public let layout: KeyboardLayout

    public init(layout: KeyboardLayout) {
        self.layout = layout
    }

    /// 종이 한 장짜리 PDF. 페이지 크기는 레이아웃의 종이 크기 그대로 (A4 가로면 297×210mm).
    public func pdfData() -> Data? {
        let scale = Self.pointsPerMillimeter
        var mediaBox = CGRect(x: 0, y: 0, width: layout.paperWidth * scale, height: layout.paperHeight * scale)
        let data = NSMutableData()
        guard let consumer = CGDataConsumer(data: data as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { return nil }
        context.beginPDFPage(nil)
        draw(in: context, pointsPerMillimeter: scale)
        context.endPDFPage()
        context.closePDF()
        return data as Data
    }

    /// 흑백 비트맵 (행 우선, 위쪽 행부터, 0 = 검정). 실기기 없이 마커 검출을 시험할 때 쓴다.
    public func grayscaleBitmap(pixelsPerMillimeter: Double) -> (width: Int, height: Int, pixels: [UInt8])? {
        let width = Int((layout.paperWidth * pixelsPerMillimeter).rounded())
        let height = Int((layout.paperHeight * pixelsPerMillimeter).rounded())
        guard let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        draw(in: context, pointsPerMillimeter: pixelsPerMillimeter)
        guard let buffer = context.data else { return nil }
        // 비트맵 메모리는 위쪽 행부터 저장된다.
        let pixels = Array(UnsafeBufferPointer(start: buffer.assumingMemoryBound(to: UInt8.self), count: width * height))
        return (width, height, pixels)
    }

    /// 컨텍스트에 종이를 그린다. 내부에서는 mm 단위, 원점 왼쪽 위, y 아래쪽 좌표로 바꿔서 그린다.
    public func draw(in context: CGContext, pointsPerMillimeter scale: Double) {
        context.saveGState()
        defer { context.restoreGState() }

        // CoreGraphics 기본 좌표(원점 왼쪽 아래)를 레이아웃 좌표(원점 왼쪽 위, mm)로 뒤집는다.
        context.translateBy(x: 0, y: layout.paperHeight * scale)
        context.scaleBy(x: scale, y: -scale)

        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: layout.paperWidth, height: layout.paperHeight))

        drawMarkers(in: context)
        drawKeys(in: context)
        drawCaption(in: context)
    }

    // MARK: - 그리기 부품

    private func drawMarkers(in context: CGContext) {
        context.setFillColor(gray: 0, alpha: 1)
        for frame in layout.markerFrames.all {
            context.fill(frame.cgRect)
        }
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(layout.orientationHoleFrame.cgRect)
    }

    private func drawKeys(in context: CGContext) {
        // 테두리는 옅고 얇게: 카메라에서 마커와 헷갈리지 않고 손끝을 가리지 않게 한다.
        context.setStrokeColor(gray: 0.6, alpha: 1)
        context.setLineWidth(0.35)
        for key in layout.keys {
            let path = CGPath(roundedRect: key.frame.cgRect, cornerWidth: 2, cornerHeight: 2, transform: nil)
            context.addPath(path)
            context.strokePath()
            drawLabels(of: key, in: context)
        }
    }

    /// 실제 키보드처럼: 글자 키는 영문 크게 왼쪽 + 한글 자모 오른쪽(Shift 자모는 위),
    /// 숫자·기호 키는 Shift 글자 위 + 기본 글자 아래, 특수키는 가운데 한 줄.
    private func drawLabels(of key: KeyboardLayout.Key, in context: CGContext) {
        let f = key.frame
        if let korean = key.koreanValue {
            drawText(key.label, centeredAt: PaperPoint(x: f.minX + 4.5, y: f.minY + 5.5), fontSize: 6, gray: 0.2, in: context)
            drawText(korean, centeredAt: PaperPoint(x: f.maxX - 4, y: f.maxY - 4), fontSize: 4.2, gray: 0.35, in: context)
            if let shifted = key.koreanShiftValue, shifted != korean {
                drawText(shifted, centeredAt: PaperPoint(x: f.maxX - 4, y: f.minY + 4.5), fontSize: 3.4, gray: 0.35, in: context)
            }
        } else if key.kind == .char, let shifted = key.shiftValue, shifted != key.value?.uppercased() {
            drawText(shifted, centeredAt: PaperPoint(x: f.center.x, y: f.minY + 5), fontSize: 4.2, gray: 0.3, in: context)
            drawText(key.label, centeredAt: PaperPoint(x: f.center.x, y: f.maxY - 5), fontSize: 5, gray: 0.2, in: context)
        } else if !key.label.isEmpty {
            let size = key.kind == .char ? 5.5 : 3.6
            drawText(key.label, centeredAt: f.center, fontSize: size, gray: 0.25, in: context)
        }
    }

    private func drawCaption(in context: CGContext) {
        let top = layout.markerCenters.topLeft.y
        drawText(
            "종이 키보드 · \(layout.name) · 실제 크기(100%)로 인쇄 · 구멍 난 마커가 왼쪽 위",
            centeredAt: PaperPoint(x: layout.paperWidth / 2, y: top),
            fontSize: 3.5, gray: 0.45, in: context
        )
    }

    /// 글자 하나 줄을 가운데 맞춰 그린다. 기호(⌫ 등)는 CoreText가 맞는 글꼴로 대체한다.
    private func drawText(_ text: String, centeredAt center: PaperPoint, fontSize: Double, gray: Double, in context: CGContext) {
        let font = CTFontCreateUIFontForLanguage(.system, fontSize, nil)
            ?? CTFontCreateWithName("Helvetica" as CFString, fontSize, nil)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): CGColor(gray: gray, alpha: 1),
        ]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let bounds = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)

        context.saveGState()
        // 위에서 y축을 뒤집었으므로 글자가 거꾸로 서지 않게 텍스트 행렬을 다시 뒤집는다.
        context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
        context.textPosition = CGPoint(x: center.x - bounds.midX, y: center.y + bounds.midY)
        CTLineDraw(line, context)
        context.restoreGState()
    }
}

extension PaperRect {
    var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}
