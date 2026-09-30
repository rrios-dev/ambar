import Foundation
import Speech

/// Catálogo de idiomas y modelos, sobre `AssetInventory`.
///
/// **El orden de las operaciones importa y no es el que parece.** Medido en
/// macOS 26.0: con `es_ES` presente en `DictationTranscriber.installedLocales`,
/// `AssetInventory.status(forModules:)` seguía devolviendo `supported` —es decir,
/// «hay que instalar»— hasta que se llamaba a `AssetInventory.reserve(locale:)`.
/// Tras reservar, el mismo módulo pasaba a `installed`.
///
/// La reserva no es solo el contador de cupo: es lo que pone el modelo a
/// disposición de **esta** app. Consultar el estado sin reservar antes le
/// anunciaría una descarga a quien ya tiene el modelo en la máquina.
public struct SpeechModelCatalog: ModelCatalog {
    /// Opciones con las que se construye el módulo para consultar su estado.
    ///
    /// El estado depende del módulo **configurado**, no solo del idioma, así que
    /// se consulta con la misma configuración que se va a usar al dictar.
    private let mode: DictationMode

    public init(mode: DictationMode = .live) {
        self.mode = mode
    }

    public func supportedLocale(equivalentTo locale: Locale) async -> Locale? {
        await DictationTranscriber.supportedLocale(equivalentTo: locale)
    }

    public func availability(forLocale locale: Locale) async -> ModelAvailability {
        guard let resolved = await DictationTranscriber.supportedLocale(equivalentTo: locale) else {
            return .unsupported
        }
        let module = SpeechTranscriberFactory.make(locale: resolved, mode: mode)
        switch await AssetInventory.status(forModules: [module]) {
        case .unsupported: return .unsupported
        case .supported: return .supported
        case .downloading: return .downloading
        case .installed: return .installed
        @unknown default:
            // Un estado nuevo del sistema se trata como «hay que instalar», que
            // es el camino que pide permiso al usuario antes de gastar red.
            return .supported
        }
    }

    public func installModel(
        forLocale locale: Locale,
        onProgress: @Sendable @escaping (Double) -> Void
    ) async throws {
        guard let resolved = await DictationTranscriber.supportedLocale(equivalentTo: locale) else {
            throw DictationEngineError.localeUnsupported
        }
        let module = SpeechTranscriberFactory.make(locale: resolved, mode: mode)

        // Ojo: `assetInstallationRequest` devuelve una petición no nula incluso
        // cuando ya está todo instalado (medido: `progress.totalUnitCount == 0`).
        // La señal de si hay que instalar es el estado, no la existencia de la
        // petición.
        guard await availability(forLocale: resolved) != .installed else {
            onProgress(1)
            return
        }
        guard let request = try await AssetInventory.assetInstallationRequest(
            supporting: [module]
        ) else {
            onProgress(1)
            return
        }

        // `Progress` no es un `AsyncSequence`: se sondea mientras la instalación
        // corre. Barato y sin KVO cruzando dominios de aislamiento.
        let progress = request.progress
        let reporter = Task {
            while !Task.isCancelled {
                onProgress(progress.fractionCompleted)
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
        defer { reporter.cancel() }

        try await request.downloadAndInstall()
        onProgress(1)
    }

    public func installationSize(forLocale locale: Locale) async -> Int64? {
        guard let resolved = await DictationTranscriber.supportedLocale(equivalentTo: locale) else {
            return nil
        }
        let module = SpeechTranscriberFactory.make(locale: resolved, mode: mode)
        // **`assetInstallationRequest` RESERVA el idioma de paso.** Medido: inventario de
        // 0 a 1 por el solo hecho de preguntar cuánto ocupa. Es la fuga que dejaba el
        // dictado inservible, y es invisible desde aquí: preguntar un peso no se parece a
        // coger una de las cinco ranuras de la máquina, y nadie la soltaba nunca.
        //
        // Quien no la tenía antes, la suelta. Quien sí —una sesión en curso, la oferta con
        // el dictado encendido— se la queda, porque no es nuestra.
        let heldBefore = await holdsReservationDirectly(resolved)
        defer {
            if !heldBefore {
                Task { _ = await AssetInventory.release(reservedLocale: resolved) }
            }
        }
        guard let request = try? await AssetInventory.assetInstallationRequest(
            supporting: [module]
        ) else { return nil }
        // `totalUnitCount` es 0 cuando no hay nada que instalar: eso no es «cero
        // bytes», es «no aplica», y decir «0 MB» sería peor que no decir nada.
        let total = request.progress.totalUnitCount
        return total > 0 ? total : nil
    }

    /// ¿Está este idioma —ya resuelto— en el inventario de este proceso?
    ///
    /// Sin volver a resolver: el que llega aquí sale de `supportedLocale`, y resolver otra
    /// vez es la puerta por la que se reserva una variante y se suelta otra.
    private func holdsReservationDirectly(_ resolved: Locale) async -> Bool {
        await AssetInventory.reservedLocales.contains { $0.identifier == resolved.identifier }
    }

    public func reserve(locale: Locale) async throws -> Bool {
        guard let resolved = await DictationTranscriber.supportedLocale(equivalentTo: locale) else {
            throw DictationEngineError.localeUnsupported
        }
        do {
            return try await AssetInventory.reserve(locale: resolved)
        } catch {
            // **El cupo lleno LANZA; no devuelve `false`.** Medido en macOS 26.0: con
            // cinco reservas, `reserve` de un sexto idioma —instalado o no— tira
            // `SFSpeechErrorDomain` 11, «Too many allocated locales, 5 maximum.», y el
            // `false` queda reservado para «este proceso ya lo tenía».
            //
            // Sin traducirlo aquí, el único fallo con remedio concreto llegaba a la
            // interfaz como «algo ha fallado», y el mensaje del cupo se emitía en el caso
            // contrario — cuando la reserva ya era nuestra y todo estaba bien.
            if Self.isQuotaExhausted(error) {
                throw DictationEngineError.reservationQuotaExceeded
            }
            throw error
        }
    }

    /// ¿Es este el error de «no caben más idiomas»?
    ///
    /// Se compara el dominio y el código, no el texto: el mensaje viene localizado por el
    /// sistema y en un Mac en ruso no dice «Too many allocated locales».
    static func isQuotaExhausted(_ error: Error) -> Bool {
        let ns = error as NSError
        return ns.domain == "SFSpeechErrorDomain" && ns.code == 11
    }

    public func release(locale: Locale) async {
        guard let resolved = await DictationTranscriber.supportedLocale(equivalentTo: locale) else {
            return
        }
        _ = await AssetInventory.release(reservedLocale: resolved)
    }

    /// Suelta lo que el sistema tenga retenido en memoria por `ModelRetention.lingering`.
    ///
    /// Existe porque `lingering` es exactamente lo que hace que el segundo dictado
    /// arranque en milisegundos, y el precio es un modelo residente. Apagar el dictado
    /// tiene que devolverlo: si no, alguien que probó la función y la desactivó paga la
    /// memoria el resto de la sesión.
    public func endModelRetention() async {
        await SpeechModels.endRetention()
    }

    public func reservation() async -> (maximum: Int, reserved: [Locale]) {
        (AssetInventory.maximumReservedLocales, await AssetInventory.reservedLocales)
    }
}

/// Construye el módulo de transcripción con la configuración canónica de Ámbar.
///
/// Vive aparte porque **el estado del modelo depende de la configuración**, así
/// que consultar disponibilidad y dictar tienen que usar exactamente el mismo
/// módulo. Tenerlo en dos sitios es garantizar que un día divergen.
enum SpeechTranscriberFactory {
    /// La configuración, como valor comparable con los presets del sistema.
    ///
    /// Se expone así porque §2.1 afirma que esto es **exactamente**
    /// `Preset.progressiveShortDictation`, y esa afirmación no tenía red: quitar
    /// `.punctuation`, `.shortForm` o `.frequentFinalization` no rompía ningún test —tres
    /// mutaciones medidas—, y cada una de las tres es una de las razones por las que se
    /// eligió este módulo. `Preset` es `Equatable`, así que afirmarlo cuesta una línea y
    /// no necesita el modelo instalado.
    ///
    /// - Parameter atypicalSpeech: añade la pista de accesibilidad para habla atípica.
    ///   Es la tercera razón de la elección del módulo (§2) y **no había forma de
    ///   activarla**: se perdía «sin que nadie lo decida», que es literalmente lo que el
    ///   diseño dice evitar. Con ella la configuración deja de ser el preset —lo es más
    ///   la pista—, y el test lo comprueba en esos términos.
    static func preset(
        for mode: DictationMode,
        atypicalSpeech: Bool = false
    ) -> DictationTranscriber.Preset {
        DictationTranscriber.Preset(
            // `shortForm` describe el uso real: frases cortas hacia un campo de
            // texto, no dictado de documentos largos.
            contentHints: atypicalSpeech ? [.shortForm, .atypicalSpeech] : [.shortForm],
            // Dictar «coma» y «punto» es lo que hace usable un dictado que va a
            // un campo de texto. `emoji` se deja fuera a propósito: en un gestor
            // de portapapeles sorprendería más que ayudaría.
            transcriptionOptions: [.punctuation],
            // El modo en vivo necesita los resultados que se refinan; el diferido
            // no los pide y así el motor no gasta en producirlos.
            //
            // `frequentFinalization` va incluido para que esta configuración sea
            // **exactamente** `Preset.progressiveShortDictation`, que es lo que
            // declara el diseño §2.1. Se comprobó comparando la configuración con el
            // preset: sin esta opción no coincidían, y el documento decía una cosa
            // mientras el código hacía otra.
            reportingOptions: mode == .live ? [.volatileResults, .frequentFinalization] : [],
            // Sin atributos. Se pedía `transcriptionConfidence` para «atenuar en
            // pantalla lo que aún es dudoso» y se descartaba: el consumidor emite
            // todos los fragmentos con `isVolatile: true` y nunca leía la confianza.
            //
            // La volatilidad SÍ se puede distinguir —`isFinal` existe como propiedad
            // de extensión del protocolo, y el motor la reporta— y se usa para eso.
            // Lo que no se usa es la confianza: se pedía y se descartaba.
            attributeOptions: []
        )
    }

    static func make(
        locale: Locale,
        mode: DictationMode,
        atypicalSpeech: Bool = false
    ) -> DictationTranscriber {
        DictationTranscriber(
            locale: locale,
            preset: preset(for: mode, atypicalSpeech: atypicalSpeech)
        )
    }
}
