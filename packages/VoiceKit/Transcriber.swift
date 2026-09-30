import Foundation

/// Un trozo de transcripción tal y como lo va entregando el motor.
///
/// `isVolatile` distingue una hipótesis del texto ya firme: un
/// fragmento volátil es una hipótesis que el motor puede reescribir —«cita» se
/// convierte en «cinta» tres palabras después—. Por eso el texto se refina dentro
/// del panel y no en la app de destino: ahí cambiar de opinión no cuesta nada.
public struct TranscriptFragment: Sendable, Equatable {
    public let text: String
    public let isVolatile: Bool
    /// Confianza del motor, si la reporta.
    ///
    /// Hoy **siempre es `nil`**: se pedía el atributo al motor y se descartaba, así
    /// que se dejó de pedir. El campo se mantiene porque otro motor detrás del
    /// protocolo sí podría reportarlo.
    ///
    /// (La volatilidad es otra cosa y sí se propaga: `isFinal` existe como propiedad
    /// de extensión de `SpeechModuleResult` —no en su declaración, que es lo que
    /// despistó una vez— y el motor la reporta.)
    public let confidence: Double?

    /// How many characters at the END of `text` are still the engine's hypothesis.
    ///
    /// The engine accumulates finalized sentences and rewrites only the current tail,
    /// and the boundary matters to any consumer that wants to let the user act on the
    /// text while dictating: the firm prefix is safe to touch, the tail is not — the
    /// engine will replace it wholesale on the next result. Published as a count and
    /// not as two strings so `text` remains the single source of what is on screen.
    ///
    /// Defaults to "all of it" for volatile fragments: a producer that cannot locate
    /// the boundary must err towards volatile, because the failure mode of the other
    /// default is an editor touching text the engine is about to rewrite.
    public let volatileCharacterCount: Int

    public init(
        text: String,
        isVolatile: Bool,
        confidence: Double? = nil,
        volatileCharacterCount: Int? = nil
    ) {
        self.text = text
        self.isVolatile = isVolatile
        self.confidence = confidence
        self.volatileCharacterCount = min(
            max(volatileCharacterCount ?? (isVolatile ? text.count : 0), 0),
            text.count
        )
    }
}

/// El resultado de una sesión, ya estable.
public struct Transcript: Sendable, Equatable {
    /// Texto plano. Los atributos del motor (confianza, rango temporal) son
    /// metadatos del reconocimiento, no formato: no significan nada en la app de
    /// destino y no viajan al portapapeles.
    public let text: String
    public let mode: DictationMode
    /// Se entregó al vencer el techo de la finalización, así que puede faltarle
    /// la última corrección. Se guarda para poder decirlo en la interfaz en lugar
    /// de entregar en silencio algo posiblemente incompleto.
    public let wasTruncated: Bool

    public init(text: String, mode: DictationMode, wasTruncated: Bool = false) {
        self.text = text
        self.mode = mode
        self.wasTruncated = wasTruncated
    }

    public var isEmpty: Bool { text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

// MARK: - Contrato del motor

/// Consultas sobre idiomas y modelos.
///
/// Va separado de la sesión a propósito: Ajustes necesita preguntar qué idiomas
/// hay y qué falta por instalar **sin instanciar nada de audio**. Si las dos cosas
/// vivieran en el mismo tipo, abrir Ajustes arrastraría el motor entero.
public protocol ModelCatalog: Sendable {
    /// Idioma admitido equivalente al pedido, o `nil` si no hay ninguno.
    ///
    /// Se delega en el motor porque el sistema ya sabe hacer esta equivalencia
    /// (`supportedLocale(equivalentTo:)`); replicarla a mano cruzando prefijos de
    /// dos letras es reimplementar peor lo que el framework resuelve.
    func supportedLocale(equivalentTo locale: Locale) async -> Locale?

    func availability(forLocale locale: Locale) async -> ModelAvailability

    /// Instala el modelo del idioma, informando del avance de 0 a 1.
    func installModel(
        forLocale locale: Locale,
        onProgress: @Sendable @escaping (Double) -> Void
    ) async throws

    /// Bytes que ocupará la instalación, si el sistema los reporta.
    ///
    /// Pedir una descarga de tamaño desconocido es pedir un cheque en blanco: el
    /// diseño exige «se ofrece indicando el peso».
    func installationSize(forLocale locale: Locale) async -> Int64?

    /// Reserva el idioma contra el cupo del sistema.
    ///
    /// Devuelve `false` cuando el cupo está lleno — no es un error, es una
    /// respuesta que hay que saber contar al usuario junto con qué liberar.
    /// - Important: el `locale` que se pase aquí y el de `release`/`availability` tienen que
    ///   ser **el mismo objeto resuelto**. `supportedLocale(equivalentTo:)` no es determinista
    ///   sin coincidencia exacta, así que resolver por separado en cada llamada puede reservar
    ///   una variante y soltar otra — y eso fuga una de las cinco ranuras de la máquina.
    func reserve(locale: Locale) async throws -> Bool

    func release(locale: Locale) async

    /// Cuántos idiomas se pueden tener reservados a la vez, y cuáles lo están.
    func reservation() async -> (maximum: Int, reserved: [Locale])

    /// Suelta el modelo que el sistema mantenga residente por retención.
    func endModelRetention() async
}

extension ModelCatalog {
    /// ¿Tiene este proceso reservado ya el idioma pedido?
    ///
    /// Hace falta porque `reserve` devuelve `false` en dos situaciones opuestas —cupo
    /// lleno y ya reservado— así que el booleano no distingue «lo he reservado yo
    /// ahora» de «ya estaba». Sin esa distinción, cualquiera que reserve para consultar
    /// no puede saber si le toca soltar, y la ranura se queda cogida.
    ///
    /// La comparación es por `identifier` sobre el idioma **resuelto**: `Locale`
    /// compara por igualdad estructural, y el que el sistema reserva no es el que se
    /// pidió (`es_ES` → `es-ES`), así que `contains(_:)` daría falso siempre.
    public func holdsReservation(forLocale locale: Locale) async -> Bool {
        guard let resolved = await supportedLocale(equivalentTo: locale) else { return false }
        let (_, reserved) = await reservation()
        return reserved.contains { $0.identifier == resolved.identifier }
    }

    /// Devuelve al sistema todas las ranuras de esta app salvo la del idioma pedido.
    ///
    /// **Las reservas sobreviven al proceso.** Medido en macOS 26.0: un proceso reserva
    /// `fr_FR` y termina; el siguiente proceso de la misma app lo encuentra reservado. No
    /// son un recurso que el sistema recoja al cerrar, sino un apunte persistente — así
    /// que cualquier camino que reserve y no suelte deja la ranura cogida **para
    /// siempre**, no hasta el próximo arranque.
    ///
    /// De ahí que haga falta un barrido y no baste con no fugar: lo ya fugado no se va
    /// solo. Solo es seguro llamarlo cuando no puede haber una sesión de dictado viva
    /// —al arrancar—, porque quitarle el idioma a una sesión en curso es peor que la fuga.
    public func releaseReservations(keeping locale: Locale?) async {
        let keep = locale.map { $0.identifier }
        let (_, reserved) = await reservation()
        for held in reserved where held.identifier != keep {
            await release(locale: held)
        }
    }
}

/// Una sesión de dictado en curso.
///
/// El ciclo es deliberadamente explícito —preparar, empezar, terminar— porque
/// cada paso tiene una consecuencia distinta sobre el micrófono:
/// `prepare()` carga el modelo y **no** toca la entrada de audio; solo `start()`
/// la abre. Esa separación es lo que permite aprovechar la cuenta del gesto para
/// lo caro sin encender el indicador del sistema antes de que el usuario confirme.
public protocol TranscriptionSession: Sendable {
    /// Carga el modelo y deja todo listo. Sin micrófono.
    func prepare() async throws

    /// Abre la entrada de audio y devuelve el flujo de fragmentos.
    func start() async throws -> AsyncStream<TranscriptFragment>

    /// Cierra la entrada y espera a que el texto deje de ser volátil.
    ///
    /// El techo de espera lo pone quien llama, no la sesión: es una decisión de
    /// interfaz («cuánto es razonable que el usuario espere»), no del motor.
    func finish() async throws -> Transcript

    /// Aborta sin entregar nada.
    func cancel() async

    /// Aviso de que la entrada de audio cambió a mitad de sesión y el formato
    /// negociado dejó de valer.
    ///
    /// **Sin implementación por defecto, a propósito.** La tuvo, vacía, con el
    /// argumento de que una fuente que no puede cambiar no tiene nada que reportar. El
    /// coste de esa comodidad se midió: `await sesiónConcreta.setSessionLimitHandler {…}`
    /// —con el tipo concreto, no con el existencial— resolvía a la implementación vacía
    /// y **no guardaba nada**, en silencio. Cayeron en la trampa un test propio y una
    /// auditoría, las dos concluyendo que «el techo cierra pero no avisa».
    ///
    /// Una red de seguridad no puede tener un no-op como comportamiento por omisión:
    /// quien no la necesite escribe dos líneas y lo dice.
    func setDeviceChangeHandler(_ handler: @escaping @Sendable () -> Void) async

    /// Aviso de que la sesión ha alcanzado su duración máxima.
    func setSessionLimitHandler(_ handler: @escaping @Sendable () -> Void) async

    /// ¿Llegó ya un resultado marcado como final?
    ///
    /// Permite no confesar una pérdida que no ha ocurrido cuando vence el techo de
    /// finalización: si el motor ya había cerrado la frase, el texto está completo.
    func hasFinalResultIfAvailable() async -> Bool
}

extension TranscriptionSession {
    /// Por defecto, conservador: se asume que no hubo resultado final, así que una
    /// entrega por techo se marca como posiblemente incompleta.
    public func hasFinalResultIfAvailable() async -> Bool { false }
}

/// El motor de transcripción.
///
/// Existe como protocolo por una razón concreta: la calidad del transcriptor
/// nativo en español hablado rápido está por medir, y si no diera la talla hay que
/// poder poner otro motor detrás sin rediseñar la interfaz, el gesto ni el
/// historial. La decisión de motor tiene que ser reversible desde el primer día.
public protocol TranscriberEngine: Sendable {
    /// Identificador estable para registrar con qué motor se hizo cada medida de
    /// capacidad. Un factor de tiempo real medido con un motor no dice nada del
    /// siguiente.
    static var identifier: String { get }

    var catalog: any ModelCatalog { get }

    /// - Parameter atypicalSpeech: activa la pista de accesibilidad del motor. Viaja por
    ///   el protocolo porque es una preferencia del usuario, no una constante: es la
    ///   tercera razón de §2 para elegir este módulo y no tenía ningún camino desde la
    ///   interfaz.
    /// - Parameter contextualStrings: words or short phrases the engine should be able
    ///   to recognize even when they are not in the system vocabulary — brand names,
    ///   proper nouns, the user's own jargon. They travel through the protocol, not as
    ///   an ambient default, for the same reason `atypicalSpeech` does: a protocol
    ///   extension default silently swallowed an assignment once in this very file,
    ///   and a bias list that never reaches the engine fails without a symptom — the
    ///   engine still transcribes, just worse, on exactly the words the user taught it.
    func makeSession(
        locale: Locale,
        mode: DictationMode,
        atypicalSpeech: Bool,
        contextualStrings: [String]
    ) throws -> any TranscriptionSession
}
