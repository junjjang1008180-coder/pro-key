import Foundation

/// 호모그래피: 한 평면의 점을 다른 평면으로 옮기는 3x3 원근 변환 행렬.
/// 비스듬히 찍힌 종이(사다리꼴)를 반듯한 종이 좌표(직사각형)로 펴는 데 쓴다.
public struct Homography: Equatable, Sendable {
    /// 행 우선 3x3 (9개 값).
    public let matrix: [Double]

    public init(matrix: [Double]) {
        precondition(matrix.count == 9, "호모그래피 행렬은 값 9개")
        self.matrix = matrix
    }

    public static let identity = Homography(matrix: [1, 0, 0, 0, 1, 0, 0, 0, 1])

    /// 대응점 4쌍으로 계산한다. 세 점이 한 직선 위에 있으면 nil.
    public init?(mapping source: [SIMD2<Double>], to destination: [SIMD2<Double>]) {
        guard source.count == 4, destination.count == 4 else { return nil }

        // 숫자 크기를 맞춰(정규화) 계산 오차를 줄인다: 중심을 원점으로, 평균 거리를 √2로.
        guard case let (src, srcT)? = Self.normalize(source),
              case let (dst, dstT)? = Self.normalize(destination),
              !Self.hasCollinearTriple(src), !Self.hasCollinearTriple(dst) else { return nil }

        // h33 = 1로 두고 8개 미지수 연립방정식을 푼다.
        var a: [[Double]] = []
        var b: [Double] = []
        for (p, q) in zip(src, dst) {
            a.append([p.x, p.y, 1, 0, 0, 0, -q.x * p.x, -q.x * p.y])
            b.append(q.x)
            a.append([0, 0, 0, p.x, p.y, 1, -q.y * p.x, -q.y * p.y])
            b.append(q.y)
        }
        guard let h = Self.solve(a, b) else { return nil }

        let normalized = Homography(matrix: h + [1])
        guard let dstInverse = dstT.inverted() else { return nil }
        let combined = dstInverse.multiplied(by: normalized).multiplied(by: srcT)
        guard let scaled = combined.scaledToUnitCorner(), scaled.matrix.allSatisfy(\.isFinite) else { return nil }
        self = scaled
    }

    /// 점 변환. 무한대로 보내는 점(지평선 위)이면 nil.
    public func map(_ point: SIMD2<Double>) -> SIMD2<Double>? {
        let m = matrix
        let w = m[6] * point.x + m[7] * point.y + m[8]
        guard abs(w) > 1e-12 else { return nil }
        return SIMD2(
            (m[0] * point.x + m[1] * point.y + m[2]) / w,
            (m[3] * point.x + m[4] * point.y + m[5]) / w
        )
    }

    public func inverted() -> Homography? {
        let m = matrix
        let c00 = m[4] * m[8] - m[5] * m[7]
        let c01 = m[5] * m[6] - m[3] * m[8]
        let c02 = m[3] * m[7] - m[4] * m[6]
        let det = m[0] * c00 + m[1] * c01 + m[2] * c02
        guard det.isFinite, abs(det) > 1e-15 else { return nil }
        let adjugate = [
            c00, m[2] * m[7] - m[1] * m[8], m[1] * m[5] - m[2] * m[4],
            c01, m[0] * m[8] - m[2] * m[6], m[2] * m[3] - m[0] * m[5],
            c02, m[1] * m[6] - m[0] * m[7], m[0] * m[4] - m[1] * m[3],
        ]
        return Homography(matrix: adjugate.map { $0 / det }).scaledToUnitCorner()
    }

    /// self ∘ other (other를 먼저 적용).
    public func multiplied(by other: Homography) -> Homography {
        let a = matrix, b = other.matrix
        var result = [Double](repeating: 0, count: 9)
        for row in 0..<3 {
            for col in 0..<3 {
                result[row * 3 + col] = (0..<3).reduce(0) { $0 + a[row * 3 + $1] * b[$1 * 3 + col] }
            }
        }
        return Homography(matrix: result)
    }

    // MARK: - 내부 계산

    /// 같은 변환을 h33 = 1인 형태로. h33이 0에 가까우면 그대로 둔다.
    private func scaledToUnitCorner() -> Homography? {
        let corner = matrix[8]
        guard abs(corner) > 1e-12 else { return self }
        return Homography(matrix: matrix.map { $0 / corner })
    }

    private static func normalize(_ points: [SIMD2<Double>]) -> ([SIMD2<Double>], Homography)? {
        let centroid = points.reduce(SIMD2<Double>(0, 0), +) / Double(points.count)
        let meanDistance = points.map { hypot($0.x - centroid.x, $0.y - centroid.y) }.reduce(0, +) / Double(points.count)
        guard meanDistance > 1e-12 else { return nil }
        let s = 2.0.squareRoot() / meanDistance
        let transform = Homography(matrix: [s, 0, -s * centroid.x, 0, s, -s * centroid.y, 0, 0, 1])
        return (points.map { ($0 - centroid) * s }, transform)
    }

    /// 정규화된 점 기준. 네 점 중 어느 세 점이라도 거의 한 직선이면 true.
    private static func hasCollinearTriple(_ p: [SIMD2<Double>]) -> Bool {
        for (i, j, k) in [(0, 1, 2), (0, 1, 3), (0, 2, 3), (1, 2, 3)] {
            let u = p[j] - p[i], v = p[k] - p[i]
            if abs(u.x * v.y - u.y * v.x) < 1e-6 { return true }
        }
        return false
    }

    /// 부분 피벗 가우스 소거. 특이 행렬이면 nil.
    private static func solve(_ matrix: [[Double]], _ vector: [Double]) -> [Double]? {
        var a = matrix, b = vector
        let n = b.count
        for col in 0..<n {
            let pivot = (col..<n).max { abs(a[$0][col]) < abs(a[$1][col]) }!
            guard abs(a[pivot][col]) > 1e-10 else { return nil }
            a.swapAt(col, pivot)
            b.swapAt(col, pivot)
            for row in (col + 1)..<n {
                let factor = a[row][col] / a[col][col]
                guard factor != 0 else { continue }
                for k in col..<n { a[row][k] -= factor * a[col][k] }
                b[row] -= factor * b[col]
            }
        }
        var x = [Double](repeating: 0, count: n)
        for row in stride(from: n - 1, through: 0, by: -1) {
            let sum = ((row + 1)..<n).reduce(0) { $0 + a[row][$1] * x[$1] }
            x[row] = (b[row] - sum) / a[row][row]
        }
        return x
    }
}
