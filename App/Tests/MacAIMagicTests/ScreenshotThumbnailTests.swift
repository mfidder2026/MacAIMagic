import XCTest
import SwiftUI
import AppKit
@testable import MacAIMagic

/// The owner wanted to watch along when the model takes a screenshot of a program or the C64 emulator: the model saved
/// 37 screenshots with commands in one C64 conversation and looked at 9, and those 9 showed only while it worked.
@MainActor final class ScreenshotThumbnailTests: XCTestCase {
    private var folder: URL!

    override func setUp() async throws {
        folder = FileManager.default.temporaryDirectory.appendingPathComponent("shots-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("a/b/c"), withIntermediateDirectories: true)
    }

    override func tearDown() async throws { try? FileManager.default.removeItem(at: folder) }

    /// A 384 x 272 picture, the size of a C64 screen in VICE.
    private func png(_ url: URL) throws {
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 384, pixelsHigh: 272, bitsPerSample: 8, samplesPerPixel: 4,
                                                 hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor(red: 0.3, green: 0.3, blue: 0.8, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 384, height: 272).fill()
        NSGraphicsContext.restoreGraphicsState()
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
    }

    func testTheImagesACommandMadeAreFound() throws {
        let old = folder.appendingPathComponent("oud.png")
        try png(old)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)], ofItemAtPath: old.path)
        let start = Date()
        try png(folder.appendingPathComponent("intro.png"))
        try png(folder.appendingPathComponent("a/b/kasteel.png"))
        try png(folder.appendingPathComponent("a/b/c/te-diep.png"))
        try "geen plaatje".write(to: folder.appendingPathComponent("notes.png.txt"), atomically: true, encoding: .utf8)
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("shot-\(UUID().uuidString).png")
        try png(outside)
        defer { try? FileManager.default.removeItem(at: outside) }

        let found = WorkspaceTools.$current.withValue(folder.path) {
            WorkspaceTools.newImages(since: start, mentioned: "python3 c64run.py test.prg --shot \(outside.path)\nscreenshot: intro.png", limit: 10)
        }
        let names = Set(found.map(\.lastPathComponent))
        XCTAssertEqual(names, ["intro.png", "kasteel.png", outside.lastPathComponent], "\(names)")
        // at most `limit`, the newest
        let two = WorkspaceTools.$current.withValue(folder.path) { WorkspaceTools.newImages(since: start, mentioned: "", limit: 1) }
        XCTAssertEqual(two.count, 1)
    }

    func testTheChatCopyIsSmall() throws {
        let url = folder.appendingPathComponent("intro.png")
        try png(url)
        let a = try XCTUnwrap(ImageAttachment.thumbnail(url))
        let img = try XCTUnwrap(NSBitmapImageRep(data: a.jpeg))
        XCTAssertLessThanOrEqual(max(img.pixelsWide, img.pixelsHigh), 360)
        XCTAssertLessThan(a.jpeg.count, 40_000)
        XCTAssertEqual(a.filename, "intro.png")
    }

    func testEachPictureShowsOnceWithItsNewestCopy() {
        func shot(_ name: String, _ byte: UInt8) -> Attachment { Attachment(filename: name, jpeg: Data([byte])) }
        var step1 = ToolActivity(label: "Uitvoeren: c64run.py", done: true)
        step1.images = [shot("intro.png", 1)]
        var step2 = ToolActivity(label: "Uitvoeren: c64run.py", done: true)
        step2.images = [shot("intro.png", 2), shot("kasteel.png", 3)]
        let parts: [AnswerPart] = [.step(step1), .looked(id: "l", attachments: [shot("geel.png", 4)]), .step(step2)]
        let pictures = AnswerPart.pictures(parts)
        XCTAssertEqual(pictures.map(\.filename), ["geel.png", "intro.png", "kasteel.png"])
        XCTAssertEqual(pictures.first { $0.filename == "intro.png" }?.jpeg, Data([2]))
    }

    func testAnOldStepWithoutImagesStillLoads() throws {
        let json = #"{"id":"4F9C8B1E-2D3A-4B5C-9D8E-7F6A5B4C3D2E","label":"Uitvoeren: ls","done":true,"output":"a"}"#
        let a = try JSONDecoder().decode(ToolActivity.self, from: Data(json.utf8))
        XCTAssertNil(a.images)
    }

    /// A finished answer keeps its screenshots in view under "Gedachtegang en N stappen".
    func testAFinishedAnswerShowsItsScreenshotsUnderTheFoldedSteps() throws {
        let url = folder.appendingPathComponent("intro.png")
        try png(url)
        let thumb = try XCTUnwrap(ImageAttachment.thumbnail(url))
        func rounds(withShots: Bool) -> [ChatMessage] {
            var work = ChatMessage(role: .assistant, text: "")
            work.reasoning = "Eerst testen."
            work.activities = (0..<5).map { n in
                var a = ToolActivity(label: "Uitvoeren: c64run.py --shot \(n).png", done: true)
                if withShots { a.images = [Attachment(filename: "\(n).png", jpeg: thumb.jpeg)] }
                return a
            }
            var done = ChatMessage(role: .assistant, text: "Het intro werkt.")
            done.reasoning = "Klaar."
            return [work, done]
        }
        func height(_ r: [ChatMessage], streaming: Bool) -> CGFloat {
            let v = NSHostingView(rootView: AnswerView(rounds: r, streaming: streaming).frame(width: 860))
            v.frame = NSRect(x: 0, y: 0, width: 860, height: 100)
            v.layoutSubtreeIfNeeded()
            return v.fittingSize.height
        }
        let plain = height(rounds(withShots: false), streaming: false)
        let shots = height(rounds(withShots: true), streaming: false)
        print("SHOTS finished \(plain) -> \(shots); live \(height(rounds(withShots: true), streaming: true))")
        XCTAssertGreaterThan(shots, plain + 100, "a row of pictures under the folded steps")
        XCTAssertLessThan(shots, plain + 200, "one row, not one per step")
        XCTAssertLessThan(height(rounds(withShots: true), streaming: true), 1500, "five steps with a picture each while it works")
    }
}
