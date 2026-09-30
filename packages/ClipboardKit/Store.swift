import BlobStore
import Foundation

/// Persistencia del historial.
///
/// Serializa todo acceso con un lock: SQLite está abierta en modo `FULLMUTEX`,
/// pero eso solo garantiza que no se corrompa, no que una operación compuesta
/// (insertar item + representaciones + índice) sea atómica frente a un lector.
public final class Store: @unchecked Sendable {
    private let database: Database
    private let lock = NSLock()
    public let blobs: BlobStore

    /// Longitud máxima del texto que se indexa por entrada. Un volcado de log
    /// de 8 MB pegado por error no debe inflar el índice ni frenar la búsqueda.
    private static let maxIndexedCharacters = 100_000

    /// Serializa el acceso a SQLite. Se usa en vez de `NSLock.withLock` porque
    /// aquel no es `@discardableResult` y llena de avisos cada operación que no
    /// devuelve valor.
    @discardableResult
    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    public init(directory: URL) throws {
        try FilePermissions.createDirectory(at: directory)

        let databaseURL = directory.appending(path: "ambar.db", directoryHint: .notDirectory)
        self.database = try Database(path: databaseURL.path(percentEncoded: false))
        self.blobs = try BlobStore(root: directory.appending(path: "blobs", directoryHint: .isDirectory))
        try migrate()

        // Después de abrir, no antes: SQLite crea `-wal` y `-shm` al conectar y
        // esos dos ficheros contienen páginas de datos igual que el principal.
        // Restringir solo `ambar.db` dejaría el contenido reciente al aire.
        FilePermissions.restrict(directory)
        for suffix in ["", "-wal", "-shm"] {
            FilePermissions.restrict(
                directory.appending(path: "ambar.db\(suffix)", directoryHint: .notDirectory)
            )
        }
    }

    // MARK: - Esquema

    private func migrate() throws {
        try locked {
            let version = try currentSchemaVersion()

            if version < 1 {
                try database.execute(Self.schemaV1)
                try database.execute("PRAGMA user_version = 1;")
            }
        }
    }

    private func currentSchemaVersion() throws -> Int {
        try database.query("PRAGMA user_version;").first.flatMap { row in
            row.int("user_version").map(Int.init)
        } ?? 0
    }

    private static let schemaV1 = """
        CREATE TABLE IF NOT EXISTS item (
            id            INTEGER PRIMARY KEY AUTOINCREMENT,
            kind          TEXT    NOT NULL,
            created_at    REAL    NOT NULL,
            last_used_at  REAL,
            use_count     INTEGER NOT NULL DEFAULT 0,
            pinned        INTEGER NOT NULL DEFAULT 0,
            source_bundle TEXT,
            source_name   TEXT,
            preview       TEXT    NOT NULL DEFAULT '',
            concealed     INTEGER NOT NULL DEFAULT 0,
            fingerprint   TEXT    NOT NULL
        );

        CREATE INDEX IF NOT EXISTS item_created_idx     ON item(created_at DESC);
        CREATE INDEX IF NOT EXISTS item_pinned_idx      ON item(pinned, created_at DESC);
        CREATE INDEX IF NOT EXISTS item_kind_idx        ON item(kind, created_at DESC);
        CREATE INDEX IF NOT EXISTS item_fingerprint_idx ON item(fingerprint);
        CREATE INDEX IF NOT EXISTS item_bundle_idx      ON item(source_bundle);

        CREATE TABLE IF NOT EXISTS representation (
            item_id   INTEGER NOT NULL REFERENCES item(id) ON DELETE CASCADE,
            uti       TEXT    NOT NULL,
            blob_hash TEXT,
            inline    BLOB,
            bytes     INTEGER NOT NULL DEFAULT 0
        );

        CREATE INDEX IF NOT EXISTS representation_item_idx ON representation(item_id);
        CREATE INDEX IF NOT EXISTS representation_blob_idx ON representation(blob_hash);

        CREATE TABLE IF NOT EXISTS image_meta (
            item_id    INTEGER PRIMARY KEY REFERENCES item(id) ON DELETE CASCADE,
            width      INTEGER NOT NULL DEFAULT 0,
            height     INTEGER NOT NULL DEFAULT 0,
            thumb_hash TEXT,
            ocr_text   TEXT,
            ocr_state  TEXT    NOT NULL DEFAULT 'pending'
        );

        CREATE INDEX IF NOT EXISTS image_ocr_state_idx ON image_meta(ocr_state);

        -- remove_diacritics 2 es obligatorio para el español: sin él, buscar
        -- "cancion" no encuentra "canción" y el usuario concluye, con razón,
        -- que la búsqueda no funciona.
        CREATE VIRTUAL TABLE IF NOT EXISTS item_fts USING fts5(
            body,
            source_name,
            tokenize = 'unicode61 remove_diacritics 2'
        );
        """

    // MARK: - Escritura

    /// Persiste una captura y devuelve el identificador de la entrada.
    ///
    /// Si el contenido coincide con una entrada existente no se duplica: se
    /// sube la que ya había. Copiar dos veces lo mismo es el gesto más común
    /// del portapapeles y llenar el historial de repeticiones lo inutiliza.
    @discardableResult
    public func insert(_ captured: CapturedItem, now: Date = Date()) throws -> Int64 {
        try locked {
            if let existing = try findByFingerprint(captured.fingerprint) {
                try database.run(
                    "UPDATE item SET created_at = ?, source_bundle = ?, source_name = ? WHERE id = ?;",
                    [
                        .real(now.timeIntervalSince1970),
                        .optionalText(captured.sourceBundle),
                        .optionalText(captured.sourceName),
                        .integer(existing),
                    ]
                )
                return existing
            }

            return try database.transaction {
                let itemID = try database.run(
                    """
                    INSERT INTO item
                        (kind, created_at, use_count, pinned, source_bundle, source_name,
                         preview, concealed, fingerprint)
                    VALUES (?, ?, 0, 0, ?, ?, ?, ?, ?);
                    """,
                    [
                        .text(captured.kind.rawValue),
                        .real(now.timeIntervalSince1970),
                        .optionalText(captured.sourceBundle),
                        .optionalText(captured.sourceName),
                        .text(captured.preview),
                        .bool(captured.concealed),
                        .text(captured.fingerprint),
                    ]
                )

                for representation in captured.representations {
                    try database.run(
                        "INSERT INTO representation (item_id, uti, blob_hash, inline, bytes) VALUES (?, ?, ?, ?, ?);",
                        [
                            .integer(itemID),
                            .text(representation.uti),
                            .optionalText(representation.blobHash),
                            representation.inline.map { SQLValue.blob($0) } ?? .null,
                            .integer(Int64(representation.bytes)),
                        ]
                    )
                }

                let body = Self.clampIndexed(captured.searchableText ?? captured.preview)
                try database.run(
                    "INSERT INTO item_fts (rowid, body, source_name) VALUES (?, ?, ?);",
                    [.integer(itemID), .text(body), .optionalText(captured.sourceName)]
                )

                return itemID
            }
        }
    }

    public func attachImageMeta(
        itemID: Int64,
        width: Int,
        height: Int,
        thumbnailHash: String?,
        ocrState: ImageMeta.OCRState = .pending
    ) throws {
        try locked {
            try database.run(
                """
                INSERT INTO image_meta (item_id, width, height, thumb_hash, ocr_state)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(item_id) DO UPDATE SET
                    width = excluded.width,
                    height = excluded.height,
                    thumb_hash = excluded.thumb_hash,
                    ocr_state = excluded.ocr_state;
                """,
                [
                    .integer(itemID),
                    .integer(Int64(width)),
                    .integer(Int64(height)),
                    .optionalText(thumbnailHash),
                    .text(ocrState.rawValue),
                ]
            )
        }
    }

    /// Vuelca el resultado del reconocimiento de texto y lo hace buscable.
    public func setOCRResult(itemID: Int64, text: String?, state: ImageMeta.OCRState) throws {
        try locked {
            try database.transaction {
                try database.run(
                    "UPDATE image_meta SET ocr_text = ?, ocr_state = ? WHERE item_id = ?;",
                    [.optionalText(text), .text(state.rawValue), .integer(itemID)]
                )

                guard let text, !text.isEmpty else { return }

                // El índice se reescribe entero para esta fila: FTS5 no tiene
                // actualización parcial de columna y el texto reconocido debe
                // convivir con el preview que ya estaba indexado.
                let previous = try database.query(
                    "SELECT preview FROM item WHERE id = ?;", [.integer(itemID)]
                ).first?.string("preview") ?? ""

                let combined = Self.clampIndexed(previous.isEmpty ? text : previous + "\n" + text)
                try database.run("DELETE FROM item_fts WHERE rowid = ?;", [.integer(itemID)])
                try database.run(
                    "INSERT INTO item_fts (rowid, body, source_name) VALUES (?, ?, (SELECT source_name FROM item WHERE id = ?));",
                    [.integer(itemID), .text(combined), .integer(itemID)]
                )
            }
        }
    }

    /// Anota que la entrada se ha usado y la **sube al primer puesto**.
    ///
    /// Usar una entrada del historial es volver a copiarla: el contenido acaba en el
    /// portapapeles igual que si se hubiera copiado de su app de origen, así que la lista
    /// tiene que contarlo igual. Y lo que ordena la lista es `created_at` —ver
    /// `items(matching:limit:)`—, no `last_used_at`: sin reescribirlo se subía el contador
    /// y la entrada se quedaba donde estaba, enterrándose bajo todo lo copiado después
    /// justamente cuando acaba de demostrar que hace falta.
    ///
    /// Es la misma reescritura que hace `insert` al reconocer una huella repetida, y por eso
    /// no hay dos comportamientos que explicar: recopiar a mano y pegar desde el historial
    /// dejan el mismo resultado.
    ///
    /// Efecto de esto, querido: la entrada deja de ser candidata a la purga por antigüedad
    /// —`applyRetention` borra por `created_at`—. Usar algo lo mantiene vivo.
    public func markUsed(itemID: Int64, now: Date = Date()) throws {
        try locked {
            try database.run(
                """
                UPDATE item
                SET use_count = use_count + 1, last_used_at = ?, created_at = ?
                WHERE id = ?;
                """,
                [
                    .real(now.timeIntervalSince1970),
                    .real(now.timeIntervalSince1970),
                    .integer(itemID),
                ]
            )
        }
    }

    public func setPinned(itemID: Int64, pinned: Bool) throws {
        try locked {
            try database.run(
                "UPDATE item SET pinned = ? WHERE id = ?;",
                [.bool(pinned), .integer(itemID)]
            )
        }
    }

    public func delete(itemID: Int64) throws {
        try locked {
            try database.transaction {
                try database.run("DELETE FROM item_fts WHERE rowid = ?;", [.integer(itemID)])
                try database.run("DELETE FROM item WHERE id = ?;", [.integer(itemID)])
            }
            // Los binarios se borran en el acto, no en la siguiente purga.
            // Borrar una entrada y que su imagen siga en disco convierte una
            // acción de privacidad en una promesa incumplida.
            try collectOrphanBlobsLocked()
        }
    }

    /// Borra todo salvo lo fijado, que es justamente lo que el usuario ha
    /// declarado que quiere conservar.
    public func deleteAllUnpinned() throws {
        try locked {
            try database.transaction {
                try database.run("DELETE FROM item_fts WHERE rowid IN (SELECT id FROM item WHERE pinned = 0);")
                try database.run("DELETE FROM item WHERE pinned = 0;")
            }
            try collectOrphanBlobsLocked()
        }
    }

    /// Borra los binarios que ya no referencia ninguna entrada.
    ///
    /// Debe llamarse desde dentro del lock; la base es la única fuente de
    /// verdad sobre qué sigue vivo.
    @discardableResult
    private func collectOrphanBlobsLocked() throws -> (deleted: Int, freedBytes: Int) {
        try blobs.garbageCollect(keeping: try liveBlobHashesLocked())
    }

    // MARK: - Lectura

    public func items(matching query: SearchQuery, limit: Int = 200) throws -> [ClipboardItem] {
        try locked {
            var conditions: [String] = []
            var parameters: [SQLValue] = []
            var joins = ""
            var ordering = "item.pinned DESC, item.created_at DESC"

            if let expression = query.ftsExpression {
                joins = "JOIN item_fts ON item_fts.rowid = item.id"
                conditions.append("item_fts MATCH ?")
                parameters.append(.text(expression))
                // El relevance ranking manda dentro de los fijados y fuera de
                // ellos por separado: un pin siempre encabeza su grupo.
                ordering = "item.pinned DESC, bm25(item_fts) ASC, item.created_at DESC"
            }

            if !query.kinds.isEmpty {
                let placeholders = query.kinds.map { _ in "?" }.joined(separator: ", ")
                conditions.append("item.kind IN (\(placeholders))")
                parameters.append(contentsOf: query.kinds.map { .text($0.rawValue) })
            }

            if let app = query.app, !app.isEmpty {
                conditions.append("(LOWER(item.source_bundle) LIKE ? OR LOWER(item.source_name) LIKE ?)")
                parameters.append(.text("%\(app.lowercased())%"))
                parameters.append(.text("%\(app.lowercased())%"))
            }

            if query.pinnedOnly {
                conditions.append("item.pinned = 1")
            }

            let whereClause = conditions.isEmpty ? "" : "WHERE " + conditions.joined(separator: " AND ")
            parameters.append(.integer(Int64(limit)))

            let sql = """
                SELECT item.*, image_meta.width, image_meta.height, image_meta.thumb_hash,
                       image_meta.ocr_text, image_meta.ocr_state
                FROM item
                \(joins)
                LEFT JOIN image_meta ON image_meta.item_id = item.id
                \(whereClause)
                ORDER BY \(ordering)
                LIMIT ?;
                """

            return try database.query(sql, parameters).map(Self.decodeItem)
        }
    }

    public func item(id: Int64) throws -> ClipboardItem? {
        try locked {
            try database.query(
                """
                SELECT item.*, image_meta.width, image_meta.height, image_meta.thumb_hash,
                       image_meta.ocr_text, image_meta.ocr_state
                FROM item
                LEFT JOIN image_meta ON image_meta.item_id = item.id
                WHERE item.id = ?;
                """,
                [.integer(id)]
            ).first.map(Self.decodeItem)
        }
    }

    public func representations(for itemID: Int64) throws -> [Representation] {
        try locked {
            try database.query(
                "SELECT uti, blob_hash, inline, bytes FROM representation WHERE item_id = ?;",
                [.integer(itemID)]
            ).map { row in
                Representation(
                    uti: row.string("uti") ?? "",
                    blobHash: row.string("blob_hash"),
                    inline: row.data("inline"),
                    bytes: Int(row.int("bytes") ?? 0)
                )
            }
        }
    }

    public func count() throws -> Int {
        try locked {
            Int(try database.query("SELECT COUNT(*) AS value FROM item;").first?.int("value") ?? 0)
        }
    }

    /// Imágenes cuyo reconocimiento quedó a medias. Se consulta al arrancar
    /// para reanudar en vez de perder el trabajo pendiente.
    public func pendingOCRItems(limit: Int = 50) throws -> [Int64] {
        try locked {
            try database.query(
                "SELECT item_id FROM image_meta WHERE ocr_state = 'pending' ORDER BY item_id DESC LIMIT ?;",
                [.integer(Int64(limit))]
            ).compactMap { $0.int("item_id") }
        }
    }

    // MARK: - Retención

    /// Aplica la política y devuelve cuántas entradas se borraron.
    ///
    /// Las fijadas quedan siempre exentas, incluidas las que superarían el tope
    /// de disco: el usuario las marcó explícitamente y una purga automática que
    /// las tocara sería una pérdida de datos, no una limpieza.
    @discardableResult
    public func applyRetention(policy: RetentionPolicy, now: Date = Date()) throws -> RetentionResult {
        try locked {
            var removed = 0

            if let maximumAge = policy.maximumAge {
                let cutoff = now.addingTimeInterval(-maximumAge).timeIntervalSince1970
                let doomed = try database.query(
                    "SELECT id FROM item WHERE pinned = 0 AND created_at < ?;", [.real(cutoff)]
                ).compactMap { $0.int("id") }
                removed += try deleteLocked(ids: doomed)
            }

            if let maximumCount = policy.maximumCount {
                let doomed = try database.query(
                    """
                    SELECT id FROM item WHERE pinned = 0
                    ORDER BY created_at DESC LIMIT -1 OFFSET ?;
                    """,
                    [.integer(Int64(maximumCount))]
                ).compactMap { $0.int("id") }
                removed += try deleteLocked(ids: doomed)
            }

            // El tope de disco se evalúa después de las otras dos reglas, para
            // no borrar por tamaño lo que la antigüedad ya iba a llevarse.
            if let maximumBytes = policy.maximumBytes {
                var total = try blobs.totalBytes()
                if total > maximumBytes {
                    let candidates = try database.query(
                        """
                        SELECT item.id AS id, COALESCE(SUM(representation.bytes), 0) AS weight
                        FROM item
                        LEFT JOIN representation ON representation.item_id = item.id
                        WHERE item.pinned = 0
                        GROUP BY item.id
                        ORDER BY item.created_at ASC;
                        """
                    )
                    var doomed: [Int64] = []
                    for row in candidates where total > maximumBytes {
                        guard let id = row.int("id") else { continue }
                        doomed.append(id)
                        total -= Int(row.int("weight") ?? 0)
                    }
                    removed += try deleteLocked(ids: doomed)
                }
            }

            let live = try liveBlobHashesLocked()
            let collected = try blobs.garbageCollect(keeping: live)

            return RetentionResult(
                deletedItems: removed,
                deletedBlobs: collected.deleted,
                freedBytes: collected.freedBytes
            )
        }
    }

    private func deleteLocked(ids: [Int64]) throws -> Int {
        guard !ids.isEmpty else { return 0 }
        try database.transaction {
            for id in ids {
                try database.run("DELETE FROM item_fts WHERE rowid = ?;", [.integer(id)])
                try database.run("DELETE FROM item WHERE id = ?;", [.integer(id)])
            }
        }
        return ids.count
    }

    private func liveBlobHashesLocked() throws -> Set<String> {
        var hashes = Set<String>()
        for row in try database.query("SELECT DISTINCT blob_hash FROM representation WHERE blob_hash IS NOT NULL;") {
            if let hash = row.string("blob_hash") { hashes.insert(hash) }
        }
        for row in try database.query("SELECT DISTINCT thumb_hash FROM image_meta WHERE thumb_hash IS NOT NULL;") {
            if let hash = row.string("thumb_hash") { hashes.insert(hash) }
        }
        return hashes
    }

    // MARK: - Apoyo

    private func findByFingerprint(_ fingerprint: String) throws -> Int64? {
        try database.query(
            "SELECT id FROM item WHERE fingerprint = ? AND pinned = 0 ORDER BY created_at DESC LIMIT 1;",
            [.text(fingerprint)]
        ).first?.int("id")
    }

    private static func clampIndexed(_ text: String) -> String {
        text.count <= maxIndexedCharacters ? text : String(text.prefix(maxIndexedCharacters))
    }

    private static func decodeItem(_ row: Row) -> ClipboardItem {
        let imageMeta: ImageMeta? = {
            guard let width = row.int("width"), let height = row.int("height") else { return nil }
            return ImageMeta(
                width: Int(width),
                height: Int(height),
                thumbnailHash: row.string("thumb_hash"),
                ocrText: row.string("ocr_text"),
                ocrState: ImageMeta.OCRState(rawValue: row.string("ocr_state") ?? "pending") ?? .pending
            )
        }()

        return ClipboardItem(
            id: row.int("id") ?? 0,
            kind: ItemKind(rawValue: row.string("kind") ?? "text") ?? .text,
            createdAt: Date(timeIntervalSince1970: row.double("created_at") ?? 0),
            lastUsedAt: row.double("last_used_at").map { Date(timeIntervalSince1970: $0) },
            useCount: Int(row.int("use_count") ?? 0),
            pinned: row.bool("pinned"),
            sourceBundle: row.string("source_bundle"),
            sourceName: row.string("source_name"),
            preview: row.string("preview") ?? "",
            concealed: row.bool("concealed"),
            imageMeta: imageMeta
        )
    }
}

/// Política de conservación del historial.
public struct RetentionPolicy: Sendable, Equatable, Codable {
    public var maximumAge: TimeInterval?
    public var maximumBytes: Int?
    public var maximumCount: Int?

    public init(maximumAge: TimeInterval? = nil, maximumBytes: Int? = nil, maximumCount: Int? = nil) {
        self.maximumAge = maximumAge
        self.maximumBytes = maximumBytes
        self.maximumCount = maximumCount
    }

    /// 30 días y 2 GB de binarios. Los fijados quedan fuera de ambos límites.
    public static let standard = RetentionPolicy(
        maximumAge: 30 * 24 * 60 * 60,
        maximumBytes: 2 * 1024 * 1024 * 1024,
        maximumCount: nil
    )
}

public struct RetentionResult: Sendable, Equatable {
    public let deletedItems: Int
    public let deletedBlobs: Int
    public let freedBytes: Int
}
