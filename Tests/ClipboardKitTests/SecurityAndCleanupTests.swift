import AppKit
import BlobStore
import Foundation
import Testing

@testable import ClipboardKit

private func makeTemporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "ambar-sec-\(UUID().uuidString)", directoryHint: .isDirectory)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func permissions(of url: URL) -> Int? {
    try? FileManager.default
        .attributesOfItem(atPath: url.path(percentEncoded: false))[.posixPermissions] as? Int
}

/// Genera una imagen por encima del tamaño de miniatura (256 px).
///
/// Por debajo de ese umbral, la miniatura sale byte a byte idéntica al original
/// y el almacén direccionado por contenido las guarda como un solo blob — que
/// es lo correcto, pero hace ambiguo el recuento de este test.
private func makeImageCapture() throws -> CapturedItem {
    let side: CGFloat = 600
    let image = NSImage(size: NSSize(width: side, height: side))
    image.lockFocus()
    NSColor.systemTeal.setFill()
    NSRect(x: 0, y: 0, width: side, height: side).fill()
    // Un degradado evita que dos capturas distintas comprimidas den el mismo
    // PNG y se dedupliquen entre sí sin querer.
    NSGradient(starting: .black, ending: .clear)?.draw(
        in: NSRect(x: 0, y: 0, width: side, height: side), angle: 45
    )
    image.unlockFocus()

    let tiff = try #require(image.tiffRepresentation)
    let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))

    return CapturedItem(
        kind: .image,
        representations: [Representation(uti: UTIs.png, blobHash: nil, inline: nil, bytes: png.count)],
        preview: "",
        searchableText: nil,
        sourceBundle: "com.test",
        sourceName: "Test",
        concealed: false,
        imageData: png,
        fingerprint: UUID().uuidString
    )
}

@Suite("Permisos del historial en disco")
struct FilePermissionTests {

    @Test("El historial no es legible por otros usuarios del sistema")
    func historyIsPrivate() throws {
        let directory = makeTemporaryDirectory()
        _ = try Store(directory: directory)

        // 0o700 / 0o600: un historial de portapapeles acumula contraseñas,
        // tokens y mensajes privados. Con los permisos de la umask por defecto
        // cualquier otra cuenta de la máquina puede leerlo entero.
        #expect(permissions(of: directory) == 0o700)

        let database = directory.appending(path: "ambar.db", directoryHint: .notDirectory)
        #expect(permissions(of: database) == 0o600)
    }

    @Test("Los ficheros auxiliares de SQLite también quedan restringidos")
    func walAndShmArePrivate() throws {
        let directory = makeTemporaryDirectory()
        let store = try Store(directory: directory)
        // Forzar escritura para que el WAL exista con contenido.
        try store.insert(
            CapturedItem(
                kind: .text,
                representations: [Representation(uti: UTIs.plainText, blobHash: nil, inline: Data("x".utf8), bytes: 1)],
                preview: "x", searchableText: "x", sourceBundle: nil, sourceName: nil,
                concealed: false, imageData: nil, fingerprint: "fp"
            )
        )

        // El `-wal` contiene páginas de datos igual que el fichero principal:
        // dejarlo abierto anularía la protección del otro.
        for suffix in ["-wal", "-shm"] {
            let url = directory.appending(path: "ambar.db\(suffix)", directoryHint: .notDirectory)
            guard FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) else { continue }
            #expect(permissions(of: url) == 0o600, "ambar.db\(suffix) quedó legible")
        }
    }

    @Test("Los binarios guardados no son legibles por otros usuarios")
    func blobsArePrivate() throws {
        let directory = makeTemporaryDirectory()
        let store = try Store(directory: directory)
        let reference = try store.blobs.put(Data("contenido privado".utf8))

        #expect(permissions(of: store.blobs.url(for: reference.hash)) == 0o600)
        #expect(permissions(of: store.blobs.root) == 0o700)
    }

    @Test("Un historial creado con permisos abiertos se corrige al abrirlo")
    func existingInstallationIsRepaired() throws {
        let directory = makeTemporaryDirectory()

        // Simula una instalación anterior al arreglo.
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path(percentEncoded: false))
        let blobs = directory.appending(path: "blobs", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: blobs, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        let stale = blobs.appending(path: "aa", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: stale, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        let staleFile = stale.appending(path: "expuesto", directoryHint: .notDirectory)
        try Data("dato viejo".utf8).write(to: staleFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: staleFile.path(percentEncoded: false))

        _ = try Store(directory: directory)

        // Actualizar la app tiene que cerrar la exposición sin que el usuario
        // haga nada; si no, el problema sobrevive indefinidamente.
        #expect(permissions(of: directory) == 0o700)
        #expect(permissions(of: blobs) == 0o700)
        #expect(permissions(of: staleFile) == 0o600)
    }
}

@Suite("Limpieza de binarios al borrar")
struct BlobCleanupTests {

    @Test("Borrar una entrada borra su imagen del disco")
    func deletingItemRemovesItsBlobs() throws {
        let store = try Store(directory: makeTemporaryDirectory())
        let ingestor = Ingestor(store: store)
        let id = try ingestor.ingest(try makeImageCapture())

        #expect(try store.blobs.allHashes().count == 2)  // original + miniatura

        try store.delete(itemID: id)

        // Si esto falla, la imagen sigue recuperable en disco después de que la
        // interfaz haya dicho que se borró.
        #expect(try store.blobs.allHashes().isEmpty)
    }

    @Test("Vaciar el historial libera el espacio de verdad")
    func clearingReleasesDiskSpace() throws {
        let store = try Store(directory: makeTemporaryDirectory())
        let ingestor = Ingestor(store: store)
        for _ in 0..<3 { try ingestor.ingest(try makeImageCapture()) }

        #expect(try store.blobs.totalBytes() > 0)

        try store.deleteAllUnpinned()

        #expect(try store.blobs.allHashes().isEmpty)
        #expect(try store.blobs.totalBytes() == 0)
    }

    @Test("Vaciar conserva los binarios de lo fijado")
    func clearingKeepsPinnedBlobs() throws {
        let store = try Store(directory: makeTemporaryDirectory())
        let ingestor = Ingestor(store: store)

        let kept = try ingestor.ingest(try makeImageCapture())
        try ingestor.ingest(try makeImageCapture())
        try store.setPinned(itemID: kept, pinned: true)

        try store.deleteAllUnpinned()

        let representations = try store.representations(for: kept)
        let hash = try #require(representations.compactMap(\.blobHash).first)
        #expect(store.blobs.exists(hash), "la recogida se llevó un binario todavía referenciado")
        #expect(try store.item(id: kept) != nil)
    }
}
