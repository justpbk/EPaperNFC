import UIKit
import CoreImage
import simd

/// Good Display 1.54" 152×152 Black / White / Yellow / Red e-paper panel.
enum Panel {
    static let size = 152
    /// Palette index = the panel's 2-bit pixel code: 00 black, 01 white, 10 yellow, 11 red.
    /// If yellow and red come out swapped on the panel, swap the last two entries.
    static let palette: [SIMD3<Float>] = [
        SIMD3(0, 0, 0), SIMD3(255, 255, 255), SIMD3(240, 200, 0), SIMD3(200, 0, 0),
    ]
}

extension TagConfig {
    /// 4-colour panels report X in bits at 2 bpp, so a 152×152 panel reads as 304×152.
    var matchesPanel: Bool { width == Panel.size * 2 && height == Panel.size }
}

struct ImageSettings: Equatable {
    var brightness: Double = 0      // -0.5 … 0.5
    var contrast: Double = 1        // 0.5 … 2.0
    var zoom: Double = 1            // 1 … 3
    var dither = true
    var rotation = 0                // 0…3 (x90° CW, applied when sending)
    var mirror = false
}

struct Processed {
    let preview: UIImage
    let indices: [UInt8]            // palette index per pixel (= 2-bit panel code)
}

enum ImageProcessor {
    private static let ciContext = CIContext()

    static func render(_ src: UIImage, _ s: ImageSettings) -> Processed? {
        let n = Panel.size

        // 1. Aspect-fill crop + zoom
        let fmt = UIGraphicsImageRendererFormat()
        fmt.scale = 1; fmt.opaque = true
        let sized = UIGraphicsImageRenderer(size: CGSize(width: n, height: n), format: fmt).image { ctx in
            UIColor.white.setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: n, height: n))
            let scale = max(CGFloat(n) / src.size.width, CGFloat(n) / src.size.height) * CGFloat(s.zoom)
            let dw = src.size.width * scale, dh = src.size.height * scale
            src.draw(in: CGRect(x: (CGFloat(n) - dw) / 2, y: (CGFloat(n) - dh) / 2, width: dw, height: dh))
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
        var rgba = [UInt8](repeating: 255, count: n * n * 4)
        let drawn: Bool = rgba.withUnsafeMutableBytes { ptr in
            guard let c = CGContext(data: ptr.baseAddress, width: n, height: n, bitsPerComponent: 8,
                                    bytesPerRow: n * 4, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            c.draw(cg, in: CGRect(x: 0, y: 0, width: n, height: n))
            return true
        }
        guard drawn else { return nil }

        // 4. Quantize to the 4 panel colours (Floyd–Steinberg or nearest colour)
        let pal = Panel.palette
        var buf = (0..<n * n).map { SIMD3<Float>(Float(rgba[$0 * 4]), Float(rgba[$0 * 4 + 1]), Float(rgba[$0 * 4 + 2])) }
        var idx = [UInt8](repeating: 1, count: n * n)
        let lo = SIMD3<Float>(repeating: 0), hi = SIMD3<Float>(repeating: 255)
        for y in 0..<n {
            for x in 0..<n {
                let i = y * n + x
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
                if x + 1 < n { buf[i + 1] += err * (7.0 / 16.0) }
                if y + 1 < n {
                    if x > 0 { buf[i + n - 1] += err * (3.0 / 16.0) }
                    buf[i + n] += err * (5.0 / 16.0)
                    if x + 1 < n { buf[i + n + 1] += err * (1.0 / 16.0) }
                }
            }
        }

        guard let preview = image(idx, n: n) else { return nil }
        return Processed(preview: preview, indices: idx)
    }

    static func image(_ idx: [UInt8], n: Int) -> UIImage? {
        var px = [UInt8](repeating: 255, count: n * n * 4)
        for i in 0..<n * n {
            let p = Panel.palette[Int(idx[i])]
            px[i * 4] = UInt8(p.x); px[i * 4 + 1] = UInt8(p.y); px[i * 4 + 2] = UInt8(p.z)
        }
        guard let prov = CGDataProvider(data: Data(px) as CFData),
              let cg = CGImage(width: n, height: n, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: n * 4,
                               space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                               provider: prov, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { return nil }
        return UIImage(cgImage: cg)
    }

    /// Pack to one 2-bpp plane, row-major, 4 pixels per byte, first pixel in bits 7-6.
    static func pack(_ p: Processed, rotation: Int, mirror: Bool) -> [UInt8] {
        let n = Panel.size
        var idx = p.indices
        if mirror {
            var m = idx
            for y in 0..<n { for x in 0..<n { m[y * n + x] = idx[y * n + (n - 1 - x)] } }
            idx = m
        }
        for _ in 0..<(rotation % 4) {
            var r = idx
            for y in 0..<n { for x in 0..<n { r[x * n + (n - 1 - y)] = idx[y * n + x] } }
            idx = r
        }

        let bpr = (n * 2 + 7) / 8
        var plane = [UInt8](repeating: 0, count: bpr * n)
        for y in 0..<n {
            for x in 0..<n {
                let shift = UInt8(6 - (x % 4) * 2)
                plane[y * bpr + x / 4] |= (idx[y * n + x] & 0x03) << shift
            }
        }
        return plane
    }
}
