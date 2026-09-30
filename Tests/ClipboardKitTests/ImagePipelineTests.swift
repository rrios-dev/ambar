import AppKit
import BlobStore
import Foundation
import Testing

@testable import ClipboardKit

private func makeTemporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "ambar-image-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Dibuja texto negro sobre blanco: es lo que mejor reconoce Vision y lo que
/// más se parece a una captura de pantalla real, que es el caso de uso.
private func makeImage(withText text: String, width: Int = 900, height: Int = 260) throws -> Data {
    let image = NSImage(size: NSSize(width: width, height: height))
    image.lockFocus()

    NSColor.white.setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()

    let attributes: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 68, weight: .semibold),
        .foregroundColor: NSColor.black,
    ]
    NSAttributedString(string: text, attributes: attributes)
        .draw(at: NSPoint(x: 40, y: 90))

    image.unlockFocus()

    let tiff = try #require(image.tiffRepresentation)
    let bitmap = try #require(NSBitmapImageRep(data: tiff))
    return try #require(bitmap.representation(using: .png, properties: [:]))
}

private func makeImageCapture(_ png: Data) -> CapturedItem {
    CapturedItem(
        kind: .image,
        representations: [
            Representation(uti: UTIs.png, blobHash: nil, inline: nil, bytes: png.count)
        ],
        preview: "",
        searchableText: nil,
        sourceBundle: "com.test.app",
        sourceName: "TestApp",
        concealed: false,
        imageData: png,
        fingerprint: BlobStore.hash(of: png)
    )
}

@Suite("Imágenes — ingesta")
struct ImageIngestionTests {

    @Test("Al capturar una imagen se guarda el blob, la miniatura y sus medidas")
    func ingestStoresBlobAndThumbnail() throws {
        let store = try Store(directory: makeTemporaryDirectory())
        let ingestor = Ingestor(store: store)
        let png = try makeImage(withText: "HOLA", width: 800, height: 400)

        let id = try ingestor.ingest(makeImageCapture(png))
        let item = try #require(try store.item(id: id))
        let meta = try #require(item.imageMeta)

        #expect(item.kind == .image)
        #expect(meta.width == 800)
        #expect(meta.height == 400)
        #expect(meta.thumbnailHash != nil)
        #expect(meta.ocrState == .pending)

        // El original debe seguir recuperable byte a byte: la miniatura es un
        // añadido, nunca un reemplazo.
        let representations = try store.representations(for: id)
        let hash = try #require(representations.compactMap(\.blobHash).first)
        #expect(try store.blobs.data(for: hash) == png)
    }

    @Test("La imagen no se guarda en la base de datos, sino en disco")
    func imageIsNotStoredInline() throws {
        let store = try Store(directory: makeTemporaryDirectory())
        let ingestor = Ingestor(store: store)
        let png = try makeImage(withText: "GRANDE", width: 1600, height: 900)

        let id = try ingestor.ingest(makeImageCapture(png))
        let representations = try store.representations(for: id)

        #expect(representations.allSatisfy { $0.inline == nil })
        #expect(representations.allSatisfy { $0.blobHash != nil })
    }

    @Test("Copiar dos veces la misma imagen no duplica el archivo en disco")
    func repeatedImageDeduplicates() throws {
        let store = try Store(directory: makeTemporaryDirectory())
        let ingestor = Ingestor(store: store)
        let png = try makeImage(withText: "REPETIDA")

        try ingestor.ingest(makeImageCapture(png))
        try ingestor.ingest(makeImageCapture(png))

        #expect(try store.count() == 1)
        // Un blob para la imagen y otro para su miniatura. Ni uno más.
        #expect(try store.blobs.allHashes().count == 2)
    }

    @Test("La purga borra también los blobs que se quedan sin dueño")
    func retentionCollectsOrphanBlobs() throws {
        let store = try Store(directory: makeTemporaryDirectory())
        let ingestor = Ingestor(store: store)
        let now = Date()

        try ingestor.ingest(
            makeImageCapture(try makeImage(withText: "VIEJA")),
            now: now.addingTimeInterval(-90 * 86_400)
        )
        #expect(try store.blobs.allHashes().count == 2)

        let result = try store.applyRetention(
            policy: RetentionPolicy(maximumAge: 30 * 86_400),
            now: now
        )

        #expect(result.deletedItems == 1)
        #expect(result.deletedBlobs == 2)
        #expect(try store.blobs.allHashes().isEmpty)
    }
}

@Suite("Reconocimiento de texto")
struct TextRecognitionTests {

    @Test("Vision lee el texto de una imagen generada")
    func recognizesText() async throws {
        let png = try makeImage(withText: "FACTURA 2026")
        let recognized = try await TextRecognizer(languages: ["es-ES", "en-US"])
            .recognize(imageData: png)

        #expect(recognized.uppercased().contains("FACTURA"))
    }

    @Test("Una imagen copiada se puede encontrar buscando su contenido")
    func imageBecomesSearchableByItsText() async throws {
        let store = try Store(directory: makeTemporaryDirectory())
        let ingestor = Ingestor(store: store)

        let png = try makeImage(withText: "PRESUPUESTO")
        let id = try ingestor.ingest(makeImageCapture(png))

        // Antes del reconocimiento la imagen no es encontrable por su texto:
        // no hay nada que indexar todavía.
        #expect(try store.items(matching: SearchQuery.parse("presupuesto")).isEmpty)

        let queue = OCRQueue(store: store)
        await queue.enqueue(itemID: id)

        // La cola trabaja en segundo plano; se espera al resultado en la base
        // de datos en vez de a un tiempo fijo.
        var state: ImageMeta.OCRState = .pending
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(100))
            state = try store.item(id: id)?.imageMeta?.ocrState ?? .pending
            if state != .pending { break }
        }

        #expect(state == .done)

        let results = try store.items(matching: SearchQuery.parse("presupuesto"))
        #expect(results.count == 1)
        #expect(results.first?.id == id)
    }

    @Test("Una imagen sin texto se marca como omitida, no como fallida")
    func imageWithoutTextIsSkipped() async throws {
        let store = try Store(directory: makeTemporaryDirectory())
        let ingestor = Ingestor(store: store)

        let blank = try makeImage(withText: "", width: 300, height: 300)
        let id = try ingestor.ingest(makeImageCapture(blank))

        let queue = OCRQueue(store: store)
        await queue.enqueue(itemID: id)

        var state: ImageMeta.OCRState = .pending
        for _ in 0..<100 {
            try await Task.sleep(for: .milliseconds(100))
            state = try store.item(id: id)?.imageMeta?.ocrState ?? .pending
            if state != .pending { break }
        }

        // La distinción importa: `failed` se reintentaría en cada arranque.
        #expect(state == .skipped)
    }

    @Test("El trabajo pendiente sobrevive al cierre de la app")
    func pendingWorkIsResumable() throws {
        let directory = makeTemporaryDirectory()
        let store = try Store(directory: directory)
        let ingestor = Ingestor(store: store)

        let id = try ingestor.ingest(makeImageCapture(try makeImage(withText: "PENDIENTE")))
        #expect(try store.pendingOCRItems().contains(id))

        // Una instancia nueva —como al reabrir la app— ve la misma cola.
        let reopened = try Store(directory: directory)
        #expect(try reopened.pendingOCRItems().contains(id))
    }
}
