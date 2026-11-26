import CryptoKit
import Foundation
import PencilKit
import VellumCore

#if os(macOS)
import AppKit
private typealias InkMaskPath = NSBezierPath
#else
import UIKit
private typealias InkMaskPath = UIBezierPath
#endif

enum PortableStrokeConversionError: Error {
    case unsupportedInk(String)
    case invalidColor, invalidDate, invalidPath, unsupportedMask, signatureMismatch
}

extension PortableStroke {
    var rawPathID: String { strokeID(created: createdAt, points: points) }

    /// I3 identity uses only the creation instant and raw control-point x/y/t.
    static func rawPathID(of stroke: PKStroke) throws -> String {
        try strokeID(created: InkTimestamp.format(stroke.path.creationDate), points: stroke.path.map(PortablePoint.init))
    }

    /// Reject a stale mutable signature even when a previous Apple save kept
    /// the same raw path. Future wire fields and the supplied ID are opaque.
    func describes(_ stroke: PKStroke) throws -> Bool {
        let m = stroke.transform
        let ranges = stroke.maskedPathRanges.map { [Double($0.lowerBound), Double($0.upperBound)] }
        let expectedMask = try mask?.rebuild()
        return try ink == stroke.ink.inkType.rawValue && randomSeed == stroke.randomSeed
            && close(color, rgba(stroke.ink.color.cgColor))
            && close(transform, [m.a, m.b, m.c, m.d, m.tx, m.ty])
            && points.count == stroke.path.count && zip(points, stroke.path).allSatisfy { $0.matches($1) }
            && ranges.count == visibleRanges.count && zip(visibleRanges, ranges).allSatisfy(close)
            && stroke.mask?.cgPath == expectedMask?.cgPath && stroke.mask?.inkEvenOdd == mask?.evenOdd
    }

    init(_ stroke: PKStroke) throws {
        let created = try InkTimestamp.format(stroke.path.creationDate)
        let points = stroke.path.map(PortablePoint.init)
        let transform = stroke.transform
        self.init(id: strokeID(created: created, points: points), ink: stroke.ink.inkType.rawValue,
                  color: try rgba(stroke.ink.color.cgColor),
                  transform: [transform.a, transform.b, transform.c, transform.d, transform.tx, transform.ty],
                  createdAt: created, points: points, randomSeed: stroke.randomSeed,
                  visibleRanges: stroke.maskedPathRanges.map { [$0.lowerBound, $0.upperBound] },
                  mask: try stroke.mask.map(PortableStrokeMask.init))
    }
}

// SHA-256 over UTF-8: the 27-byte UTC timestamp followed directly by each
// raw x, y, t as 16 lowercase hex digits (binary64, most significant first).
// The fixed widths delimit every field. Never transform or round the points.
private func strokeID(created: String, points: [PortablePoint]) -> String {
    var hash = SHA256()
    hash.update(data: Data(created.utf8))
    for point in points {
        let triple = [point.x, point.y, point.t].map { String(format: "%016llx", $0.bitPattern) }.joined()
        hash.update(data: Data(triple.utf8))
    }
    return hash.finalize().map { String(format: "%02x", $0) }.joined()
}

private enum InkTimestamp {
    // ICU's fractional-second field loses submillisecond precision. Format
    // only whole seconds with it and round the fractional part separately.
    static let seconds: DateFormatter = {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = TimeZone(secondsFromGMT: 0)
        format.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return format
    }()

    static func format(_ date: Date) throws -> String {
        let time = date.timeIntervalSinceReferenceDate
        guard time.isFinite else { throw PortableStrokeConversionError.invalidDate }
        var whole = floor(time)
        var micros = Int(((time - whole) * 1_000_000).rounded())
        if micros == 1_000_000 {
            whole += 1
            micros = 0
        }
        let prefix = seconds.string(from: Date(timeIntervalSinceReferenceDate: whole))
        guard prefix.utf8.count == 19 else { throw PortableStrokeConversionError.invalidDate }
        return prefix + String(format: ".%06dZ", micros)
    }

    static func parse(_ text: String) throws -> Date {
        guard text.utf8.count == 27, text.last == "Z",
              let whole = seconds.date(from: String(text.prefix(19))),
              let micros = Int(text.dropFirst(20).dropLast()) else { throw PortableStrokeConversionError.invalidDate }
        let date = whole.addingTimeInterval(Double(micros) / 1_000_000)
        guard try format(date) == text else { throw PortableStrokeConversionError.invalidDate }
        return date
    }
}

private let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

private func rgba(_ color: CGColor) throws -> [Double] {
    guard let converted = color.converted(to: srgb, intent: .relativeColorimetric, options: nil),
          let values = converted.components, values.count == 4 else { throw PortableStrokeConversionError.invalidColor }
    return values.map { Double($0) }
}

extension PKStroke {
    /// Fail closed when the native path or mask cannot reproduce the recorded
    /// signature. In particular, visible intervals cannot stand in for a missing mask.
    init(_ stroke: PortableStroke) throws {
        guard let inkType = PKInk.InkType(rawValue: stroke.ink) else {
            throw PortableStrokeConversionError.unsupportedInk(stroke.ink)
        }
        let c = stroke.color
        guard c.count == 4, c.allSatisfy({ (0...1).contains($0) }),
              let cgColor = CGColor(colorSpace: srgb, components: c.map { CGFloat($0) }) else {
            throw PortableStrokeConversionError.invalidColor
        }
        #if os(macOS)
        guard let color = NSColor(cgColor: cgColor) else { throw PortableStrokeConversionError.invalidColor }
        #else
        let color = UIColor(cgColor: cgColor)
        #endif

        let m = stroke.transform
        guard m.count == 6, m.allSatisfy(\.isFinite), !stroke.points.isEmpty else {
            throw PortableStrokeConversionError.invalidPath
        }
        let date = try InkTimestamp.parse(stroke.createdAt)
        let path = try PKStrokePath(controlPoints: stroke.points.map { try $0.rebuild() }, creationDate: date)
        let mask = try stroke.mask?.rebuild()
        self.init(ink: PKInk(inkType, color: color), path: path,
                  transform: CGAffineTransform(a: m[0], b: m[1], c: m[2], d: m[3], tx: m[4], ty: m[5]),
                  mask: mask, randomSeed: stroke.randomSeed)

        let rebuiltMask = self.mask
        guard rebuiltMask?.cgPath == mask?.cgPath,
              rebuiltMask?.inkEvenOdd == stroke.mask?.evenOdd else { throw PortableStrokeConversionError.unsupportedMask }
        let actual = self.maskedPathRanges.map { [Double($0.lowerBound), Double($0.upperBound)] }
        // Without geometry a display-only erasure must fail, even when the
        // erased sliver is narrower than the signature's float tolerance.
        if mask == nil, actual != stroke.visibleRanges { throw PortableStrokeConversionError.unsupportedMask }

        let transform = self.transform
        guard self.path.count == stroke.points.count,
              zip(stroke.points, self.path).allSatisfy({ $0.matches($1) }),
              try InkTimestamp.format(self.path.creationDate) == stroke.createdAt,
              close([transform.a, transform.b, transform.c, transform.d, transform.tx, transform.ty], m),
              try close(rgba(self.ink.color.cgColor), c),
              actual.count == stroke.visibleRanges.count,
              zip(actual, stroke.visibleRanges).allSatisfy(close)
        else { throw PortableStrokeConversionError.signatureMismatch }
    }
}

private func close(_ lhs: [Double], _ rhs: [Double]) -> Bool {
    lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { abs($0 - $1) <= 1e-6 }
}

private extension PortablePoint {
    init(_ point: PKStrokePoint) {
        self.init(x: point.location.x, y: point.location.y, t: point.timeOffset,
                  w: point.size.width, h: point.size.height, opacity: point.opacity, force: point.force,
                  azimuth: point.azimuth, altitude: point.altitude, secondaryScale: point.secondaryScale)
    }

    func matches(_ point: PKStrokePoint) -> Bool {
        // Identity inputs require exact bits, independently of signature tolerance.
        x.bitPattern == point.location.x.bitPattern && y.bitPattern == point.location.y.bitPattern
            && t.bitPattern == point.timeOffset.bitPattern
            && close([w, h, opacity, force, azimuth, altitude, secondaryScale],
                     [point.size.width, point.size.height, point.opacity, point.force,
                      point.azimuth, point.altitude, point.secondaryScale])
    }

    func rebuild() throws -> PKStrokePoint {
        guard [x, y, t, w, h, opacity, force, azimuth, altitude, secondaryScale].allSatisfy({ Float($0).isFinite })
        else { throw PortableStrokeConversionError.invalidPath }

        func make(azimuth: Double, altitude: Double) -> PKStrokePoint {
            PKStrokePoint(location: CGPoint(x: x, y: y), timeOffset: t, size: CGSize(width: w, height: h),
                          opacity: opacity, force: force, azimuth: azimuth, altitude: altitude,
                          secondaryScale: secondaryScale)
        }
        let point = make(azimuth: azimuth, altitude: altitude)
        if matches(point) { return point }
        // macOS PencilKit can quantize an already decoded angle one bin lower
        // (the I0 zero-input azimuth is -0.000047937631...). Aim halfway into
        // the observed bin. The final native path is still checked at 1e-6.
        return make(azimuth: azimuth + (azimuth - point.azimuth) / 2,
                    altitude: altitude + (altitude - point.altitude) / 2)
    }
}

private extension InkMaskPath {
    var inkEvenOdd: Bool {
        #if os(macOS)
        windingRule == .evenOdd
        #else
        usesEvenOddFillRule
        #endif
    }
}

private extension PortableStrokeMask {
    init(_ mask: InkMaskPath) throws {
        var commands: [Command] = []
        var supported = true
        mask.cgPath.applyWithBlock { pointer in
            let e = pointer.pointee
            let verb: String
            let count: Int
            switch e.type {
            case .moveToPoint: (verb, count) = ("M", 1)
            case .addLineToPoint: (verb, count) = ("L", 1)
            case .addQuadCurveToPoint: (verb, count) = ("Q", 2)
            case .addCurveToPoint: (verb, count) = ("C", 3)
            case .closeSubpath: (verb, count) = ("Z", 0)
            @unknown default:
                supported = false
                return
            }
            commands.append(Command(verb, (0..<count).flatMap { [e.points[$0].x, e.points[$0].y] }))
        }
        guard supported else { throw PortableStrokeConversionError.unsupportedMask }
        self.init(evenOdd: mask.inkEvenOdd, path: commands)
    }

    func rebuild() throws -> InkMaskPath {
        let result = CGMutablePath()
        for command in path {
            let c = command.coordinates
            guard c.allSatisfy(\.isFinite), command.verb == "M" || !result.isEmpty else {
                throw PortableStrokeConversionError.unsupportedMask
            }
            func point(_ i: Int) -> CGPoint { CGPoint(x: c[i], y: c[i + 1]) }
            switch (command.verb, c.count) {
            case ("M", 2): result.move(to: point(0))
            case ("L", 2): result.addLine(to: point(0))
            case ("Q", 4): result.addQuadCurve(to: point(2), control: point(0))
            case ("C", 6): result.addCurve(to: point(4), control1: point(0), control2: point(2))
            case ("Z", 0): result.closeSubpath()
            default: throw PortableStrokeConversionError.unsupportedMask
            }
        }
        let mask = InkMaskPath(cgPath: result)
        #if os(macOS)
        mask.windingRule = evenOdd ? .evenOdd : .nonZero
        #else
        mask.usesEvenOddFillRule = evenOdd
        #endif
        return mask
    }
}

extension PKDrawing {
    init(pdfStrokePayload: String) throws {
        try self.init(portableStrokes: PortableStroke.decodePDFPayload(pdfStrokePayload))
    }

    init(portableStrokes: [PortableStroke]) throws {
        guard !portableStrokes.isEmpty else { throw PortableStrokeConversionError.invalidPath }
        self.init(strokes: try portableStrokes.map(PKStroke.init))
    }
}
