import CoreGraphics
import Foundation

public enum CheckupFieldKind: String, Codable, CaseIterable, Sendable {
  case black, red, green, blue, gray7, gray50, ramp, white, witness

  /// The field order the flow shows them in; white is last and shortest (CK17).
  public static let protocolOrder: [CheckupFieldKind] = [.black, .red, .green, .blue, .gray7, .gray50, .ramp, .white]

  public var capSeconds: Int { self == .white ? 10 : 20 }

  /// Pixel fields carry the plant; the others are ungraded attestations (CK23).
  public var carriesPlant: Bool {
    switch self {
    case .black, .red, .green, .blue, .white: true
    case .gray7, .gray50, .ramp, .witness: false
    }
  }
}

public struct CheckupPlant: Equatable, Sendable {
  public let x: Int
  public let y: Int
  public let size: Int
  public init(x: Int, y: Int, size: Int) { self.x = x; self.y = y; self.size = size }
}

public enum CheckupField {
  /// sRGB 8-bit fill per field. Grays are encoded values, not linear.
  static func fill(for kind: CheckupFieldKind) -> (r: UInt8, g: UInt8, b: UInt8) {
    switch kind {
    case .black, .ramp, .witness: (0, 0, 0)
    case .red: (255, 0, 0)
    case .green: (0, 255, 0)
    case .blue: (0, 0, 255)
    case .gray7: (18, 18, 18)
    case .gray50: (128, 128, 128)
    case .white: (255, 255, 255)
    }
  }

  public static func plantColor(for kind: CheckupFieldKind) -> (r: UInt8, g: UInt8, b: UInt8) {
    kind == .black ? (255, 255, 255) : (0, 0, 0)
  }

  /// Linear luminance of the field, for the exposure booking.
  public static func luminance(of kind: CheckupFieldKind) -> Double {
    func linear(_ v: UInt8) -> Double {
      let c = Double(v) / 255
      return c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
    }
    switch kind {
    case .ramp: return 0.5 * (linear(255) + linear(0)) / 2 + 0.25 * linear(128)
    case .witness: return 0.1
    default:
      let f = fill(for: kind)
      return 0.2126 * linear(f.r) + 0.7152 * linear(f.g) + 0.0722 * linear(f.b)
    }
  }

  /// Never in the outer 5% of either axis: bezels and rounded corners hide
  /// a plant there, which would grade the user for the panel's geometry.
  public static func plantPosition<G: RandomNumberGenerator>(
    width: Int, height: Int, size: Int, using rng: inout G
  ) -> CheckupPlant {
    let mx = width / 20, my = height / 20
    let x = Int.random(in: mx...(width - mx - size), using: &rng)
    let y = Int.random(in: my...(height - my - size), using: &rng)
    return CheckupPlant(x: x, y: y, size: size)
  }

  public static func image(
    kind: CheckupFieldKind, pixelWidth: Int, pixelHeight: Int, plant: CheckupPlant?
  ) -> CGImage? {
    guard pixelWidth > 0, pixelHeight > 0,
      let ctx = CGContext(
        data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8,
        bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { return nil }
    // Top-left origin, so the plant's y is the y a user would tap.
    ctx.translateBy(x: 0, y: CGFloat(pixelHeight))
    ctx.scaleBy(x: 1, y: -1)
    ctx.interpolationQuality = .none

    let f = fill(for: kind)
    ctx.setFillColor(red: CGFloat(f.r) / 255, green: CGFloat(f.g) / 255, blue: CGFloat(f.b) / 255, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))

    switch kind {
    case .ramp:
      for x in 0..<pixelWidth {
        let v = CGFloat(x) / CGFloat(max(pixelWidth - 1, 1))
        ctx.setFillColor(red: v, green: v, blue: v, alpha: 1)
        ctx.fill(CGRect(x: x, y: 0, width: 1, height: pixelHeight))
      }
    case .witness:
      // A circle on the left, a square on the right, equal diameters, white on
      // black; a stretched aspect turns the circle into an ellipse on glass.
      let d = CGFloat(min(pixelWidth / 2, pixelHeight)) * 0.75
      ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 1)
      ctx.fillEllipse(in: CGRect(x: CGFloat(pixelWidth) / 4 - d / 2, y: CGFloat(pixelHeight) / 2 - d / 2, width: d, height: d))
      ctx.fill(CGRect(x: CGFloat(pixelWidth) * 3 / 4 - d / 2, y: CGFloat(pixelHeight) / 2 - d / 2, width: d, height: d))
    default:
      break
    }

    if let plant, kind.carriesPlant {
      let p = plantColor(for: kind)
      ctx.setFillColor(red: CGFloat(p.r) / 255, green: CGFloat(p.g) / 255, blue: CGFloat(p.b) / 255, alpha: 1)
      ctx.fill(CGRect(x: plant.x, y: plant.y, width: plant.size, height: plant.size))
    }
    return ctx.makeImage()
  }

  /// Reads one pixel back, top-left origin. A test helper, public so the
  /// paint tool's readback can use the same reader.
  public static func pixel(in image: CGImage, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
    guard let data = image.dataProvider?.data, let ptr = CFDataGetBytePtr(data) else { return (0, 0, 0) }
    let offset = y * image.bytesPerRow + x * (image.bitsPerPixel / 8)
    return (ptr[offset], ptr[offset + 1], ptr[offset + 2])
  }
}
