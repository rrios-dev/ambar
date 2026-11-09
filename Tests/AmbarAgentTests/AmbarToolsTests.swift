import ClipboardKit
import CoreGraphics
import Foundation
import ImageIO
import MCPKit
import Testing
import UniformTypeIdentifiers

@testable import AmbarAgent

/// What an agent reads and asks through `ambar-mcp`, on a made-up history.
@Suite("Ámbar tools", .serialized)
struct AmbarToolsTests {
    struct Fixture {
        let directory: URL
        let note: Int64
        let link: Int64
        let file: Int64
        let image: Int64
        let long: Int64
    }

    static func png(width: Int, height: Int) -> Data {
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(red: 0.9, green: 0.6, blue: 0.1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let output = NSMutableData()
        let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        CGImageDestinationFinalize(destination)
        return output as Data
    }

    private func text(_ kind: ItemKind, _ body: String, uti: String = UTIs.plainText, app: String = "Notes",
                      preview: String? = nil) -> CapturedItem {
        let data = Data(body.utf8)
        return CapturedItem(kind: kind, representations: [Representation(uti: uti, blobHash: nil, inline: data, bytes: data.count)],
                            preview: preview ?? String(body.prefix(200)), searchableText: body, sourceBundle: "com.apple.\(app)",
                            sourceName: app, concealed: false, imageData: nil, fingerprint: UUID().uuidString)
    }

    private func fixture() throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ambar-agent-\(UUID().uuidString)")
        let store = try Store(directory: directory)
        let base = Date(timeIntervalSince1970: 1_791_970_200)
        let note = try store.insert(text(.text, "Presupuesto de la reunión: 12.400 € para el piloto."), now: base)
        let link = try store.insert(text(.url, "https://example.com/acta", uti: UTIs.url, app: "Safari"), now: base.addingTimeInterval(60))
        let file = try store.insert(text(.file, "file:///Users/someone/Documents/acta.pdf", uti: UTIs.fileURL, app: "Finder",
                                         preview: "acta.pdf"), now: base.addingTimeInterval(120))
        let picture = Self.png(width: 3000, height: 2000)
        let blob = try store.blobs.put(picture)
        let image = try store.insert(CapturedItem(
            kind: .image, representations: [Representation(uti: UTIs.png, blobHash: blob.hash, inline: nil, bytes: picture.count)],
            preview: "Imagen 3000 × 2000", searchableText: nil, sourceBundle: "com.apple.screencaptureui",
            sourceName: "Captura", concealed: false, imageData: nil, fingerprint: UUID().uuidString), now: base.addingTimeInterval(180))
        try store.attachImageMeta(itemID: image, width: 3000, height: 2000, thumbnailHash: nil)
        try store.setOCRResult(itemID: image, text: "FACTURA 2026 · Total 980 €", state: .done)
        let long = try store.insert(text(.text, String(repeating: "palabra ", count: 5000)), now: base.addingTimeInterval(240))
        let dictionary = """
            [{"id":"\(UUID().uuidString)","written":"Anthropic","heard":["antropic"],"uses":3,
              "lastUsedAt":"2026-10-14T09:30:00Z","addedAt":"2026-10-01T09:30:00Z"}]
            """
        try Data(dictionary.utf8).write(to: directory.appendingPathComponent("dictionary.json"))
        return Fixture(directory: directory, note: note, link: link, file: file, image: image, long: long)
    }

    private func text(_ result: ToolResult) -> String {
        result.content.compactMap { if case .text(let text) = $0 { text } else { nil } }.joined()
    }

    private func run(_ tool: Tool, _ arguments: [String: JSONValue] = [:]) async throws -> ToolResult {
        try await tool.run(Arguments(arguments))
    }

    @Test("search finds text, links and words read from images; newest first")
    func search() async throws {
        let fixture = try fixture()
        let tools = AmbarTools(dataDirectory: fixture.directory)
        #expect(text(try await run(tools.searchClipboard, ["query": "presupuesto piloto"])).hasPrefix("- \(fixture.note) · text"))
        #expect(text(try await run(tools.searchClipboard, ["query": "factura"])).hasPrefix("- \(fixture.image) · image"))
        let images = try await run(tools.searchClipboard, ["query": "acta", "kind": "url"])
        #expect(images.structured?["items"]?.arrayValue?.map { $0["id"] } == [.int(Int(fixture.link))])
        #expect(text(try await run(tools.searchClipboard, ["query": "zzqx"])).hasPrefix("Nothing in the clipboard history matches"))
        await #expect(throws: ToolError.self) { try await run(tools.searchClipboard, ["query": "acta", "kind": "video"]) }
    }

    @Test("recent items, newest first, bounded")
    func recent() async throws {
        let fixture = try fixture()
        let tools = AmbarTools(dataDirectory: fixture.directory)
        let result = try await run(tools.recentClipboard, ["limit": 3])
        #expect(result.structured?["items"]?.arrayValue?.map { $0["id"] } == [fixture.long, fixture.image, fixture.file].map { .int(Int($0)) })
        await #expect(throws: ToolError.self) { try await run(tools.recentClipboard, ["limit": 500]) }
    }

    @Test("one item in full: text, link, file path, long text cut where asked")
    func item() async throws {
        let fixture = try fixture()
        let tools = AmbarTools(dataDirectory: fixture.directory)
        #expect(text(try await run(tools.getClipboardItem, ["id": .int(Int(fixture.note))])).hasSuffix("Presupuesto de la reunión: 12.400 € para el piloto."))
        #expect(text(try await run(tools.getClipboardItem, ["id": .int(Int(fixture.link))])).hasSuffix("https://example.com/acta"))
        #expect(text(try await run(tools.getClipboardItem, ["id": .int(Int(fixture.file))])).hasSuffix("/Users/someone/Documents/acta.pdf"))
        let cut = text(try await run(tools.getClipboardItem, ["id": .int(Int(fixture.long)), "max_characters": 100]))
        #expect(cut.contains("more characters not shown"))
        await #expect(throws: ToolError.self) { try await run(tools.getClipboardItem, ["id": 999_999]) }
    }

    @Test("an image comes with its text and downscaled under the cap")
    func image() async throws {
        let fixture = try fixture()
        let tools = AmbarTools(dataDirectory: fixture.directory)
        let result = try await run(tools.getClipboardItem, ["id": .int(Int(fixture.image))])
        #expect(text(result).contains("Text read from the image:\nFACTURA 2026 · Total 980 €"))
        guard case .image(let data, let mime) = result.content.last else {
            Issue.record("no image content")
            return
        }
        #expect(mime == "image/jpeg")
        #expect(data.count <= ImageScaling.maximumBytes)
        let source = CGImageSourceCreateWithData(data as CFData, nil)!
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as! [CFString: Any]
        #expect(properties[kCGImagePropertyPixelWidth] as? Int == ImageScaling.maximumSide)
        #expect(text(result).contains("downscaled to 1568×1045"))
    }

    @Test("the dictionary is read from its file")
    func dictionary() async throws {
        let fixture = try fixture()
        let tools = AmbarTools(dataDirectory: fixture.directory)
        #expect(text(try await run(tools.listDictionary)) == "- Anthropic · heard as: antropic")
        let empty = AmbarTools(dataDirectory: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        #expect(text(try await run(empty.listDictionary)) == "The dictionary is empty.")
    }

    @Test("teaching a word goes to the app; a closed or updated app reaches the agent as text")
    func addWord() async throws {
        let fixture = try fixture()
        let asked = Asked()
        let tools = AmbarTools(dataDirectory: fixture.directory, ask: { request in
            asked.set(request)
            return AmbarReply(text: "Added “Forgejo”.")
        })
        #expect(text(try await run(tools.addDictionaryWord, ["word": " Forgejo ", "heard_as": "for hello"])) == "Added “Forgejo”.")
        #expect(asked.request == .addWord(written: "Forgejo", heard: "for hello"))
        await #expect(throws: ToolError.self) { try await run(tools.addDictionaryWord, ["word": "  "]) }
        let closed = AmbarTools(dataDirectory: fixture.directory, ask: { _ in throw LocalChannel.Failure.notRunning })
        await #expect(throws: ToolError("Ámbar is not open. Ask the user to open Ámbar, then try again.")) {
            try await run(closed.addDictionaryWord, ["word": "Forgejo"])
        }
        let stale = AmbarTools(dataDirectory: fixture.directory, ask: { _ in throw LocalChannel.Failure.noReply }, replaced: { true })
        await #expect(throws: ToolError(AmbarTools.reconnect)) { try await run(stale.addDictionaryWord, ["word": "Forgejo"]) }
    }

    @Test("copying puts the text on the clipboard through the given writer")
    func copy() async throws {
        let copied = Asked()
        let tools = AmbarTools(dataDirectory: URL(fileURLWithPath: "/tmp"), copy: { copied.text = $0; return true })
        #expect(text(try await run(tools.copyToClipboard, ["text": "hola"])) == "Copied 4 characters to the clipboard.")
        #expect(copied.text == "hola")
        await #expect(throws: ToolError.self) { try await run(tools.copyToClipboard, ["text": ""]) }
    }

    @Test("reads are read-only; copying and teaching are actions; nothing deletes")
    func annotations() {
        let tools = AmbarTools(dataDirectory: URL(fileURLWithPath: "/tmp"))
        #expect(tools.all.filter { !$0.annotations.readOnly }.map(\.name) == ["add_dictionary_word", "copy_to_clipboard"])
        #expect(tools.all.filter { $0.name.contains("delete") || $0.name.contains("remove") }.isEmpty)
    }
}

private final class Asked: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: AmbarRequest?
    private var copied: String?
    func set(_ request: AmbarRequest) { lock.withLock { stored = request } }
    var request: AmbarRequest? { lock.withLock { stored } }
    var text: String? {
        get { lock.withLock { copied } }
        set { lock.withLock { copied = newValue } }
    }
}
