import Foundation

/// 카메라 버퍼 → 마커 검출용 작은 흑백 이미지.
/// `step`×`step` 칸의 평균 밝기를 한 픽셀로 만든다 (예: 1920×1080, step 3 → 640×360).
/// 줄인 이미지의 픽셀 i는 원본 [i·step, (i+1)·step) 범위이므로, 검출 좌표에 step을 곱하면 원본 픽셀 좌표가 된다.
/// 버퍼는 **미러링·회전하지 않은 원본 그대로** 넘긴다.
extension GrayImage {
    /// 밝기(Y) 평면 (픽셀당 1바이트, 420YpCbCr 포맷의 첫 평면).
    public init?(luma bytes: UnsafeRawBufferPointer, width: Int, height: Int, bytesPerRow: Int, step: Int) {
        guard step >= 1, width >= step, height >= step, bytesPerRow >= width,
              bytes.count >= bytesPerRow * (height - 1) + width else { return nil }
        self.init(width: width / step, height: height / step, step: step) { x, y in
            Int(bytes[y * bytesPerRow + x])
        }
    }

    /// BGRA (픽셀당 4바이트). 밝기 = 0.30R + 0.59G + 0.11B 근사.
    public init?(bgra bytes: UnsafeRawBufferPointer, width: Int, height: Int, bytesPerRow: Int, step: Int) {
        guard step >= 1, width >= step, height >= step, bytesPerRow >= width * 4,
              bytes.count >= bytesPerRow * (height - 1) + width * 4 else { return nil }
        self.init(width: width / step, height: height / step, step: step) { x, y in
            let i = y * bytesPerRow + x * 4
            return (77 * Int(bytes[i + 2]) + 150 * Int(bytes[i + 1]) + 29 * Int(bytes[i])) >> 8
        }
    }

    private init?(width: Int, height: Int, step: Int, brightness: (Int, Int) -> Int) {
        var pixels = [UInt8](repeating: 0, count: width * height)
        let count = step * step
        for y in 0..<height {
            for x in 0..<width {
                var sum = 0
                for dy in 0..<step {
                    for dx in 0..<step { sum += brightness(x * step + dx, y * step + dy) }
                }
                pixels[y * width + x] = UInt8(sum / count)
            }
        }
        self.init(width: width, height: height, pixels: pixels)
    }
}
