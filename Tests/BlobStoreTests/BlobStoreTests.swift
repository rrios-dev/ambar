import AppKit
import Foundation
import Testing

@testable import BlobStore

private func makeTemporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "blobstore-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Genera un PNG real de color liso.
func makePNG(width: Int, height: Int, color: NSColor = .systemOrange) throws -> Data {
    let image = NSImage(size: NSSize(width: width, height: height))
    image.lockFocus()
    color.setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    image.unlockFocus()

    let tiff = try #require(image.tiffRepresentation)
    let bitmap = try #require(NSBitmapImageRep(data: tiff))
    return try #require(bitmap.representation(using: .png, properties: [:]))
}

@Suite("BlobStore")
struct BlobStoreSuite {

    @Test("Lo que se guarda es exactamente lo que se recupera")
    func roundTrip() throws {
        let store = try BlobStore(root: makeTemporaryDirectory())
        let payload = Data("contenido arbitrario ñáé 🟠".utf8)

        let reference = try store.put(payload)
        #expect(try store.data(for: reference.hash) == payload)
        #expect(reference.bytes == payload.count)
    }

    @Test("Guardar el mismo contenido dos veces escribe un solo archivo")
    func deduplicates() throws {
        let root = makeTemporaryDirectory()
        let store = try BlobStore(root: root)
        let payload = Data(repeating: 0xAB, count: 4096)

        let first = try store.put(payload)
        let second = try store.put(payload)

        #expect(first.hash == second.hash)
        // Esta es la propiedad que justifica el almacén: diez capturas iguales
        // ocupan lo que una.
        #expect(try store.allHashes().count == 1)
    }

    @Test("Contenidos distintos no colisionan")
    func distinctContent() throws {
        let store = try BlobStore(root: makeTemporaryDirectory())
        let a = try store.put(Data("uno".utf8))
        let b = try store.put(Data("dos".utf8))

        #expect(a.hash != b.hash)
        #expect(try store.allHashes().count == 2)
    }

    @Test("Los blobs se reparten en subdirectorios por prefijo")
    func shardsByPrefix() throws {
        let root = makeTemporaryDirectory()
        let store = try BlobStore(root: root)
        let reference = try store.put(Data("algo".utf8))

        let expected = root
            .appending(path: String(reference.hash.prefix(2)))
            .appending(path: reference.hash)
        #expect(FileManager.default.fileExists(atPath: expected.path(percentEncoded: false)))
    }

    @Test("Pedir un blob inexistente da error, no datos vacíos")
    func missingBlobThrows() throws {
        let store = try BlobStore(root: makeTemporaryDirectory())
        #expect(throws: BlobStoreError.self) {
            _ = try store.data(for: String(repeating: "0", count: 64))
        }
    }

    @Test("La miniatura se genera y respeta el tamaño máximo")
    func makesThumbnail() throws {
        let store = try BlobStore(root: makeTemporaryDirectory())
        let png = try makePNG(width: 1200, height: 800)

        let thumbnail = try store.makeThumbnail(from: png, maxPixel: 256)
        let data = try store.data(for: thumbnail.hash)
        let size = try #require(BlobStore.imageSize(of: data))

        #expect(max(size.width, size.height) <= 256)
        // La miniatura debe pesar bastante menos que el original: es lo único
        // que justifica generarla.
        #expect(thumbnail.bytes < png.count)
    }

    @Test("Las dimensiones se leen sin decodificar la imagen entera")
    func readsImageSize() throws {
        let png = try makePNG(width: 640, height: 360)
        let size = try #require(BlobStore.imageSize(of: png))
        #expect(size.width == 640)
        #expect(size.height == 360)
    }

    @Test("Un dato que no es imagen no produce miniatura")
    func rejectsNonImage() throws {
        let store = try BlobStore(root: makeTemporaryDirectory())
        #expect(throws: (any Error).self) {
            _ = try store.makeThumbnail(from: Data("no soy una imagen".utf8))
        }
    }

    @Test("La recolección borra lo no referenciado y conserva lo vivo")
    func garbageCollection() throws {
        let store = try BlobStore(root: makeTemporaryDirectory())
        let kept = try store.put(Data("vivo".utf8))
        let orphan = try store.put(Data("huérfano".utf8))

        let result = try store.garbageCollect(keeping: [kept.hash])

        #expect(result.deleted == 1)
        #expect(result.freedBytes == orphan.bytes)
        #expect(store.exists(kept.hash))
        #expect(!store.exists(orphan.hash))
    }

    @Test("El tamaño total suma lo que hay en disco")
    func totalBytes() throws {
        let store = try BlobStore(root: makeTemporaryDirectory())
        try store.put(Data(repeating: 1, count: 1000))
        try store.put(Data(repeating: 2, count: 2000))

        #expect(try store.totalBytes() == 3000)
    }

    @Test("No quedan archivos temporales tras escribir")
    func noTemporaryLeftovers() throws {
        let root = makeTemporaryDirectory()
        let store = try BlobStore(root: root)
        for index in 0..<20 {
            try store.put(Data("payload \(index)".utf8))
        }

        let leftovers = try store.allHashes().filter { $0.hasPrefix(".tmp-") }
        #expect(leftovers.isEmpty)
    }
}
