import UIKit
import CoreImage
import simd

enum EPaperColor: String, CaseIterable, Identifiable {
    case bw = "Black / White", bwr = "Black / White / Red", bwy = "Black / White / Yellow"
    var id: String { rawValue }

    var palette: [SIMD3<Float>] {
        switch self {
        case .bw:  return [SIMD3(0, 0, 0), SIMD3(255, 255, 255)]
        case .bwr: return [SIMD3(0, 0, 0), SIMD3(255, 255, 255), SIMD3(220, 0, 0)]
        case .bwy: return [SIMD3(0, 0, 0), SIMD3(255, 255, 255), SIMD3(240, 200, 0)]
        }
    }
    /// Screen colour byte for Set Screen Type ('DA' 0000)
    var colorByte: UInt8 {
        switch self { case .bw: return 0x20; case .bwr: return 0x30; case .bwy: return 0x31 }
    }
    /// Colour control params ('DA' 0001): black 00, white 10, colour 01
    var colorParams: [UInt8] {
        switch self {
        case .bw:  return [0x12, 0x00, 0x30]
        case .bwr: return [0x23, 0x00, 0x30, 0x48]
        case .bwy: return [0x23, 0x00, 0x30, 0x68]
        }
    }
}

enum Resolution: String, CaseIterable, Identifiable {
    case r200 = "200 × 200", r152 = "152 × 152", r304x152 = "304 × 152"
    var id: String { rawValue }
    var width: Int {
        switch self {
        case .r200: return 200
        case .r152: return 152
        case .r304x152: return 304
        }
    }
    var height: Int { self == .r304x152 ? 152 : width }
    var sizeByte: UInt8? {
        switch self {
        case .r200: return 0x12
        case .r152: return 0x02
        case .r304x152: return nil
        }
    }

    init?(width: Int, height: Int) {
        switch (width, height) {
        case (200, 200): self = .r200
        case (152, 152): self = .r152
        case (304, 152): self = .r304x152
        default: return nil
        }
    }

    init?(sizeByte b: UInt8) {
        switch b {
        case 0x02: self = .r152
        case 0x12: self = .r200
        default: return nil
        }
    }
}

extension EPaperColor {
    init?(colorByte b: UInt8) {
        switch b {
        case 0x20: self = .bw
        case 0x30: self = .bwr
        case 0x31: self = .bwy
        default: return nil
        }
    }
}

extension TagConfig {
    /// Panel settings the tag is currently configured for (nil if not a supported 1.54" type).
    var resolution: Resolution? {
        if let width, let height {
            return Resolution(width: width, height: height)
        }
        return sizeByte.flatMap { Resolution(sizeByte: $0) }
    }
    var color: EPaperColor? { colorByte.flatMap { EPaperColor(colorByte: $0) } }
}

struct ImageSettings: Equatable {
    var brightness: Double = 0      // -0.5 … 0.5
    var contrast: Double = 1        // 0.5 … 2.0
    var zoom: Double = 1            // 1 … 3
    var dither = true
    var invert = false
    var color: EPaperColor = .bw
    var resolution: Resolution = .r200
    var rotation = 0                // 0…3 (x90° CW, applied when sending)
    var mirror = false
}

struct Processed {
    let preview: UIImage
    let indices: [UInt8]            // 0 black, 1 white, 2 colour
    let width: Int, height: Int
}

enum ImageProcessor {
    private static let ciContext = CIContext()

    static func render(_ src: UIImage, _ s: ImageSettings) -> Processed? {
        let w = s.resolution.width, h = s.resolution.height

        // 1. Aspect-fill crop + zoom
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1; fmt.opaque = true
        let sized = UIGraphicsImageRenderer(size: CGSize(width: w, height: h), format: fmt).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            let scale = max(CGFloat(w) / src.size.width, CGFloat(h) / src.size.height) * CGFloat(s.zoom)
            let dw = src.size.width * scale, dh = src.size.height * scale
            src.draw(in: CGRect(x: (CGFloat(w) - dw) / 2, y: (CGFloat(h) - dh) / 2, width: dw, height: dh))
        }
        guard let cg0 = sized.cgImage else { return nil }

        // 2. Brightness / contrast
        let ci = CIImage(cgImage: cg0)
        guard let f = CIFilter(name: "CIColorControls") else { return nil }
        f.setValue(ci, forKey: kCIInputImageKey)
        f.setValue(s.brightness, forKey: kCIInputBrightnessKey)
        f.setValue(s.contrast, forKey: kCIInputContrastKey)
        guard let out = f.outputImage, let cg = ciContext.createCGImage(out, from: ci.extent) else { return nil }

        // 3. Read pixels
        var rgba = [UInt8](repeating: 255, count: w * h * 4)
        let drawn: Bool = rgba.withUnsafeMutableBytes { ptr in
            guard let c = CGContext(data: ptr.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                    bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            c.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }

        // 4. Quantize (Floyd–Steinberg or nearest colour)
        let pal = s.color.palette
        var buf = (0..<w * h).map { SIMD3<Float>(Float(rgba[$0 * 4]), Float(rgba[$0 * 4 + 1]), Float(rgba[$0 * 4 + 2])) }
        var idx = [UInt8](repeating: 1, count: w * h)
        let lo = SIMD3<Float>(repeating: 0), hi = SIMD3<Float>(repeating: 255)
        for y in 0..<h {
            for x in 0..<w {
                let i = y * w + x
                let c = simd_clamp(buf[i], lo, hi)
                var best = 0
                var bd = Float.greatestFiniteMagnitude
                for (k, p) in pal.enumerated() {
                    let d = simd_distance_squared(c, p)
                    if d < bd { bd = d; best = k }
                }
                idx[i] = UInt8(best)
                guard s.dither else { continue }
                let err = c - pal[best]
                if x + 1 < w { buf[i + 1] += err * (7.0 / 16.0) }
                if y + 1 < h {
                    if x > 0 { buf[i + w - 1] += err * (3.0 / 16.0) }
                    buf[i + w] += err * (5.0 / 16.0)
                    if x + 1 < w { buf[i + w + 1] += err * (1.0 / 16.0) }
                }
            }
        }
        if s.invert { idx = idx.map { $0 == 0 ? 1 : ($0 == 1 ? 0 : $0) } }

        guard let preview = image(idx, w: w, h: h, palette: pal) else { return nil }
        return Processed(preview: preview, indices: idx, width: w, height: h)
    }

    static func image(_ idx: [UInt8], w: Int, h: Int, palette: [SIMD3<Float>]) -> UIImage? {
        var px = [UInt8](repeating: 255, count: w * h * 4)
        for i in 0..<w * h {
            let p = palette[Int(idx[i])]
            px[i * 4] = UInt8(p.x); px[i * 4 + 1] = UInt8(p.y); px[i * 4 + 2] = UInt8(p.z)
        }
        guard let prov = CGDataProvider(data: Data(px) as CFData),
              let cg = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
                               space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                               provider: prov, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        return UIImage(cgImage: cg)
    }

    /// Pack to 1-bpp planes, row-major, MSB first.
    /// Plane 1: 1 = white. Plane 2 (colour screens): 1 = red/yellow.
    static func pack(_ p: Processed, rotation: Int, mirror: Bool, color: EPaperColor) -> [[UInt8]] {
        var idx = p.indices, w = p.width, h = p.height
        if mirror {
            var m = idx
            for y in 0..<h { for x in 0..<w { m[y * w + x] = idx[y * w + (w - 1 - x)] } }
            idx = m
        }
        for _ in 0..<(rotation % 4) { (idx, w, h) = rotateCW(idx, w: w, h: h) }

        let bpr = (w + 7) / 8
        var p1 = [UInt8](repeating: 0, count: bpr * h)
        var p2 = [UInt8](repeating: 0, count: bpr * h)
        for y in 0..<h {
            for x in 0..<w {
                let v = idx[y * w + x]
                let byte = y * bpr + x / 8
                let bit = UInt8(0x80 >> (x % 8))
                if v == 1 { p1[byte] |= bit }
                if v == 2 { p2[byte] |= bit }
            }
        }
        return color == .bw ? [p1] : [p1, p2]
    }

    private static func rotateCW(_ idx: [UInt8], w: Int, h: Int) -> ([UInt8], Int, Int) {
        var out = [UInt8](repeating: 1, count: w * h)
        for y in 0..<h { for x in 0..<w { out[x * h + (h - 1 - y)] = idx[y * w + x] } }
        return (out, h, w)
    }
}
