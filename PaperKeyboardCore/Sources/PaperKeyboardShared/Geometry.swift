import Foundation

/// 종이 위의 점. 단위 mm, 원점은 종이 왼쪽 위, x는 오른쪽, y는 아래쪽으로 증가한다.
public struct PaperPoint: Equatable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public func distance(to other: PaperPoint) -> Double {
        hypot(x - other.x, y - other.y)
    }
}

/// 종이 위의 사각형 (mm).
public struct PaperRect: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public var minX: Double { x }
    public var minY: Double { y }
    public var maxX: Double { x + width }
    public var maxY: Double { y + height }
    public var center: PaperPoint { PaperPoint(x: x + width / 2, y: y + height / 2) }

    /// 경계 포함.
    public func contains(_ point: PaperPoint) -> Bool {
        point.x >= minX && point.x <= maxX && point.y >= minY && point.y <= maxY
    }

    /// 양수면 안쪽으로 줄이고, 음수면 바깥으로 넓힌다.
    public func insetBy(_ amount: Double) -> PaperRect {
        PaperRect(x: x + amount, y: y + amount, width: width - amount * 2, height: height - amount * 2)
    }

    /// 면적이 겹칠 때만 true (변이 맞닿는 것은 겹침이 아님).
    public func overlaps(_ other: PaperRect) -> Bool {
        minX < other.maxX && other.minX < maxX && minY < other.maxY && other.minY < maxY
    }
}

/// 종이 네 모서리마다 하나씩 있는 값 (마커 위치 등).
public struct CornerQuad<Point> {
    public var topLeft: Point
    public var topRight: Point
    public var bottomRight: Point
    public var bottomLeft: Point

    public init(topLeft: Point, topRight: Point, bottomRight: Point, bottomLeft: Point) {
        self.topLeft = topLeft
        self.topRight = topRight
        self.bottomRight = bottomRight
        self.bottomLeft = bottomLeft
    }

    /// 시계 방향: 왼쪽 위, 오른쪽 위, 오른쪽 아래, 왼쪽 아래.
    public var all: [Point] { [topLeft, topRight, bottomRight, bottomLeft] }

    public func map<T>(_ transform: (Point) throws -> T) rethrows -> CornerQuad<T> {
        CornerQuad<T>(
            topLeft: try transform(topLeft),
            topRight: try transform(topRight),
            bottomRight: try transform(bottomRight),
            bottomLeft: try transform(bottomLeft)
        )
    }
}

extension CornerQuad: Sendable where Point: Sendable {}
extension CornerQuad: Equatable where Point: Equatable {}
