import CoreGraphics
import Foundation

/// Decodes the ThumbHash format described at https://evanw.github.io/thumbhash/.
enum ThumbHash {
    private struct Channel {
        let average: Double
        let coefficients: [(x: Int, y: Int, weight: Double)]

        func sample(x: [Double], y: [Double]) -> Double {
            coefficients.reduce(average) { value, coefficient in
                value + coefficient.weight * x[coefficient.x] * y[coefficient.y]
            }
        }
    }

    static func image(from encoded: String) -> CGImage? {
        guard let data = Data(base64Encoded: encoded), (5...32).contains(data.count) else { return nil }
        let bytes = Array(data)
        let color = Int(bytes[0]) | Int(bytes[1]) << 8 | Int(bytes[2]) << 16
        let shape = Int(bytes[3]) | Int(bytes[4]) << 8
        let alpha = color & (1 << 23) != 0
        let landscape = shape & (1 << 15) != 0
        let longest = alpha ? 5 : 7
        let shortest = max(1, shape & 7)
        guard shortest <= longest else { return nil }
        let xCount = landscape ? longest : shortest
        let yCount = landscape ? shortest : longest
        var nibble = (alpha ? 6 : 5) * 2
        guard bytes.count >= nibble / 2 else { return nil }

        func channel(_ columns: Int, _ rows: Int, average: Double, scale: Double) -> Channel? {
            var terms: [(Int, Int, Double)] = []
            for y in 0..<rows {
                for x in 0..<columns where (x != 0 || y != 0) && x * rows < columns * (rows - y) {
                    guard nibble / 2 < bytes.count else { return nil }
                    let quantized = (bytes[nibble / 2] >> ((nibble % 2) * 4)) & 15
                    terms.append((x, y, (Double(quantized) / 7.5 - 1) * scale * 2))
                    nibble += 1
                }
            }
            return Channel(average: average, coefficients: terms)
        }

        guard let luminance = channel(max(3, xCount), max(3, yCount),
                                      average: Double(color & 63) / 63,
                                      scale: Double((color >> 18) & 31) / 31),
              let p = channel(3, 3, average: Double((color >> 6) & 63) / 31.5 - 1,
                              scale: Double((shape >> 3) & 63) / 63 * 1.25),
              let q = channel(3, 3, average: Double((color >> 12) & 63) / 31.5 - 1,
                              scale: Double((shape >> 9) & 63) / 63 * 1.25)
        else { return nil }

        var opacity = Channel(average: 1, coefficients: [])
        if alpha {
            guard let channel = channel(5, 5, average: Double(bytes[5] & 15) / 15,
                                        scale: Double(bytes[5] >> 4) / 15) else { return nil }
            opacity = channel
        }

        let width = Int((32 * Double(xCount) / Double(longest)).rounded())
        let height = Int((32 * Double(yCount) / Double(longest)).rounded())
        let xBasis = basis(length: width)
        let yBasis = basis(length: height)
        var pixels = Data(capacity: width * height * 4)
        for y in yBasis {
            for x in xBasis {
                let light = luminance.sample(x: x, y: y)
                let blue = light - (2.0 / 3.0) * p.sample(x: x, y: y)
                let difference = q.sample(x: x, y: y)
                let red = (3 * light - blue + difference) / 2
                let green = red - difference
                let a = min(1, max(0, opacity.sample(x: x, y: y)))
                for component in [red, green, blue] {
                    pixels.append(UInt8((min(1, max(0, component)) * a * 255).rounded()))
                }
                pixels.append(UInt8((a * 255).rounded()))
            }
        }

        guard let provider = CGDataProvider(data: pixels as CFData) else { return nil }
        let bitmapInfo = CGBitmapInfo.byteOrder32Big.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue))
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: bitmapInfo, provider: provider, decode: nil,
                       shouldInterpolate: true, intent: .defaultIntent)
    }

    private static func basis(length: Int) -> [[Double]] {
        (0..<length).map { position in
            (0..<7).map { frequency in
                cos(.pi * (Double(position) + 0.5) * Double(frequency) / Double(length))
            }
        }
    }
}
