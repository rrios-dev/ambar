import Foundation
import Vision

/// Reconocimiento de texto en las imágenes copiadas.
///
/// Es lo que convierte el historial de imágenes en algo buscable: se copia una
/// captura de una factura y semanas después se encuentra escribiendo
/// "factura", sin haberla etiquetado. Todo ocurre en el dispositivo — Vision no
/// sale a la red — así que no hay que decidir nada sobre privacidad.
///
/// Usa la API Swift de Vision (`RecognizeTextRequest`), no la heredada de Objective-C
/// (`VNRecognizeTextRequest`). No es cosmética: la vieja obliga a un
/// `withCheckedThrowingContinuation` sobre un `DispatchQueue.global`, porque `perform` es
/// síncrona y bloqueante. Ese puente lo escribe uno a mano y es donde se cuelan los fallos
/// de concurrencia — una continuación que se reanuda dos veces revienta el proceso, y una
/// que no se reanuda nunca deja la cola de OCR colgada para siempre. La API nueva es
/// `async` de nacimiento y trabaja con structs `Sendable`, así que ese puente desaparece
/// en vez de quedar bien escrito.
public struct TextRecognizer: Sendable {
    /// Idiomas que se intentan reconocer, en orden de preferencia.
    ///
    /// `Locale.Language` en vez de `String`: es lo que pide la API nueva, y de paso quita
    /// la ambigüedad de si «es» y «es-ES» son lo mismo, que la versión anterior resolvía
    /// comparando prefijos de dos caracteres a mano.
    public var languages: [Locale.Language]
    /// `accurate` cuesta unas décimas de segundo más que `fast` y acierta
    /// bastante más en capturas de pantalla con texto pequeño, que es
    /// justamente el caso de uso.
    public var level: RecognizeTextRequest.RecognitionLevel

    public init(
        languages: [Locale.Language] = TextRecognizer.systemPreferredLanguages(),
        level: RecognizeTextRequest.RecognitionLevel = .accurate
    ) {
        self.languages = languages
        self.level = level
    }

    /// Comodidad para quien tiene etiquetas sueltas («es-ES», «en-US»), sobre todo tests.
    public init(languages: [String], level: RecognizeTextRequest.RecognitionLevel = .accurate) {
        self.init(languages: languages.map(Locale.Language.init(identifier:)), level: level)
    }

    /// Idiomas de reconocimiento derivados de las preferencias del usuario.
    ///
    /// Fijarlos a español e inglés dejaba la función estrella inservible para
    /// cualquier otro idioma: la interfaz aparecía traducida al japonés, pero
    /// el texto de las capturas japonesas no se reconocía y la búsqueda dentro
    /// de imágenes no encontraba nada.
    ///
    /// Se cruzan los idiomas preferidos con los que Vision admite de verdad
    /// —la lista depende de la versión del sistema— y se deja inglés como
    /// respaldo, porque aparece en interfaces y capturas de casi cualquier
    /// procedencia.
    public static func systemPreferredLanguages(limit: Int = 3) -> [Locale.Language] {
        // `supportedRecognitionLanguages` de la API nueva es una propiedad, no una función
        // que lance: desaparece el `try?` que antes podía tragarse el motivo de una lista
        // vacía sin dejar rastro.
        let supported = RecognizeTextRequest().supportedRecognitionLanguages

        var chosen: [Locale.Language] = []
        for preferred in Locale.preferredLanguages {
            let language = Locale.Language(identifier: preferred)
            // La comparación por código ISO la hace el propio tipo, en vez del prefijo de
            // dos caracteres que se recortaba a mano: «es-ES» y «es» casan sin trampas, y
            // «zh-Hans» deja de confundirse con cualquier otra cosa que empiece por «zh».
            let match = supported.first { $0 == language }
                ?? supported.first { $0.languageCode == language.languageCode }
            if let match, !chosen.contains(match) {
                chosen.append(match)
            }
            if chosen.count >= limit { break }
        }

        for fallback in ["en-US", "en"] {
            let language = Locale.Language(identifier: fallback)
            if !chosen.contains(language), supported.contains(language) {
                chosen.append(language)
                break
            }
        }

        // Si Vision no devolvió nada utilizable, es mejor pedir inglés que
        // pasar una lista vacía y dejar que decida por su cuenta.
        return chosen.isEmpty ? [Locale.Language(identifier: "en-US")] : chosen
    }

    public enum RecognitionError: Error, Sendable {
        case invalidImage
    }

    /// Devuelve el texto reconocido, o cadena vacía si la imagen no tiene.
    ///
    /// Ya no hace falta saltar a una cola de fondo a mano: la petición es `async` y Vision
    /// hace su trabajo fuera del llamante. Lo que antes protegía el `DispatchQueue.global`
    /// —que una captura a pantalla completa no bloqueara la captura del portapapeles— lo
    /// da ahora el propio `await`.
    public func recognize(imageData: Data) async throws -> String {
        var request = RecognizeTextRequest()
        request.recognitionLevel = level
        request.recognitionLanguages = languages
        request.usesLanguageCorrection = true

        let observations = try await request.perform(on: imageData)
        let lines = observations.compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: "\n")
    }
}

/// Procesa en segundo plano la cola de imágenes pendientes de reconocer.
///
/// El estado vive en la base de datos (`ocr_state`), no en memoria: si la app
/// se cierra con cuarenta capturas a medias, al arrancar retoma exactamente
/// donde lo dejó en vez de perderlas o rehacerlas todas.
public actor OCRQueue {
    private let store: Store
    private let recognizer: TextRecognizer
    private var isRunning = false
    private var pending: [Int64] = []

    public init(store: Store, recognizer: TextRecognizer = TextRecognizer()) {
        self.store = store
        self.recognizer = recognizer
    }

    public func enqueue(itemID: Int64) {
        pending.append(itemID)
        Task { await drain() }
    }

    /// Recupera de la base de datos lo que quedó pendiente de una ejecución
    /// anterior. Se llama al arrancar.
    public func resumePendingWork() {
        guard let ids = try? store.pendingOCRItems() else { return }
        pending.append(contentsOf: ids)
        Task { await drain() }
    }

    private func drain() async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false }

        while !pending.isEmpty {
            let itemID = pending.removeFirst()
            await process(itemID: itemID)
        }
    }

    private func process(itemID: Int64) async {
        guard let representations = try? store.representations(for: itemID),
              let hash = representations.compactMap(\.blobHash).first,
              let data = try? store.blobs.data(for: hash)
        else {
            try? store.setOCRResult(itemID: itemID, text: nil, state: .failed)
            return
        }

        do {
            let text = try await recognizer.recognize(imageData: data)
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            // Una imagen sin texto no es un fallo: se marca como omitida para
            // no volver a intentarlo en cada arranque.
            try store.setOCRResult(
                itemID: itemID,
                text: trimmed.isEmpty ? nil : trimmed,
                state: trimmed.isEmpty ? .skipped : .done
            )
        } catch {
            try? store.setOCRResult(itemID: itemID, text: nil, state: .failed)
        }
    }
}
