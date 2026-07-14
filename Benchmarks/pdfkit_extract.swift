import Foundation
import PDFKit

guard CommandLine.arguments.count == 3 else {
    FileHandle.standardError.write(Data("usage: pdfkit_extract INPUT.pdf OUTPUT.json\n".utf8))
    exit(2)
}

let input = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
guard let document = PDFDocument(url: input) else {
    FileHandle.standardError.write(Data("could not open PDF\n".utf8))
    exit(1)
}

let pages = (0..<document.pageCount).map { document.page(at: $0)?.string ?? "" }
let data = try JSONEncoder().encode(pages)
try data.write(to: output, options: .atomic)
