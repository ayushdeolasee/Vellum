import Foundation

public enum PdfReadOnlyReason: Error, Equatable, Sendable {
    case unsupportedXref, encrypted, signed, nonzeroGeneration
    case malformed, ambiguousAnnotation, unsupportedGeometry
}

public enum PdfEditEligibility: Equatable, Sendable {
    case editable
    case readOnly(PdfReadOnlyReason)

    /// Classify the byte snapshot obtained by the reader, before normalization.
    /// Unknown syntax or an exhausted work budget leaves the reader read-only.
    public static func classify(_ original: Data) -> Self {
        guard original.count <= 128 * 1024 * 1024 else { return .readOnly(.malformed) }
        do {
            try PdfClassicStructure(original).inspect()
            return .editable
        } catch let reason as PdfReadOnlyReason {
            return .readOnly(reason)
        } catch {
            return .readOnly(.malformed)
        }
    }
}

extension PdfClassicStructure {
    private func resolved(_ value: Value?) -> Value? {
        guard let value, let number = value.reference else { return value }
        return objects[number]
    }

    // Inspect EVERY live dictionary (including inline and unreachable ones) in
    // each revision's own object map. A newer object can replace even the name
    // or flags referenced by an older signature field.
    private func inspect(_ value: Value, inbound: inout [Int: Int]) throws {
        try charge()
        switch value {
        case .dictionary(let dict):
            if dict["Perms"] != nil || dict["ByteRange"] != nil ||
                resolved(dict["FT"])?.name == "Sig" ||
                ["Sig", "DocTimeStamp"].contains(resolved(dict["Type"])?.name ?? "") {
                throw Reason.signed
            }
            if let flags = dict["SigFlags"] {
                guard let bits = resolved(flags)?.integer else { throw Reason.malformed }
                if bits != 0 { throw Reason.signed }
            }
            if let type = dict["FT"], resolved(type)?.name == nil { throw Reason.malformed }
            for child in dict.values { try inspect(child, inbound: &inbound) }
        case .array(let items):
            for item in items { try inspect(item, inbound: &inbound) }
        case .reference(let number):
            inbound[number, default: 0] += 1
            guard objects[number] != nil else { throw Reason.malformed }
        default: break
        }
    }

    func validate(trailer: [String: Value], streamDictionaries: Dictionary<Int, Value>.Values) throws {
        var inbound: [Int: Int] = [:]
        for value in objects.values {
            guard value.reference == nil else { throw Reason.malformed }
            try inspect(value, inbound: &inbound)
        }
        for dict in streamDictionaries { try inspect(dict, inbound: &inbound) }
        try inspect(.dictionary(trailer), inbound: &inbound)
        guard let root = trailer["Root"]?.reference, let catalog = objects[root]?.dictionary,
              catalog["Type"]?.name == "Catalog", let pages = catalog["Pages"]?.reference,
              trailer["Info"] == nil || resolved(trailer["Info"])?.dictionary != nil
        else { throw Reason.malformed }

        if let info = trailer["Info"]?.reference, inbound[info] != 1 { throw Reason.malformed }

        if let form = catalog["AcroForm"] {
            guard let fields = resolved(form)?.dictionary,
                  case .array(let roots) = resolved(fields["Fields"]), fields["XFA"] == nil
            else { throw Reason.malformed }
            var visited = Set<Int>()
            func field(_ value: Value, depth: Int) throws {
                try charge()
                guard depth < 64, let n = value.reference, visited.insert(n).inserted,
                      let node = objects[n]?.dictionary else { throw Reason.malformed }
                if let children = node["Kids"] {
                    guard case .array(let items) = resolved(children) else { throw Reason.malformed }
                    for item in items { try field(item, depth: depth + 1) }
                }
            }
            // A field may inherit /FT from a parent. Both dictionaries have
            // already been inspected, independent of their order in /Fields.
            for item in roots { try field(item, depth: 0) }
        }

        if let outline = catalog["Outlines"] { try checkOutline(outline, inbound: inbound) }

        var visited = Set<Int>()
        var ids = Set<String>()
        var pageNumber = 0
        func walk(_ n: Int, parent: Int?, inherited: [String: Value], depth: Int) throws -> Int {
            try charge()
            guard depth < 64, visited.insert(n).inserted, let node = objects[n]?.dictionary,
                  node["Parent"]?.reference == parent, parent != nil || node["Parent"] == nil
            else { throw Reason.malformed }
            var geometry = inherited
            for key in ["MediaBox", "CropBox", "Rotate", "UserUnit"] {
                if let value = node[key] { geometry[key] = value }
            }
            switch node["Type"]?.name {
            case "Pages":
                guard case .array(let kids) = resolved(node["Kids"]), !kids.isEmpty,
                      node["Annots"] == nil else { throw Reason.malformed }
                var count = 0
                for kid in kids {
                    guard let child = kid.reference else { throw Reason.malformed }
                    count += try walk(child, parent: n, inherited: geometry, depth: depth + 1)
                }
                guard count == node["Count"]?.integer else { throw Reason.malformed }
                return count
            case "Page":
                guard parent != nil, node["Kids"] == nil else { throw Reason.malformed }
                try checkGeometry(geometry)
                pageNumber += 1
                if let annots = node["Annots"] {
                    try checkAnnotations(annots, page: n, pageNumber: pageNumber, inbound: inbound, ids: &ids)
                }
                return 1
            default: throw Reason.malformed
            }
        }
        _ = try walk(pages, parent: nil, inherited: [:], depth: 0)
    }

    // The classic bookmark writer appends to the root sibling list. Nested
    // outlines require additional count/ownership semantics beyond that subset.
    private func checkOutline(_ value: Value, inbound: [Int: Int]) throws {
        guard let outline = resolved(value)?.dictionary,
              outline["Type"] == nil || outline["Type"]?.name == "Outlines",
              outline["Pages"] == nil, outline["Subtype"] == nil else { throw Reason.malformed }
        var seen = Set<Int>()
        var previous: Int?
        var next = outline["First"]
        while let item = next {
            try charge()
            guard let n = item.reference, seen.insert(n).inserted, let dict = objects[n]?.dictionary,
                  value.reference != nil, dict["Parent"]?.reference == value.reference,
                  (dict["Prev"] == nil) == (previous == nil), dict["Prev"]?.reference == previous,
                  case .string = resolved(dict["Title"]), dict["First"] == nil, dict["Last"] == nil,
                  dict["Type"] == nil, dict["Subtype"] == nil
            else { throw Reason.malformed }
            // First/Prev and Last/Next account for both inbound links,
            // including the single-item list where First and Last coincide.
            guard inbound[n] == 2 else { throw Reason.malformed }
            previous = n
            next = dict["Next"]
        }
        if let n = value.reference, inbound[n] != 1 + seen.count { throw Reason.malformed }
        guard (outline["Last"] == nil) == (previous == nil), outline["Last"]?.reference == previous,
              (outline["Count"] == nil && seen.isEmpty) || outline["Count"]?.integer == seen.count else { throw Reason.malformed }
    }

    private func checkGeometry(_ geometry: [String: Value]) throws {
        func box(_ value: Value?) throws -> [Double] {
            guard case .array(let items) = resolved(value), items.count == 4 else { throw Reason.unsupportedGeometry }
            let coordinates = items.compactMap { resolved($0)?.number }
            // PDFium exposes these coordinates as floats. Require positive
            // extents after conversion, as well as finite display dimensions.
            guard coordinates.count == 4,
                  coordinates.allSatisfy({ abs($0) <= 16_777_216 }), // exact integer range in PDFium's Float
                  Float(coordinates[2]) > Float(coordinates[0]), Float(coordinates[3]) > Float(coordinates[1])
            else { throw Reason.unsupportedGeometry }
            return coordinates
        }
        let media = try box(geometry["MediaBox"])
        if let value = geometry["CropBox"] {
            let crop = try box(value)
            guard crop[0] >= media[0], crop[1] >= media[1], crop[2] <= media[2], crop[3] <= media[3]
            else { throw Reason.unsupportedGeometry }
        }
        if let value = geometry["Rotate"] {
            guard let angle = resolved(value)?.integer, [0, 90, 180, 270].contains(angle) else { throw Reason.unsupportedGeometry }
        }
        // The current PDFium page-info path reports unscaled box units.
        if let value = geometry["UserUnit"], resolved(value)?.number != 1 { throw Reason.unsupportedGeometry }
    }

    private func checkAnnotations(_ value: Value, page: Int, pageNumber: Int,
                                  inbound: [Int: Int], ids: inout Set<String>) throws {
        func requireExclusiveReference(_ value: Value) throws {
            if let n = value.reference, inbound[n] != 1 { throw Reason.ambiguousAnnotation }
        }
        try requireExclusiveReference(value)
        guard case .array(let slots) = resolved(value) else { throw Reason.ambiguousAnnotation }
        for (index, slot) in slots.enumerated() {
            try charge()
            try requireExclusiveReference(slot)
            if case .null = resolved(slot) { continue }
            guard let dict = resolved(slot)?.dictionary, dict["Subtype"]?.name != nil,
                  dict["Type"] == nil || dict["Type"]?.name == "Annot",
                  dict["P"] == nil || dict["P"]?.reference == page
            else { throw Reason.ambiguousAnnotation }
            let id: String
            if let nm = dict["NM"] {
                // The writer reads a direct PDF text string. Bound decoding
                // and reject IDs outside the unambiguous portable subset.
                guard case .string(let range) = nm, range.count <= 1024,
                      let string = PdfDictSource.decodeTextString(Array(bytes[range])),
                      !string.isEmpty, string.utf8.allSatisfy({ (32...126).contains($0) })
                else { throw Reason.ambiguousAnnotation }
                id = string
            } else {
                id = "pdf-direct-\(pageNumber)-\(index)"
            }
            guard ids.insert(id).inserted else { throw Reason.ambiguousAnnotation }
        }
    }
}
