import UIKit
import CoreImage
import simd

/// Good Display 1.54" 152×152 Black / White / Yellow / Red e-paper panel.
enum Panel {
    static let size = 152
    /// Panel colours in palette order: black, white, yellow, red.
    static let palette: [SIMD3<Float>] = [
        SIMD3(0, 0, 0), SIMD3(255, 255, 255), SIMD3(240, 200, 0), SIMD3(200, 0, 0),
    ]
    /// 2-bit pixel code sent for each palette colour when the tag stores none:
    /// 00 black, 01 white, 10 yellow, 11 red. If yellow and red come out swapped, use [0, 1, 3, 2].
    static let defaultCodes: [UInt8] = [0, 1, 2, 3]

    static func describe(_ codes: [UInt8]) -> String {
        zip(["black", "white", "yellow", "red"], codes)
            .map { "\($0) \(String($1, radix: 2).leftPad(2))" }.joined(separator: ", ")
    }
}

extension String {
    func leftPad(_ n: Int) -> String { String(repeating: "0", count: max(0, n - count)) + self }
}

extension TagConfig {
    /// The manual gives X in bits per row, so a 152×152 panel at 2 bpp (4 colours) reads as 304×152.
    var matchesPanel: Bool { width == Panel.size * 2 && height == Panel.size }

    /// Colour → pixel code table stored on the tag (D1 response tag 'A1', set by 'DA 0001', manual 7.9.3.2),
    /// in palette order. nil unless all four colours are present with distinct codes.
    /// 'A1' value: [scan mode, images|colours, entry…]; entry bits7-5 = colour (000 black, 001 white,
    /// 010 red, 011 yellow), bits4-3 = pixel code.
    var colorCodes: [UInt8]? {
        guard let v = entries.first(where: { $0.tag == 0xA1 })?.value, v.count >= 6 else { return nil }
        let paletteIndex: [UInt8: Int] = [0: 0, 1: 1, 3: 2, 2: 3]
        var codes = [UInt8?](repeating: nil, count: 4)
        for e in v.dropFirst(2) {
            guard let i = paletteIndex[e >> 5], codes[i] == nil else { continue }
            codes[i] = (e >> 3) & 0x03
        }
        let found = codes.compactMap { $0 }
        guard found.count == 4, Set(found).count == 4 else { return nil }
        return found
    }
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
    let indices: [UInt8]            // palette index per pixel (0 black, 1 white, 2 yellow, 3 red)
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
    /// `codes[i]` is the 2-bit pixel code for palette colour i.
    static func pack(_ p: Processed, rotation: Int, mirror: Bool,
                     codes: [UInt8] = Panel.defaultCodes) -> [UInt8] {
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
                plane[y * bpr + x / 4] |= (codes[Int(idx[y * n + x])] & 0x03) << shift
            }
        }
        return plane
    }
}
