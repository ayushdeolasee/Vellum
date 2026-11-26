import Foundation

/// The path stays in PencilKit's raw control-point space. Apply the stroke
/// transform to get cluster-local coordinates, then translate by the cluster bounds.
public struct PortableStroke: Equatable, Sendable, Codable {
    /// Minted on Apple. Readers carry this string verbatim, including unfamiliar IDs.
    public var id: String
    public var ink: String
    public var color: [Double]       // sRGB RGBA
    public var transform: [Double]   // a, b, c, d, tx, ty
    public var createdAt: String
    public var points: [PortablePoint]
    public var randomSeed: UInt32
    /// Display intervals in the path's parametric space. Only the mask can rebuild an erasure.
    public var visibleRanges: [[Double]]
    public var mask: PortableStrokeMask?
    public var unknownFields: [String: JSONValue] = [:]

    public init(id: String, ink: String, color: [Double], transform: [Double], createdAt: String,
                points: [PortablePoint], randomSeed: UInt32, visibleRanges: [[Double]], mask: PortableStrokeMask?) {
        self.id = id
        self.ink = ink
        self.color = color
        self.transform = transform
        self.createdAt = createdAt
        self.points = points
        self.randomSeed = randomSeed
        self.visibleRanges = visibleRanges
        self.mask = mask
    }

    private enum CodingKeys: String, CodingKey {
        case id, ink, color, transform, points, mask
        case createdAt = "created_at", randomSeed = "random_seed", visibleRanges = "visible_ranges"
    }

    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        id = try fields.decode(String.self, forKey: .id)
        ink = try fields.decode(String.self, forKey: .ink)
        color = try fields.decode([Double].self, forKey: .color)
        transform = try fields.decode([Double].self, forKey: .transform)
        createdAt = try fields.decode(String.self, forKey: .createdAt)
        points = try fields.decode([PortablePoint].self, forKey: .points)
        randomSeed = try fields.decode(UInt32.self, forKey: .randomSeed)
        visibleRanges = try fields.decode([[Double]].self, forKey: .visibleRanges)
        mask = try fields.decodeIfPresent(PortableStrokeMask.self, forKey: .mask)
        unknownFields = try JSONValue.unknownFields(in: decoder, excluding: CodingKeys.self)
    }

    public func encode(to encoder: Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(id, forKey: .id)
        try fields.encode(ink, forKey: .ink)
        try fields.encode(color, forKey: .color)
        try fields.encode(transform, forKey: .transform)
        try fields.encode(createdAt, forKey: .createdAt)
        try fields.encode(points, forKey: .points)
        try fields.encode(randomSeed, forKey: .randomSeed)
        try fields.encode(visibleRanges, forKey: .visibleRanges)
        try fields.encodeIfPresent(mask, forKey: .mask)
        try JSONValue.encode(unknownFields, to: encoder, excluding: CodingKeys.self)
    }
}

public struct PortablePoint: Equatable, Sendable, Codable {
    public var x, y, t, w, h: Double
    public var opacity, force, azimuth, altitude, secondaryScale: Double
    public var unknownFields: [String: JSONValue] = [:]

    public init(x: Double, y: Double, t: Double, w: Double, h: Double, opacity: Double,
                force: Double, azimuth: Double, altitude: Double, secondaryScale: Double) {
        self.x = x
        self.y = y
        self.t = t
        self.w = w
        self.h = h
        self.opacity = opacity
        self.force = force
        self.azimuth = azimuth
        self.altitude = altitude
        self.secondaryScale = secondaryScale
    }

    private enum CodingKeys: String, CodingKey {
        case x, y, t, w, h, opacity, force, azimuth, altitude
        case secondaryScale = "secondary_scale"
    }

    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        x = try fields.decode(Double.self, forKey: .x)
        y = try fields.decode(Double.self, forKey: .y)
        t = try fields.decode(Double.self, forKey: .t)
        w = try fields.decode(Double.self, forKey: .w)
        h = try fields.decode(Double.self, forKey: .h)
        opacity = try fields.decode(Double.self, forKey: .opacity)
        force = try fields.decode(Double.self, forKey: .force)
        azimuth = try fields.decode(Double.self, forKey: .azimuth)
        altitude = try fields.decode(Double.self, forKey: .altitude)
        secondaryScale = try fields.decode(Double.self, forKey: .secondaryScale)
        unknownFields = try JSONValue.unknownFields(in: decoder, excluding: CodingKeys.self)
    }

    public func encode(to encoder: Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(x, forKey: .x)
        try fields.encode(y, forKey: .y)
        try fields.encode(t, forKey: .t)
        try fields.encode(w, forKey: .w)
        try fields.encode(h, forKey: .h)
        try fields.encode(opacity, forKey: .opacity)
        try fields.encode(force, forKey: .force)
        try fields.encode(azimuth, forKey: .azimuth)
        try fields.encode(altitude, forKey: .altitude)
        try fields.encode(secondaryScale, forKey: .secondaryScale)
        try JSONValue.encode(unknownFields, to: encoder, excluding: CodingKeys.self)
    }
}

public struct PortableStrokeMask: Equatable, Sendable, Codable {
    /// Absolute Bézier commands. Each wire array starts with M, L, Q, C or Z,
    /// followed by x/y pairs (control points first, destination last).
    public struct Command: Equatable, Sendable, Codable {
        public var verb: String
        public var coordinates: [Double]

        public init(_ verb: String, _ coordinates: [Double] = []) {
            self.verb = verb
            self.coordinates = coordinates
        }

        public init(from decoder: Decoder) throws {
            var values = try decoder.unkeyedContainer()
            verb = try values.decode(String.self)
            coordinates = []
            while !values.isAtEnd { coordinates.append(try values.decode(Double.self)) }
        }

        public func encode(to encoder: Encoder) throws {
            var values = encoder.unkeyedContainer()
            try values.encode(verb)
            for value in coordinates { try values.encode(value) }
        }
    }

    public var evenOdd: Bool
    public var path: [Command]
    public var unknownFields: [String: JSONValue] = [:]

    public init(evenOdd: Bool, path: [Command]) {
        self.evenOdd = evenOdd
        self.path = path
    }

    private enum CodingKeys: String, CodingKey {
        case evenOdd = "even_odd", path
    }

    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        evenOdd = try fields.decode(Bool.self, forKey: .evenOdd)
        path = try fields.decode([Command].self, forKey: .path)
        unknownFields = try JSONValue.unknownFields(in: decoder, excluding: CodingKeys.self)
    }

    public func encode(to encoder: Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        try fields.encode(evenOdd, forKey: .evenOdd)
        try fields.encode(path, forKey: .path)
        try JSONValue.encode(unknownFields, to: encoder, excluding: CodingKeys.self)
    }
}

extension PortableStroke {
    /// /VellumInkStrokes is an RFC 1950 zlib stream inside a base64 PDF string.
    public static func decodePDFPayload(_ value: String) throws -> [PortableStroke] {
        let limit = ArchiveCodec.maxInkBytes
        guard value.utf8.count <= (limit + 2) / 3 * 4, let compressed = Data(base64Encoded: value) else {
            throw ArchiveCodecError.invalidDocument("Invalid PDF handwriting data")
        }
        let bytes = try MiniZip.inflate(compressed, cap: limit, windowBits: 15)
        return try JSONDecoder().decode([PortableStroke].self, from: bytes)
    }
}
