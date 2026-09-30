import BlobStore
import Foundation
import Testing

@testable import ClipboardKit

/// Directorio temporal aislado por test.
private func makeTemporaryDirectory() -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "ambar-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func makeItem(
    text: String,
    kind: ItemKind = .text,
    source: String? = "TestApp"
) -> CapturedItem {
    CapturedItem(
        kind: kind,
        representations: [
            Representation(
                uti: UTIs.plainText,
                blobHash: nil,
                inline: Data(text.utf8),
                bytes: text.utf8.count
            )
        ],
        preview: text,
        searchableText: text,
        sourceBundle: "com.test.app",
        sourceName: source,
        concealed: false,
        imageData: nil,
        fingerprint: BlobStore.hash(of: Data(text.utf8))
    )
}

@Suite("Store — persistencia")
struct StoreTests {

    @Test("El texto sobrevive intacto al viaje de ida y vuelta, tildes incluidas")
    func roundTripPreservesUnicode() throws {
        let store = try Store(directory: makeTemporaryDirectory())
        let original = "Ámbar: canción con tildes ÑÁÉÍÓÚ y emoji 🟠"

        let id = try store.insert(makeItem(text: original))
        let recovered = try store.item(id: id)

        #expect(recovered?.preview == original)

        // Además de la igualdad de cadenas se comprueban los bytes: una doble
        // codificación (UTF-8 releído como MacRoman) produce una cadena que
        // parece distinta pero que ciertas comparaciones podrían dar por buena.
        let bytes = Array(recovered!.preview.utf8.prefix(2))
        #expect(bytes == [0xC3, 0x81], "Á debe seguir siendo C3 81 en UTF-8")
    }

    @Test("Buscar sin tildes encuentra el texto acentuado")
    func searchIgnoresDiacritics() throws {
        let store = try Store(directory: makeTemporaryDirectory())
        try store.insert(makeItem(text: "La canción del verano"))

        let results = try store.items(matching: SearchQuery.parse("cancion"))
        #expect(results.count == 1)
    }

    @Test("Buscar con tildes también encuentra el texto acentuado")
    func searchWithDiacritics() throws {
        let store = try Store(directory: makeTemporaryDirectory())
        try store.insert(makeItem(text: "La canción del verano"))

        let results = try store.items(matching: SearchQuery.parse("canción"))
        #expect(results.count == 1)
    }

    @Test("La búsqueda filtra por prefijo mientras se teclea")
    func searchMatchesPrefix() throws {
        let store = try Store(directory: makeTemporaryDirectory())
        try store.insert(makeItem(text: "factura de septiembre"))

        #expect(try store.items(matching: SearchQuery.parse("fac")).count == 1)
        #expect(try store.items(matching: SearchQuery.parse("sept")).count == 1)
        #expect(try store.items(matching: SearchQuery.parse("zzz")).isEmpty)
    }

    @Test("Copiar dos veces lo mismo no duplica la entrada")
    func duplicatesAreCollapsed() throws {
        let store = try Store(directory: makeTemporaryDirectory())
        let first = try store.insert(makeItem(text: "repetido"))
        let second = try store.insert(makeItem(text: "repetido"))

        #expect(first == second)
        #expect(try store.count() == 1)
    }

    @Test("Repetir un contenido lo sube al principio de la lista")
    func duplicateMovesToTop() throws {
        let store = try Store(directory: makeTemporaryDirectory())
        let base = Date(timeIntervalSince1970: 1_000_000)

        let old = try store.insert(makeItem(text: "antiguo"), now: base)
        try store.insert(makeItem(text: "reciente"), now: base.addingTimeInterval(10))
        try store.insert(makeItem(text: "antiguo"), now: base.addingTimeInterval(20))

        let items = try store.items(matching: .empty)
        #expect(items.first?.id == old)
    }

    @Test("Los fijados encabezan la lista aunque sean viejos")
    func pinnedItemsComeFirst() throws {
        let store = try Store(directory: makeTemporaryDirectory())
        let base = Date(timeIntervalSince1970: 1_000_000)

        let old = try store.insert(makeItem(text: "viejo pero fijado"), now: base)
        try store.insert(makeItem(text: "nuevo"), now: base.addingTimeInterval(100))
        try store.setPinned(itemID: old, pinned: true)

        let items = try store.items(matching: .empty)
        #expect(items.first?.id == old)
        #expect(items.first?.pinned == true)
    }

    @Test("Vaciar el historial respeta los fijados")
    func clearKeepsPinned() throws {
        let store = try Store(directory: makeTemporaryDirectory())
        let kept = try store.insert(makeItem(text: "importante"))
        try store.insert(makeItem(text: "prescindible"))
        try store.setPinned(itemID: kept, pinned: true)

        try store.deleteAllUnpinned()

        let items = try store.items(matching: .empty)
        #expect(items.count == 1)
        #expect(items.first?.id == kept)
    }

    @Test("Borrar una entrada la saca también del índice de búsqueda")
    func deleteRemovesFromIndex() throws {
        let store = try Store(directory: makeTemporaryDirectory())
        let id = try store.insert(makeItem(text: "efímero"))

        try store.delete(itemID: id)

        #expect(try store.items(matching: SearchQuery.parse("efimero")).isEmpty)
        #expect(try store.count() == 0)
    }

    @Test("El filtro por tipo acota los resultados")
    func filterByKind() throws {
        let store = try Store(directory: makeTemporaryDirectory())
        try store.insert(makeItem(text: "un texto"))
        try store.insert(makeItem(text: "documento.pdf", kind: .file))

        let files = try store.items(matching: SearchQuery.parse("file:"))
        #expect(files.count == 1)
        #expect(files.first?.kind == .file)
    }

    @Test("El filtro por app acota los resultados")
    func filterByApp() throws {
        let store = try Store(directory: makeTemporaryDirectory())
        try store.insert(makeItem(text: "desde safari", source: "Safari"))
        try store.insert(makeItem(text: "desde notas", source: "Notas"))

        let results = try store.items(matching: SearchQuery.parse("app:safari"))
        #expect(results.count == 1)
        #expect(results.first?.sourceName == "Safari")
    }

    @Test("Un texto enorme no rompe la inserción ni el índice")
    func hugeTextIsClamped() throws {
        let store = try Store(directory: makeTemporaryDirectory())
        let huge = String(repeating: "log ", count: 200_000)  // ~800 000 caracteres

        let id = try store.insert(makeItem(text: huge))
        #expect(try store.item(id: id) != nil)
        #expect(try store.items(matching: SearchQuery.parse("log")).count == 1)
    }
}

@Suite("Retención")
struct RetentionTests {

    @Test("Se borra lo más antiguo que el límite de días")
    func expiresByAge() throws {
        let store = try Store(directory: makeTemporaryDirectory())
        let now = Date()

        try store.insert(makeItem(text: "de hace mucho"), now: now.addingTimeInterval(-40 * 86_400))
        try store.insert(makeItem(text: "de ayer"), now: now.addingTimeInterval(-86_400))

        let result = try store.applyRetention(
            policy: RetentionPolicy(maximumAge: 30 * 86_400),
            now: now
        )

        #expect(result.deletedItems == 1)
        #expect(try store.count() == 1)
    }

    @Test("La purga por antigüedad nunca toca lo fijado")
    func pinnedSurvivesExpiry() throws {
        let store = try Store(directory: makeTemporaryDirectory())
        let now = Date()

        let old = try store.insert(makeItem(text: "viejo"), now: now.addingTimeInterval(-400 * 86_400))
        try store.setPinned(itemID: old, pinned: true)

        let result = try store.applyRetention(
            policy: RetentionPolicy(maximumAge: 30 * 86_400),
            now: now
        )

        #expect(result.deletedItems == 0)
        #expect(try store.count() == 1)
    }

    @Test("El límite por número conserva las entradas más recientes")
    func expiresByCount() throws {
        let store = try Store(directory: makeTemporaryDirectory())
        let base = Date(timeIntervalSince1970: 1_000_000)

        for index in 0..<10 {
            try store.insert(
                makeItem(text: "entrada \(index)"),
                now: base.addingTimeInterval(Double(index))
            )
        }

        try store.applyRetention(policy: RetentionPolicy(maximumCount: 4))

        let items = try store.items(matching: .empty)
        #expect(items.count == 4)
        #expect(items.first?.preview == "entrada 9")
    }

    // MARK: - Usar una entrada

    @Test("Usar una entrada la sube al primer puesto, como si se hubiera recopiado")
    func usingPromotesToTop() throws {
        let store = try Store(directory: makeTemporaryDirectory())
        let base = Date(timeIntervalSince1970: 1_000_000)

        let first = try store.insert(makeItem(text: "la primera"), now: base)
        try store.insert(makeItem(text: "la segunda"), now: base.addingTimeInterval(10))
        try store.insert(makeItem(text: "la tercera"), now: base.addingTimeInterval(20))

        #expect(try store.items(matching: .empty).map(\.preview) == ["la tercera", "la segunda", "la primera"])

        try store.markUsed(itemID: first, now: base.addingTimeInterval(30))

        // Pegar del historial es volver a copiar: si no sube, lo último que se pegó queda
        // enterrado bajo todo lo copiado después, que es justo cuando más falta hace.
        #expect(try store.items(matching: .empty).map(\.preview) == ["la primera", "la tercera", "la segunda"])
    }

    @Test("Usar una entrada sigue contando los usos")
    func usingStillCountsUses() throws {
        let store = try Store(directory: makeTemporaryDirectory())
        let id = try store.insert(makeItem(text: "contada"))
        let used = Date(timeIntervalSince1970: 2_000_000)

        try store.markUsed(itemID: id, now: used)
        try store.markUsed(itemID: id, now: used.addingTimeInterval(5))

        let item = try store.item(id: id)
        #expect(item?.useCount == 2)
        #expect(item?.lastUsedAt == used.addingTimeInterval(5))
    }

    @Test("Usar una entrada la salva de la purga por número")
    func usingSavesFromRetention() throws {
        let store = try Store(directory: makeTemporaryDirectory())
        let base = Date(timeIntervalSince1970: 1_000_000)

        let oldest = try store.insert(makeItem(text: "la vieja"), now: base)
        for index in 1..<6 {
            try store.insert(makeItem(text: "entrada \(index)"), now: base.addingTimeInterval(Double(index)))
        }

        try store.markUsed(itemID: oldest, now: base.addingTimeInterval(100))
        try store.applyRetention(policy: RetentionPolicy(maximumCount: 3))

        // Consecuencia de subir por `created_at`, y querida: lo que se usa se mantiene vivo.
        #expect(try store.item(id: oldest) != nil)
        #expect(try store.items(matching: .empty).first?.preview == "la vieja")
    }
}
