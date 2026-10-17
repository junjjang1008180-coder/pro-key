import Foundation
import PaperKeyboardPrinting
import PaperKeyboardShared

// 사용법: swift run layout-pdf [출력 경로]
// 기본 QWERTY 레이아웃을 인쇄용 PDF로 저장한다.
let output = CommandLine.arguments.dropFirst().first ?? "paper_keyboard_qwerty_a4.pdf"

do {
    let layout = try KeyboardLayout.bundledQWERTY()
    guard let data = PrintableLayoutRenderer(layout: layout).pdfData() else {
        FileHandle.standardError.write(Data("PDF를 만들지 못함\n".utf8))
        exit(1)
    }
    try data.write(to: URL(fileURLWithPath: output))
    print("저장: \(output) (\(layout.name), \(Int(layout.paperWidth))×\(Int(layout.paperHeight))mm)")
} catch {
    FileHandle.standardError.write(Data("실패: \(error.localizedDescription)\n".utf8))
    exit(1)
}
