import BlobStore
import Foundation

/// Lleva una captura desde el portapapeles hasta el disco y la base de datos.
///
/// Es el único punto que escribe binarios: el lector se limita a extraer y el
/// store a persistir metadatos. Concentrarlo aquí es lo que permite que la
/// política de qué va inline y qué va a disco sea una sola decisión.
public struct Ingestor: Sendable {
    private let store: Store

    public init(store: Store) {
        self.store = store
    }

    /// Persiste la captura y devuelve el identificador de la entrada creada
    /// (o de la que ya existía, si el contenido se repite).
    @discardableResult
    public func ingest(_ captured: CapturedItem, now: Date = Date()) throws -> Int64 {
        var stored = captured
        var imageBlob: BlobRef?

        // Las representaciones que superan el umbral llegan del lector con el
        // hash ya calculado y el contenido todavía en memoria: aquí se vuelca
        // a disco y se suelta el buffer.
        stored.representations = try captured.representations.map { representation in
            guard representation.blobHash != nil, let payload = representation.inline else {
                return representation
            }
            let reference = try store.blobs.put(payload)
            return Representation(
                uti: representation.uti,
                blobHash: reference.hash,
                inline: nil,
                bytes: reference.bytes
            )
        }

        if let imageData = captured.imageData {
            let reference = try store.blobs.put(imageData)
            imageBlob = reference
            stored.representations = [
                Representation(
                    uti: captured.representations.first?.uti ?? UTIs.png,
                    blobHash: reference.hash,
                    inline: nil,
                    bytes: reference.bytes
                )
            ]
        }

        let itemID = try store.insert(stored, now: now)

        if let imageData = captured.imageData, imageBlob != nil {
            let size = BlobStore.imageSize(of: imageData)
            // Un fallo generando la miniatura no puede tumbar la captura: el
            // item se guarda igual y la lista cae al icono genérico.
            let thumbnail = try? store.blobs.makeThumbnail(from: imageData)
            try store.attachImageMeta(
                itemID: itemID,
                width: size?.width ?? 0,
                height: size?.height ?? 0,
                thumbnailHash: thumbnail?.hash,
                ocrState: .pending
            )
        }

        return itemID
    }
}
