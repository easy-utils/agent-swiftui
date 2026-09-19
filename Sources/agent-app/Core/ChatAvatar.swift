import SwiftUI

/// Honeycomb identicon — exact port of flutter/widgets/chat_avatar.dart
/// (branch level) and compose ChatAvatar.kt.
///
/// The hash and pattern must match the other clients precisely, so the
/// arithmetic keeps the same shape: FNV-1a over the seed (masked to 31 bits per
/// step) followed by the same `mix` finalizer. Overflow is emulated with
/// `&*`/`&+` so the 32-bit wrapping multiplications match Dart/Kotlin/JS.
struct HexCell {
    var x: CGFloat
    var y: CGFloat
    var r: CGFloat
    var on: Bool
}

struct AvatarSpec {
    var bg: Color
    var fg: Color
    var hexes: [HexCell]
}

enum ChatAvatarMath {
    static let hexSize: CGFloat = 0.10
    private static let m32: UInt32 = 0xffff_ffff

    static func fnv(_ s: String) -> UInt32 {
        var h: UInt32 = 0x811c_9dc5
        for cu in s.unicodeScalars {
            h ^= UInt32(cu.value)
            h = (h &* 0x0100_0193) & 0x7fff_ffff
        }
        return h
    }

    static func mix(_ x0: UInt32) -> UInt32 {
        var x = x0
        x = (x ^ (x >> 16)) &* 0x7feb_352d
        x = (x ^ (x >> 15)) &* 0x846c_a68b
        return x ^ (x >> 16)
    }

    static func bitAt(_ seed: String, _ i: Int) -> Bool {
        if seed.isEmpty { return (i & 1) == 0 }
        return (mix(fnv("\(seed)#\(i)")) & 1) == 1
    }

    static func hue(_ source: String) -> Double {
        Double(fnv(source) % 360)
    }

    static func honeycombCells(_ seed: String, mirror: Bool) -> [HexCell] {
        let r = hexSize
        let stepX = CGFloat(3.0.squareRoot()) * r
        let stepY = 1.5 * r
        var cells: [HexCell] = []
        for row in -8...8 {
            let y = CGFloat(row) * stepY
            let xOff = row % 2 != 0 ? stepX / 2 : 0
            for col in -8...8 {
                let x = CGFloat(col) * stepX + xOff
                if (x * x + y * y).squareRoot() > 0.5 - r { continue }
                cells.append(HexCell(x: x, y: y, r: r, on: true))
            }
        }
        if !mirror {
            return cells.enumerated().map { HexCell(x: $1.x, y: $1.y, r: r, on: bitAt(seed, $0)) }
        }
        // Mirror-symmetric about the vertical axis: one shared bit per x → -x pair.
        func key(_ x: CGFloat, _ y: CGFloat) -> String {
            "\(Int((x * 1_000_000).rounded()))|\(Int((y * 1_000_000).rounded()))"
        }
        var byCoord: [String: Int] = [:]
        for (i, c) in cells.enumerated() { byCoord[key(-c.x, c.y)] = i }
        var on = [Bool](repeating: false, count: cells.count)
        for (i, c) in cells.enumerated() where !on[i] {
            let mi = byCoord[key(c.x, c.y)] ?? i
            let bit = bitAt(seed, min(i, mi))
            on[i] = bit
            if mi != i { on[mi] = bit }
        }
        return cells.enumerated().map { HexCell(x: $1.x, y: $1.y, r: r, on: on[$0]) }
    }

    /// HSL (h in degrees, s/l 0…1) → RGB 0…1.
    static func hsl(_ hue: Double, _ sat: Double, _ light: Double) -> (Double, Double, Double) {
        let c = (1 - abs(2 * light - 1)) * sat
        let hp = hue / 60
        let x = c * (1 - abs(hp.truncatingRemainder(dividingBy: 2) - 1))
        var r1 = 0.0, g1 = 0.0, b1 = 0.0
        switch hp {
        case ..<1: (r1, g1, b1) = (c, x, 0)
        case ..<2: (r1, g1, b1) = (x, c, 0)
        case ..<3: (r1, g1, b1) = (0, c, x)
        case ..<4: (r1, g1, b1) = (0, x, c)
        case ..<5: (r1, g1, b1) = (x, 0, c)
        default: (r1, g1, b1) = (c, 0, x)
        }
        let m = light - c / 2
        // Quantise to 8-bit channels with ROUND, matching Flutter's
        // HSLColor.toColor (`(v * 0xFF).round()`), WebUI and Compose. Returning
        // raw floats would leave the byte value to CoreGraphics' own rounding,
        // which is not guaranteed to agree at a contrast-ladder boundary.
        func ch(_ v: Double) -> Double { (min(1, max(0, v + m)) * 255).rounded() / 255 }
        return (ch(r1), ch(g1), ch(b1))
    }

    static func color(_ rgb: (Double, Double, Double)) -> Color {
        Color(red: rgb.0, green: rgb.1, blue: rgb.2)
    }

    static func luminance(_ rgb: (Double, Double, Double)) -> Double {
        func ch(_ v: Double) -> Double {
            v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * ch(rgb.0) + 0.7152 * ch(rgb.1) + 0.0722 * ch(rgb.2)
    }

    static func contrast(_ a: (Double, Double, Double), _ b: (Double, Double, Double)) -> Double {
        let la = luminance(a)
        let lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    static func spec(_ seed: String) -> AvatarSpec {
        let hue = self.hue(seed)
        let bgRgb = hsl(hue, 0.60, 0.48)
        let darkRungs = [0.34, 0.28, 0.22, 0.17, 0.12]
        let lightRungs = [0.66, 0.72, 0.78, 0.84, 0.90]
        var best = hsl(hue, 0.62, 0.66)
        var bestRatio = -1.0
        for l in darkRungs + lightRungs {
            let c = hsl(hue, 0.62, l)
            let ratio = contrast(c, bgRgb)
            if ratio > bestRatio {
                bestRatio = ratio
                best = c
            }
            if bestRatio >= 3.5 { break }
        }
        let fgRgb = bestRatio < 3.0
            ? (luminance(bgRgb) > 0.35 ? (0.090, 0.094, 0.110) : (1.0, 1.0, 1.0))
            : best
        return AvatarSpec(
            bg: color(bgRgb),
            fg: color(fgRgb),
            hexes: honeycombCells(seed, mirror: true)
        )
    }
}

/// Circle-clipped honeycomb identicon (flutter ChatAvatar, branch level).
struct ChatAvatar: View {
    let seed: String
    var size: CGFloat = 40

    var body: some View {
        let spec = ChatAvatarMath.spec(seed)
        Canvas { ctx, canvasSize in
            let d = min(canvasSize.width, canvasSize.height)
            let cx = canvasSize.width / 2
            let cy = canvasSize.height / 2
            let disc = Path(ellipseIn: CGRect(x: cx - d / 2, y: cy - d / 2, width: d, height: d))
            ctx.fill(disc, with: .color(spec.bg))
            ctx.clip(to: disc)
            for h in spec.hexes where h.on {
                var path = Path()
                let hx = cx + h.x * d
                let hy = cy + h.y * d
                let r = h.r * d
                for k in 0..<6 {
                    let a = Double.pi / 6 + Double(k) * Double.pi / 3
                    let pt = CGPoint(x: hx + r * CGFloat(cos(a)), y: hy + r * CGFloat(sin(a)))
                    if k == 0 { path.move(to: pt) } else { path.addLine(to: pt) }
                }
                path.closeSubpath()
                ctx.fill(path, with: .color(spec.fg))
            }
        }
        .frame(width: size, height: size)
    }
}
