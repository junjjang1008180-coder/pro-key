import Foundation
import PaperKeyboardShared

/// 흑백 이미지. 행 우선, 위쪽 행부터, 0 = 검정.
/// 앱에서는 카메라 버퍼의 밝기(Y) 평면을 **미러링하지 않은 채** 담는다 (좌우가 뒤집히면 모서리 순서가 바뀐다).
public struct GrayImage: Sendable {
    public let width: Int
    public let height: Int
    public let pixels: [UInt8]

    public init?(width: Int, height: Int, pixels: [UInt8]) {
        guard width > 0, height > 0, pixels.count == width * height else { return nil }
        self.width = width
        self.height = height
        self.pixels = pixels
    }

    public var size: PixelSize { PixelSize(width: Double(width), height: Double(height)) }
}

/// 종이 네 모서리의 검은 마커를 찾는다.
/// 1. 주변보다 어두운 픽셀을 고른다 (조명이 고르지 않아도 되도록 주변 평균과 비교).
/// 2. 이어진 덩어리로 묶고, 크기·모양·채움 비율로 마커 후보만 남긴다.
/// 3. 가운데가 비어 있는 후보(구멍 난 왼쪽 위 마커) 하나 + 꽉 찬 후보 셋으로 볼록 사각형을 만든다.
///    구멍 난 마커부터 시계 방향으로 왼쪽 위 → 오른쪽 위 → 오른쪽 아래 → 왼쪽 아래.
/// 4. 그 네 점으로 만든 변환으로 레이아웃의 마커 자리를 이미지에 되돌려 보고,
///    정말 검은 마커와 흰 종이가 있는지 확인한다. 통과한 것 중 가장 큰 조합을 고른다.
public struct MarkerDetector: Sendable {
    public enum Failure: Error, Equatable, Sendable {
        /// 마커로 보이는 덩어리가 부족함 (손이나 화면 밖으로 가려짐).
        case notEnoughMarkers(found: Int)
        /// 구멍 난 왼쪽 위 마커가 없음 → 종이 방향을 알 수 없음.
        case orientationMarkerNotFound
        /// 후보는 있지만 네 개가 종이 모서리 모양(볼록 사각형)을 이루지 않음.
        case noConsistentQuad
    }

    /// 마커 후보. 디버그 화면에 그릴 때도 쓴다.
    public struct Candidate: Equatable, Sendable {
        public let center: PixelPoint
        public let area: Int
        public let hasHole: Bool
    }

    public struct Detection: Sendable {
        public let candidates: [Candidate]
        public let result: Result<CornerQuad<PixelPoint>, Failure>

        public var markers: CornerQuad<PixelPoint>? { try? result.get() }
    }

    public let layout: KeyboardLayout
    public let settings: RecognitionSettings

    public init(layout: KeyboardLayout, settings: RecognitionSettings = RecognitionSettings()) {
        self.layout = layout
        self.settings = settings
    }

    public func detect(in image: GrayImage) -> Detection {
        let dark = DarkMask(image: image, settings: settings)
        let candidates = findCandidates(in: dark)
        return Detection(candidates: candidates, result: chooseCorners(from: candidates, dark: dark))
    }

    // MARK: - 1·2. 후보 찾기

    private func findCandidates(in dark: DarkMask) -> [Candidate] {
        let (w, h) = (dark.width, dark.height)
        var visited = [Bool](repeating: false, count: w * h)
        var stack: [Int] = []
        var candidates: [Candidate] = []

        let shortSide = Double(min(w, h))
        let minSide = shortSide * settings.markerMinSizeFraction
        let maxSide = shortSide * settings.markerMaxSizeFraction

        for start in 0..<(w * h) where dark.pixels[start] && !visited[start] {
            var blob = Blob()
            visited[start] = true
            stack.append(start)
            while let index = stack.popLast() {
                let x = index % w, y = index / w
                blob.add(x: x, y: y, width: w, height: h)
                for ny in max(0, y - 1)...min(h - 1, y + 1) {
                    for nx in max(0, x - 1)...min(w - 1, x + 1) {
                        let neighbor = ny * w + nx
                        if dark.pixels[neighbor] && !visited[neighbor] {
                            visited[neighbor] = true
                            stack.append(neighbor)
                        }
                    }
                }
            }

            // 화면 가장자리에 걸린 덩어리는 잘린 모양이라 중심을 믿을 수 없다.
            guard !blob.touchesBorder else { continue }
            let (boxW, boxH) = (Double(blob.maxX - blob.minX + 1), Double(blob.maxY - blob.minY + 1))
            guard min(boxW, boxH) >= minSide, max(boxW, boxH) <= maxSide,
                  max(boxW, boxH) / min(boxW, boxH) <= settings.markerMaxAspectRatio,
                  Double(blob.count) / (boxW * boxH) >= settings.markerMinFillRatio else { continue }

            let center = PixelPoint(
                x: Double(blob.sumX) / Double(blob.count) + 0.5,
                y: Double(blob.sumY) / Double(blob.count) + 0.5
            )
            candidates.append(Candidate(center: center, area: blob.count, hasHole: hasHole(at: center, dark: dark)))
        }
        return candidates
    }

    /// 덩어리 중심 3×3이 대부분 밝으면 구멍 난 마커로 본다.
    private func hasHole(at center: PixelPoint, dark: DarkMask) -> Bool {
        let (cx, cy) = (Int(center.x), Int(center.y))
        var light = 0
        for y in (cy - 1)...(cy + 1) {
            for x in (cx - 1)...(cx + 1) where dark.isDark(x: x, y: y) == false {
                light += 1
            }
        }
        return light >= 7
    }

    // MARK: - 3·4. 네 모서리 고르기

    private func chooseCorners(from candidates: [Candidate], dark: DarkMask) -> Result<CornerQuad<PixelPoint>, Failure> {
        // 큰 것부터 몇 개만 조합해 본다 (글자 등 작은 덩어리는 대부분 여기서 빠진다).
        let rings = candidates.filter(\.hasHole).sorted { $0.area > $1.area }.prefix(3)
        let solids = Array(candidates.filter { !$0.hasHole }.sorted { $0.area > $1.area }.prefix(6))

        var best: (score: Int, corners: CornerQuad<PixelPoint>)?
        for ring in rings {
            for i in 0..<solids.count {
                for j in (i + 1)..<solids.count {
                    for k in (j + 1)..<solids.count {
                        let group = [ring, solids[i], solids[j], solids[k]]
                        let areas = group.map(\.area)
                        guard Double(areas.max()!) / Double(areas.min()!) <= settings.markerMaxAreaRatio,
                              let corners = Self.clockwiseCorners(ring: ring.center, others: [solids[i].center, solids[j].center, solids[k].center]),
                              looksLikePaper(corners, dark: dark)
                        else { continue }
                        let score = areas.reduce(0, +)
                        if score > best?.score ?? -1 { best = (score, corners) }
                    }
                }
            }
        }
        guard let best else { return .failure(failureReason(for: candidates)) }
        return .success(best.corners)
    }

    /// 네 점이 정말 이 레이아웃의 종이인지 확인한다. 변환으로 마커 자리를 이미지에 되돌려 보고
    /// 마커 안쪽(구멍 난 마커는 테두리 띠)은 검고, 마커 바로 바깥과 구멍은 흰지 본다.
    private func looksLikePaper(_ corners: CornerQuad<PixelPoint>, dark: DarkMask) -> Bool {
        guard let mapping = PaperMapping(markerPixels: corners, markerPaper: layout.markerCenters) else { return false }
        var darkHits = 0, darkTotal = 0, lightHits = 0, lightTotal = 0

        func check(_ point: PaperPoint, shouldBeDark: Bool) {
            // 이미지 밖으로 나가는 지점은 틀린 것으로 센다 (마커 전체가 보여야 함).
            let pixel = mapping.pixel(fromPaper: point)
            let isDark = pixel.flatMap { dark.isDark(x: Int($0.x), y: Int($0.y)) }
            if shouldBeDark {
                darkTotal += 1
                if isDark == true { darkHits += 1 }
            } else {
                lightTotal += 1
                if isDark == false { lightHits += 1 }
            }
        }

        let markers = layout.markerFrames
        let fractions = [0.2, 0.35, 0.5, 0.65, 0.8]
        for frame in [markers.topRight, markers.bottomRight, markers.bottomLeft] {
            for fx in fractions {
                for fy in fractions {
                    check(PaperPoint(x: frame.minX + frame.width * fx, y: frame.minY + frame.height * fy), shouldBeDark: true)
                }
            }
        }

        // 구멍 난 마커: 구멍과 바깥 테두리 사이 띠의 한가운데를 따라 16곳, 구멍 가운데는 흰색.
        let ring = markers.topLeft
        let bandHalf = (ring.width / 2 + layout.orientationHoleFrame.width / 2) / 2
        for step in stride(from: -1.0, to: 1.0, by: 0.5) {
            check(PaperPoint(x: ring.center.x + bandHalf * step, y: ring.center.y - bandHalf), shouldBeDark: true)
            check(PaperPoint(x: ring.center.x + bandHalf, y: ring.center.y + bandHalf * step), shouldBeDark: true)
            check(PaperPoint(x: ring.center.x - bandHalf * step, y: ring.center.y + bandHalf), shouldBeDark: true)
            check(PaperPoint(x: ring.center.x - bandHalf, y: ring.center.y - bandHalf * step), shouldBeDark: true)
        }
        check(layout.orientationHoleFrame.center, shouldBeDark: false)

        // 모든 마커의 네 변 바로 바깥은 흰 종이.
        for frame in markers.all {
            let offset = frame.width / 2 + frame.width * settings.markerVerifyMarginFraction
            let c = frame.center
            for (dx, dy) in [(-offset, 0.0), (offset, 0), (0, -offset), (0, offset)] {
                check(PaperPoint(x: c.x + dx, y: c.y + dy), shouldBeDark: false)
            }
        }

        let required = settings.markerVerifyMinRatio
        return Double(darkHits) >= Double(darkTotal) * required && Double(lightHits) >= Double(lightTotal) * required
    }

    /// 실패 이유를 화면 안내용으로 고른다. 크기가 서로 비슷한 후보 무리 중 면적 합이 가장 큰 것
    /// (= 마커일 법한 무리, 작은 글자 덩어리들은 제외)을 기준으로 판단한다.
    private func failureReason(for candidates: [Candidate]) -> Failure {
        var largestGroup: [Candidate] = []
        var largestTotal = 0
        for reference in candidates {
            let group = candidates.filter {
                $0.area <= reference.area && Double(reference.area) / Double($0.area) <= settings.markerMaxAreaRatio
            }
            let total = group.reduce(0) { $0 + $1.area }
            if total > largestTotal { (largestGroup, largestTotal) = (group, total) }
        }
        if largestGroup.count < 4 { return .notEnoughMarkers(found: largestGroup.count) }
        if !largestGroup.contains(where: \.hasHole) { return .orientationMarkerNotFound }
        return .noConsistentQuad
    }

    /// 네 점을 중심 기준 각도로 정렬해 구멍 난 마커부터 시계 방향으로 놓는다. 볼록 사각형이 아니면 nil.
    /// 이미지 좌표는 y가 아래로 커지므로 atan2 각도가 커지는 방향이 화면상 시계 방향이다.
    static func clockwiseCorners(ring: PixelPoint, others: [PixelPoint]) -> CornerQuad<PixelPoint>? {
        let points = [ring] + others
        let cx = points.map(\.x).reduce(0, +) / 4
        let cy = points.map(\.y).reduce(0, +) / 4
        var sorted = points.sorted { atan2($0.y - cy, $0.x - cx) < atan2($1.y - cy, $1.x - cx) }
        let ringIndex = sorted.firstIndex(of: ring)!
        sorted = Array(sorted[ringIndex...] + sorted[..<ringIndex])

        for i in 0..<4 {
            let (a, b, c) = (sorted[i], sorted[(i + 1) % 4], sorted[(i + 2) % 4])
            let cross = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
            guard cross > 0 else { return nil }
        }
        return CornerQuad(topLeft: sorted[0], topRight: sorted[1], bottomRight: sorted[2], bottomLeft: sorted[3])
    }
}

/// 주변 평균보다 `markerThresholdOffset` 이상 어두운 픽셀 표시. 적분 이미지로 창 평균을 빠르게 구한다.
private struct DarkMask {
    let width: Int
    let height: Int
    let pixels: [Bool]

    init(image: GrayImage, settings: RecognitionSettings) {
        let (w, h) = (image.width, image.height)
        let stride = w + 1
        var integral = [Int](repeating: 0, count: stride * (h + 1))
        for y in 0..<h {
            var rowSum = 0
            for x in 0..<w {
                rowSum += Int(image.pixels[y * w + x])
                integral[(y + 1) * stride + x + 1] = integral[y * stride + x + 1] + rowSum
            }
        }

        let radius = max(2, Int(Double(min(w, h)) * settings.markerThresholdWindowFraction / 2))
        let factor = 1 - settings.markerThresholdOffset
        var mask = [Bool](repeating: false, count: w * h)
        for y in 0..<h {
            let (y0, y1) = (max(0, y - radius), min(h, y + radius + 1))
            for x in 0..<w {
                let (x0, x1) = (max(0, x - radius), min(w, x + radius + 1))
                let sum = integral[y1 * stride + x1] - integral[y0 * stride + x1] - integral[y1 * stride + x0] + integral[y0 * stride + x0]
                let count = (y1 - y0) * (x1 - x0)
                // 픽셀 < 평균 × factor  ⇔  픽셀 × 개수 < 합 × factor (나눗셈 없이 비교)
                mask[y * w + x] = Double(image.pixels[y * w + x]) * Double(count) < Double(sum) * factor
            }
        }
        (self.width, self.height, self.pixels) = (w, h, mask)
    }

    /// 이미지 밖이면 nil.
    func isDark(x: Int, y: Int) -> Bool? {
        guard x >= 0, y >= 0, x < width, y < height else { return nil }
        return pixels[y * width + x]
    }
}

/// 이어진 검은 픽셀 덩어리 하나의 통계.
private struct Blob {
    var count = 0
    var sumX = 0
    var sumY = 0
    var minX = Int.max, maxX = Int.min
    var minY = Int.max, maxY = Int.min
    var touchesBorder = false

    mutating func add(x: Int, y: Int, width: Int, height: Int) {
        count += 1
        sumX += x
        sumY += y
        minX = min(minX, x); maxX = max(maxX, x)
        minY = min(minY, y); maxY = max(maxY, y)
        if x == 0 || y == 0 || x == width - 1 || y == height - 1 { touchesBorder = true }
    }
}
