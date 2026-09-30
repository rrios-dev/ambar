import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Referencia a un binario almacenado, identificado por el hash de su contenido.
public struct BlobRef: Sendable, Hashable, Codable {
    public let hash: String
    public let bytes: Int

    public init(hash: String, bytes: Int) {
        self.hash = hash
        self.bytes = bytes
    }
}

public enum BlobStoreError: Error, Sendable {
    case notFound(String)
    case notAnImage
    case thumbnailFailed
}

/// Almacén direccionado por contenido.
///
/// Los binarios se guardan en `<root>/<hash[0..2]>/<hash>`, donde `hash` es el
/// SHA-256 del contenido en hexadecimal. De ahí salen dos propiedades que la
/// base de datos no puede dar: la deduplicación es automática (copiar diez
/// veces la misma captura escribe un solo archivo) y la escritura es
/// idempotente, así que un fallo a media escritura nunca deja un blob corrupto
/// visible — se escribe a temporal y se mueve atómicamente.
///
/// Guardar imágenes como BLOB en SQLite sería lo cómodo y lo equivocado: hincha
/// el fichero, destruye la localidad de la caché de páginas y ralentiza todas
/// las demás consultas, incluidas las que no tocan imágenes.
public final class BlobStore: Sendable {
    public let root: URL

    public init(root: URL) throws {
        self.root = root
        try FilePermissions.createDirectory(at: root)
        // Cierra la exposición de instalaciones anteriores, que se crearon con
        // los permisos permisivos de la umask.
        FilePermissions.restrictTree(at: root)
    }

    // MARK: - Rutas

    /// Dos niveles: el prefijo de dos caracteres evita directorios con decenas
    /// de miles de entradas, que degradan el rendimiento del sistema de ficheros.
    public func url(for hash: String) -> URL {
        let prefix = String(hash.prefix(2))
        return root.appending(path: prefix, directoryHint: .isDirectory)
            .appending(path: hash, directoryHint: .notDirectory)
    }

    public func exists(_ hash: String) -> Bool {
        FileManager.default.fileExists(atPath: url(for: hash).path(percentEncoded: false))
    }

    // MARK: - Escritura y lectura

    public static func hash(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Guarda el contenido y devuelve su referencia. Si ya existe un blob con
    /// el mismo hash no se reescribe: el contenido es idéntico por definición.
    @discardableResult
    public func put(_ data: Data) throws -> BlobRef {
        let digest = Self.hash(of: data)
        let destination = url(for: digest)

        if FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)) {
            return BlobRef(hash: digest, bytes: data.count)
        }

        try FilePermissions.createDirectory(at: destination.deletingLastPathComponent())

        // Temporal + move: el blob solo se hace visible cuando está completo.
        let temporary = destination.deletingLastPathComponent()
            .appending(path: ".tmp-\(UUID().uuidString)", directoryHint: .notDirectory)
        try data.write(to: temporary, options: .atomic)
        // Se restringe el temporal, no el destino: cuando el fichero aparece en
        // su ruta definitiva ya tiene que estar cerrado.
        FilePermissions.restrict(temporary)

        do {
            try FileManager.default.moveItem(at: temporary, to: destination)
        } catch {
            // Otro hilo ganó la carrera y escribió el mismo contenido. No es un
            // error: el hash garantiza que su versión es idéntica a la nuestra.
            try? FileManager.default.removeItem(at: temporary)
            guard FileManager.default.fileExists(atPath: destination.path(percentEncoded: false)) else {
                throw error
            }
        }

        return BlobRef(hash: digest, bytes: data.count)
    }

    public func data(for hash: String) throws -> Data {
        let location = url(for: hash)
        guard FileManager.default.fileExists(atPath: location.path(percentEncoded: false)) else {
            throw BlobStoreError.notFound(hash)
        }
        return try Data(contentsOf: location)
    }

    public func delete(_ hash: String) throws {
        let location = url(for: hash)
        guard FileManager.default.fileExists(atPath: location.path(percentEncoded: false)) else { return }
        try FileManager.default.removeItem(at: location)
    }

    // MARK: - Thumbnails

    /// Genera una miniatura con ImageIO, que decodifica solo lo necesario para
    /// el tamaño pedido en vez de la imagen completa. Es la diferencia entre
    /// una lista que hace scroll a 120 Hz y una que traga 40 MB por fila.
    public func makeThumbnail(from data: Data, maxPixel: Int = 256) throws -> BlobRef {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw BlobStoreError.notAnImage
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            kCGImageSourceShouldCacheImmediately: true,
        ]

        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw BlobStoreError.thumbnailFailed
        }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.png.identifier as CFString, 1, nil
        ) else {
            throw BlobStoreError.thumbnailFailed
        }
        CGImageDestinationAddImage(destination, thumbnail, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw BlobStoreError.thumbnailFailed
        }

        return try put(output as Data)
    }

    /// Dimensiones sin decodificar los píxeles: ImageIO lee solo la cabecera.
    public static func imageSize(of data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return (width, height)
    }

    // MARK: - Mantenimiento

    public func totalBytes() throws -> Int {
        var total = 0
        for url in try allBlobURLs() {
            let values = try url.resourceValues(forKeys: [.fileSizeKey])
            total += values.fileSize ?? 0
        }
        return total
    }

    public func allHashes() throws -> Set<String> {
        Set(try allBlobURLs().map { $0.lastPathComponent })
    }

    /// Borra todo blob que no esté referenciado. La base de datos es la única
    /// fuente de verdad sobre qué sigue vivo; el almacén no lleva refcounts
    /// propios porque se desincronizarían al primer crash.
    @discardableResult
    public func garbageCollect(keeping live: Set<String>) throws -> (deleted: Int, freedBytes: Int) {
        var deleted = 0
        var freed = 0
        for url in try allBlobURLs() where !live.contains(url.lastPathComponent) {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            try FileManager.default.removeItem(at: url)
            deleted += 1
            freed += size
        }
        return (deleted, freed)
    }

    private func allBlobURLs() throws -> [URL] {
        let manager = FileManager.default
        guard manager.fileExists(atPath: root.path(percentEncoded: false)) else { return [] }

        let enumerator = manager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        )

        var result: [URL] = []
        while let url = enumerator?.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            if values.isRegularFile == true { result.append(url) }
        }
        return result
    }
}
