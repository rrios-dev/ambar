import Foundation

/// Disponibilidad del modelo de transcripción para un idioma.
///
/// Espeja `AssetInventory.Status` del framework Speech: los mismos cuatro casos
/// con los mismos nombres, deliberadamente. La taxonomía es del sistema, no
/// nuestra — inventar una propia solo garantiza divergir cuando el sistema añada
/// un estado.
///
/// ¿Por qué entonces un tipo propio en lugar de usar el del sistema? Porque esta
/// capa decide **qué se le ofrece al usuario**, y eso tiene que poder probarse
/// sin arrancar el framework, sin micrófono y sin modelos instalados. El mapeo
/// desde `AssetInventory.Status` vive en el motor, en un único sitio.
public enum ModelAvailability: String, Sendable, Equatable, CaseIterable {
    /// El idioma no está entre los que el transcriptor admite.
    case unsupported
    /// El idioma se admite, pero el modelo no está en la máquina todavía.
    case supported
    /// Instalación en curso.
    case downloading
    /// Listo para transcribir.
    case installed
}

/// Estado del permiso de micrófono, tal y como lo ve esta capa.
///
/// `notDetermined` es distinto de `denied` y la diferencia importa: en el primer
/// caso se puede pedir, en el segundo hay que mandar a Ajustes del Sistema
/// porque macOS no vuelve a preguntar.
public enum MicrophonePermission: String, Sendable, Equatable, CaseIterable {
    case notDetermined
    case granted
    case denied
}

/// Modo de dictado.
///
/// La diferencia es **solo si se ve el texto mientras se habla**, no el
/// mecanismo de entrega: los dos acaban con un único pegado al finalizar.
public enum DictationMode: String, Sendable, Equatable, CaseIterable {
    /// El texto aparece y se refina mientras se habla.
    case live
    /// Se graba y el texto llega al final.
    case deferred
}

// MARK: - Capacidad de la máquina

/// Medida de si esta máquina puede seguir el habla en tiempo real.
///
/// El indicador es el **factor de tiempo real**: segundos de cómputo por segundo
/// de audio. Por debajo de 1 el análisis va más rápido que el habla; por encima,
/// no puede seguirla.
///
/// Se mide en lugar de deducirse de una tabla de modelos de Mac porque esa tabla
/// envejece mal y no sabe nada de la presión de memoria ni del estado térmico del
/// momento. El precedente de la casa es `TextRecognizer.systemPreferredLanguages`,
/// que cruza las preferencias con lo que Vision admite de verdad en vez de fijar
/// una lista.
public struct CapabilityMeasurement: Sendable, Equatable {
    public let realTimeFactor: Double
    public let measuredAt: Date
    /// Identificador de la máquina y versión del sistema con los que se midió.
    /// Si cambian, la medida deja de ser válida y hay que repetirla.
    public let machineIdentifier: String
    public let systemVersion: String

    public init(
        realTimeFactor: Double,
        measuredAt: Date,
        machineIdentifier: String,
        systemVersion: String
    ) {
        self.realTimeFactor = realTimeFactor
        self.measuredAt = measuredAt
        self.machineIdentifier = machineIdentifier
        self.systemVersion = systemVersion
    }

    /// ¿Sigue siendo válida esta medida en el entorno actual?
    public func isValid(machineIdentifier: String, systemVersion: String) -> Bool {
        self.machineIdentifier == machineIdentifier && self.systemVersion == systemVersion
    }
}

/// Umbrales que traducen un factor de tiempo real en una recomendación.
///
/// > **Los valores por defecto son PROVISIONALES.** El diseño exige calibrarlos
/// > midiendo en máquinas reales, y hasta que eso ocurra no se puede afirmar que
/// > separen bien. Están aquí para que el resto del sistema tenga con qué
/// > funcionar, no como conclusión.
public struct CapabilityThresholds: Sendable, Equatable {
    /// Por debajo de este factor, el modo en vivo va con holgura.
    public var comfortable: Double

    /// A partir de este factor el análisis no puede seguir al habla. El 1,0 no
    /// es una elección: es la definición de tiempo real.
    public var realTime: Double

    public init(comfortable: Double = 0.5, realTime: Double = 1.0) {
        self.comfortable = comfortable
        self.realTime = realTime
    }

    public static let provisional = CapabilityThresholds()
}

/// Lectura de la capacidad de la máquina.
public enum Capability: String, Sendable, Equatable, CaseIterable {
    /// Nadie ha medido todavía.
    case unmeasured
    /// La medida da margen: se puede invitar al modo en vivo.
    case comfortable
    /// Se puede, pero va apretado: hay que advertir de qué se va a notar.
    case tight
    /// El análisis no puede seguir al habla: el modo en vivo no es una opción.
    case cannotFollowSpeech

    /// ¿Hay que presentar el dictado advirtiendo en lugar de invitando?
    ///
    /// Sí en los dos casos en los que la máquina no da de sobra. Que `unmeasured` invite
    /// es deliberado: no se sabe nada, y proponer el modo diferido ya es la cautela.
    public var warrantsWarning: Bool {
        switch self {
        case .tight, .cannotFollowSpeech: true
        case .unmeasured, .comfortable: false
        }
    }

    public init(realTimeFactor: Double, thresholds: CapabilityThresholds = .provisional) {
        if realTimeFactor <= thresholds.comfortable {
            self = .comfortable
        } else {
            // `realTime` sí se usa: por encima de 1 el análisis no puede seguir al
            // habla, y eso no es «va justo», es «el modo en vivo no sirve aquí». Antes
            // el campo no tenía consumidor y un test lo afirmaba de todas formas.
            self = realTimeFactor >= thresholds.realTime ? .cannotFollowSpeech : .tight
        }
    }

    /// Modo que se preselecciona con esta capacidad.
    ///
    /// Preselecciona: el usuario puede cambiarlo. Sin medida se propone el
    /// diferido, que es el que funciona en cualquier máquina — no se estrena la
    /// función con la variante que puede ir a tirones.
    public var suggestedMode: DictationMode {
        switch self {
        case .comfortable: .live
        case .tight, .unmeasured, .cannotFollowSpeech: .deferred
        }
    }
}

// MARK: - Qué se le ofrece al usuario

/// Motivo por el que el dictado no se puede activar.
///
/// Cada caso existe porque lleva a un mensaje y a una acción distintos. Un
/// «no disponible» sin motivo deja al usuario sin nada que hacer.
public enum UnavailableReason: String, Sendable, Equatable, CaseIterable {
    /// El idioma no está entre los admitidos por el transcriptor.
    case localeUnsupported
    /// No hay entrada de audio en el sistema.
    case noMicrophone
    /// El permiso está denegado; macOS no volverá a preguntar.
    case microphoneDenied
}

/// Tono con el que se presenta la función cuando sí se puede activar.
///
/// La diferencia entre holgada y justa **no es encendido/apagado — es el tono**:
/// una invita, la otra advierte. En los dos casos decide el usuario y en los dos
/// arranca apagado.
public enum OfferTone: String, Sendable, Equatable, CaseIterable {
    case inviting
    case warning
}

/// Lo que la interfaz debe presentar.
public enum DictationOffer: Sendable, Equatable {
    case unavailable(UnavailableReason)
    /// Se puede, pero el permiso del micrófono **no se ha pedido nunca**.
    ///
    /// Distinto de `.unavailable(.microphoneDenied)`: aquí hay un clic que lo resuelve, y
    /// hacerlo es además lo único que mete a la app en la lista de Ajustes del Sistema →
    /// Privacidad → Micrófono. macOS solo enumera ahí las apps que **han solicitado** el
    /// permiso, y no hay botón para añadirlas a mano.
    case needsMicrophonePermission
    /// Se puede, pero antes hay que instalar el modelo del idioma.
    case needsModel
    case installingModel
    case available(tone: OfferTone, suggestedMode: DictationMode)
}

/// Todo lo que se sabe del entorno, junto.
public struct DictationReadiness: Sendable, Equatable {
    public var availability: ModelAvailability
    public var permission: MicrophonePermission
    public var hasInputDevice: Bool
    public var capability: Capability

    public init(
        availability: ModelAvailability,
        permission: MicrophonePermission,
        hasInputDevice: Bool,
        capability: Capability
    ) {
        self.availability = availability
        self.permission = permission
        self.hasInputDevice = hasInputDevice
        self.capability = capability
    }

    /// Resuelve qué se ofrece.
    ///
    /// El orden de las comprobaciones no es arbitrario: primero lo que no tiene
    /// arreglo desde la app (idioma, hardware), después el permiso —que tiene
    /// acción— y por último el modelo, que solo es cuestión de esperar. Al
    /// usuario se le dice el obstáculo que de verdad le bloquea, no el primero
    /// que encontramos.
    public var offer: DictationOffer {
        guard availability != .unsupported else {
            return .unavailable(.localeUnsupported)
        }
        guard hasInputDevice else {
            return .unavailable(.noMicrophone)
        }
        guard permission != .denied else {
            return .unavailable(.microphoneDenied)
        }
        // **Sin permiso decidido no se declara lista.**
        //
        // Aquí decía que `notDetermined` no bloquea «porque se pide al activar», y es cierto
        // en ese camino: `enableDictation` pide primero y calcula la oferta con la respuesta.
        // El hueco era el otro: una app que arranca con el dictado **ya activado** en las
        // preferencias y el permiso sin pedir —porque se activó en otra copia, porque la app
        // se movió, porque se reinstaló o porque alguien corrió `tccutil reset Microphone`—.
        // Ahí nadie pedía nada, la oferta salía `.available`, el gesto armaba, y el permiso
        // aparecía **a mitad de la primera sesión**: exactamente el modo de fallo que la
        // cabecera de `MicrophoneAuthorization` describe como el peor, porque la sesión sigue
        // viva recibiendo silencio.
        //
        // Y tenía una segunda cara peor de diagnosticar: al fallar, el remedio que se ofrecía
        // era «Abrir Ajustes», y en esa lista **la app no aparece** —macOS solo enumera las
        // que han pedido el permiso—, así que el usuario se queda mirando un panel donde no
        // hay nada que activar.
        guard permission == .granted else {
            return .needsMicrophonePermission
        }

        switch availability {
        case .unsupported:
            // Ya cubierto por el guard de arriba; el compilador exige el caso.
            return .unavailable(.localeUnsupported)
        case .supported:
            return .needsModel
        case .downloading:
            return .installingModel
        case .installed:
            return .available(
                // Advierte con `.tight` **y** con `.cannotFollowSpeech`. Solo con
                // `.tight`, la máquina cuyo propio caso dice «el modo en vivo no es una
                // opción» se presentaba **invitando**, con el modo en vivo seleccionable
                // al lado. Era invisible mientras nadie medía —el caso no podía ocurrir—,
                // y el primer test que lo ejercitó tras cablear la sonda lo destapó.
                tone: capability.warrantsWarning ? .warning : .inviting,
                suggestedMode: capability.suggestedMode
            )
        }
    }
}
