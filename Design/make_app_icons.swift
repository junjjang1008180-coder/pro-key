import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

// 앱 아이콘 시안 3개 (1024×1024, 불투명) + 나란히 놓은 미리보기.
let size = 1024.0
let outDir = CommandLine.arguments[1]

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func makeContext(width: Int, height: Int) -> CGContext {
    CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
}

func gradient(_ ctx: CGContext, _ top: UInt32, _ bottom: UInt32, from: CGPoint, to: CGPoint) {
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [color(top), color(bottom)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(g, start: from, end: to, options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}

func text(_ ctx: CGContext, _ string: String, font: String, size: CGFloat, color c: CGColor, center: CGPoint) {
    let f = CTFontCreateWithName(font as CFString, size, nil)
    let attr = NSAttributedString(string: string, attributes: [
        NSAttributedString.Key(kCTFontAttributeName as String): f,
        NSAttributedString.Key(kCTForegroundColorAttributeName as String): c,
    ])
    let line = CTLineCreateWithAttributedString(attr)
    let b = CTLineGetBoundsWithOptions(line, .useGlyphPathBounds)
    ctx.textPosition = CGPoint(x: center.x - b.midX, y: center.y - b.midY)
    CTLineDraw(line, ctx)
}

func roundedRect(_ rect: CGRect, _ r: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
}

/// 종이 키보드: 흰 종이 + 모서리 마커(왼쪽 위만 구멍) + 키 몇 줄. 원점 중심 기준으로 그린다.
func drawPaper(_ ctx: CGContext, width w: CGFloat, height h: CGFloat, accent: CGColor, highlightLabel: String) {
    let paper = CGRect(x: -w / 2, y: -h / 2, width: w, height: h)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 40, color: color(0x000000, 0.35))
    ctx.setFillColor(color(0xFFFFFF))
    ctx.addPath(roundedRect(paper, 26))
    ctx.fillPath()
    ctx.restoreGState()

    // 마커: 왼쪽 위(이미지 좌표상 위 = y가 큰 쪽)만 구멍
    let m: CGFloat = 0.115 * w, inset: CGFloat = 0.055 * w
    let corners = [
        CGPoint(x: paper.minX + inset, y: paper.maxY - inset - m),   // 왼쪽 위
        CGPoint(x: paper.maxX - inset - m, y: paper.maxY - inset - m),
        CGPoint(x: paper.maxX - inset - m, y: paper.minY + inset),
        CGPoint(x: paper.minX + inset, y: paper.minY + inset),
    ]
    for (i, p) in corners.enumerated() {
        ctx.setFillColor(color(0x15161C))
        ctx.fill(CGRect(origin: p, size: CGSize(width: m, height: m)))
        if i == 0 {
            ctx.setFillColor(color(0xFFFFFF))
            let hole = m * 0.46
            ctx.fill(CGRect(x: p.x + (m - hole) / 2, y: p.y + (m - hole) / 2, width: hole, height: hole))
        }
    }

    // 키 3줄 × 5칸, 가운데 줄 가운데 키를 강조
    let cols = 5, rows = 3
    let pitch = w * 0.112, key = pitch * 0.84
    let gridW = pitch * CGFloat(cols), gridH = pitch * CGFloat(rows)
    for r in 0..<rows {
        for c in 0..<cols {
            let stagger = r == 1 ? pitch * 0.25 : (r == 2 ? pitch * 0.5 : 0)
            let x = -gridW / 2 + CGFloat(c) * pitch + (pitch - key) / 2 + stagger - pitch * 0.25
            let y = gridH / 2 - CGFloat(r + 1) * pitch + (pitch - key) / 2 - h * 0.02
            let rect = CGRect(x: x, y: y, width: key, height: key)
            if r == 1 && c == 2 {
                ctx.setFillColor(accent)
                ctx.addPath(roundedRect(rect, key * 0.2))
                ctx.fillPath()
                text(ctx, highlightLabel, font: "AppleSDGothicNeo-Bold", size: key * 0.62, color: color(0xFFFFFF), center: CGPoint(x: rect.midX, y: rect.midY))
            } else {
                ctx.setStrokeColor(color(0xC9CEDA))
                ctx.setLineWidth(5)
                ctx.addPath(roundedRect(rect.insetBy(dx: 2.5, dy: 2.5), key * 0.2))
                ctx.strokePath()
            }
        }
    }
}

func save(_ image: CGImage, _ name: String) {
    let url = URL(fileURLWithPath: outDir).appendingPathComponent(name)
    let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
}

var icons: [CGImage] = []

// 시안 1: 파란 배경 + 살짝 기운 종이 키보드, 가운데 키 "가"
do {
    let ctx = makeContext(width: Int(size), height: Int(size))
    gradient(ctx, 0x4D8BFF, 0x6A3DF0, from: CGPoint(x: 0, y: size), to: CGPoint(x: size, y: 0))
    ctx.translateBy(x: size / 2, y: size / 2 - 10)
    ctx.rotate(by: 8 * .pi / 180)
    drawPaper(ctx, width: 700, height: 495, accent: color(0x5A5CFF), highlightLabel: "가")
    icons.append(ctx.makeImage()!)
}

// 시안 2: 남색 배경 + 큰 키캡 하나 (A / 가), 모서리에 작은 마커
do {
    let ctx = makeContext(width: Int(size), height: Int(size))
    gradient(ctx, 0x2B3270, 0x141833, from: CGPoint(x: 0, y: size), to: CGPoint(x: 0, y: 0))
    let cap = CGRect(x: 222, y: 230, width: 580, height: 580)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -26), blur: 50, color: color(0x000000, 0.5))
    ctx.setFillColor(color(0xF4F6FB))
    ctx.addPath(roundedRect(cap, 120))
    ctx.fillPath()
    ctx.restoreGState()
    // 키캡 윗면 살짝 들어간 느낌
    ctx.setFillColor(color(0xFFFFFF))
    ctx.addPath(roundedRect(cap.insetBy(dx: 40, dy: 40).offsetBy(dx: 0, dy: 18), 90))
    ctx.fillPath()
    text(ctx, "A", font: "AvenirNext-Bold", size: 250, color: color(0x1E2348), center: CGPoint(x: cap.minX + 205, y: cap.maxY - 215))
    text(ctx, "가", font: "AppleSDGothicNeo-Bold", size: 170, color: color(0x5A5CFF), center: CGPoint(x: cap.maxX - 170, y: cap.minY + 175))
    // 종이 마커 4개 (왼쪽 위만 구멍)
    let m: CGFloat = 70, e: CGFloat = 92
    for (i, p) in [CGPoint(x: e, y: size - e - m), CGPoint(x: size - e - m, y: size - e - m), CGPoint(x: size - e - m, y: e), CGPoint(x: e, y: e)].enumerated() {
        ctx.setFillColor(color(0xFFFFFF, 0.9))
        ctx.fill(CGRect(origin: p, size: CGSize(width: m, height: m)))
        if i == 0 {
            ctx.setFillColor(color(0x272D66))
            ctx.fill(CGRect(x: p.x + 19, y: p.y + 19, width: 32, height: 32))
        }
    }
    icons.append(ctx.makeImage()!)
}

// 시안 3: 주황~분홍 배경 + 종이 키보드, 강조 키를 누르는 동그라미 물결
do {
    let ctx = makeContext(width: Int(size), height: Int(size))
    gradient(ctx, 0xFFB35C, 0xFF5E8A, from: CGPoint(x: 0, y: size), to: CGPoint(x: size, y: 0))
    ctx.translateBy(x: size / 2, y: size / 2 - 20)
    drawPaper(ctx, width: 740, height: 523, accent: color(0xFF6A5C), highlightLabel: "A")
    // 누르는 손끝 자리: 물결 동그라미
    let pitch = 740 * 0.112
    let center = CGPoint(x: pitch * 0.25, y: 523 * 0.0 - 523 * 0.02 + pitch * 0.0)
    for (radius, alpha) in [(150.0, 0.18), (110.0, 0.28)] {
        ctx.setStrokeColor(color(0xFF6A5C, alpha))
        ctx.setLineWidth(12)
        ctx.addEllipse(in: CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
        ctx.strokePath()
    }
    icons.append(ctx.makeImage()!)
}

for (i, icon) in icons.enumerated() { save(icon, "icon\(i + 1).png") }

// 미리보기: iOS처럼 둥근 모서리로 잘라 나란히, 아래에 번호
let tile = 360.0, gap = 60.0, label = 80.0
let preview = makeContext(width: Int(tile * 3 + gap * 4), height: Int(tile + gap * 2 + label))
preview.setFillColor(color(0xF2F2F7))
preview.fill(CGRect(x: 0, y: 0, width: tile * 3 + gap * 4, height: tile + gap * 2 + label))
for (i, icon) in icons.enumerated() {
    let rect = CGRect(x: gap + Double(i) * (tile + gap), y: gap + label, width: tile, height: tile)
    preview.saveGState()
    preview.addPath(roundedRect(rect, tile * 0.225))
    preview.clip()
    preview.draw(icon, in: rect)
    preview.restoreGState()
    text(preview, "시안 \(i + 1)", font: "AppleSDGothicNeo-Bold", size: 40, color: color(0x333333), center: CGPoint(x: rect.midX, y: gap + label / 2 - 10))
}
save(preview.makeImage()!, "preview.png")
print("ok")
