import AppCore
import AppKit
import ClipboardKit
import Foundation
import VoiceKit
import Observation

/// Preferencias persistidas.
///
/// `UserDefaults` y no la base de datos: son ajustes del usuario, no datos del
/// historial, y deben sobrevivir a un borrado completo del historial.
@Observable
@MainActor
final class Settings {
    private enum Key {
        static let hotKeyCode = "hotkey.keyCode"
        static let hotKeyModifiers = "hotkey.modifiers"
        static let retentionDays = "retention.days"
        static let retentionGigabytes = "retention.gigabytes"
        static let excludedBundleIDs = "privacy.excludedBundleIDs"
        static let launchAtLogin = "general.launchAtLogin"
        static let isPaused = "general.paused"
        static let pauseUntil = "general.pauseUntil"
        static let ocrEnabled = "recognition.enabled"
        static let dictationEnabled = "dictation.enabled"
        static let dictationMode = "dictation.mode"
        static let dictationModeChosen = "dictation.modeChosen"
        static let atypicalSpeech = "dictation.atypicalSpeech"
        static let dictionaryLearning = "dictation.dictionaryLearning"
        static let capabilityFactor = "dictation.capability.factor"
        static let capabilityAt = "dictation.capability.measuredAt"
        static let capabilityMachine = "dictation.capability.machine"
        static let capabilitySystem = "dictation.capability.system"
        static let holdGestureEnabled = "dictation.holdGesture"
        static let onboardingCompletedVersion = "onboarding.completedVersion"
    }

    private let defaults: UserDefaults

    var hotKey: KeyCombination {
        didSet {
            defaults.set(Int(hotKey.keyCode), forKey: Key.hotKeyCode)
            defaults.set(Int(hotKey.modifiers), forKey: Key.hotKeyModifiers)
        }
    }

    /// 0 = sin límite de antigüedad.
    var retentionDays: Int {
        didSet { defaults.set(retentionDays, forKey: Key.retentionDays) }
    }

    /// 0 = sin límite de tamaño.
    var retentionGigabytes: Double {
        didSet { defaults.set(retentionGigabytes, forKey: Key.retentionGigabytes) }
    }

    var excludedBundleIDs: [String] {
        didSet { defaults.set(excludedBundleIDs, forKey: Key.excludedBundleIDs) }
    }

    var launchAtLogin: Bool {
        didSet {
            defaults.set(launchAtLogin, forKey: Key.launchAtLogin)
            LaunchAtLogin.set(launchAtLogin)
        }
    }

    /// Vuelve a aplicar la preferencia de arranque contra el registro real del sistema.
    ///
    /// La asignación de arriba solo corre **al cambiar** el valor, así que una
    /// preferencia guardada como activa no se volvía a aplicar nunca. Reinstalar la app
    /// —o moverla— pierde el registro, y la casilla seguía marcada mientras Ámbar ya no
    /// arrancaba sola. Se llama al arrancar, que es el único momento en que las dos
    /// versiones de la verdad se pueden comparar.
    func reconcileLaunchAtLogin() {
        let effective = LaunchAtLogin.reconcile(preference: launchAtLogin)
        if effective != launchAtLogin { launchAtLogin = effective }
    }

    /// Pausa de la captura, con vencimiento.
    ///
    /// Se guarda **la fecha en la que vence**, no un booleano. Un booleano tiene
    /// dos fallos simétricos: te olvidas de que está puesto y pierdes semanas de
    /// historial, o te crees protegido cuando ya no lo estás. Con una fecha, el
    /// estado se deriva del reloj y vuelve solo al lado seguro — también después
    /// de reiniciar.
    private(set) var pause: HistoryPause? {
        didSet {
            if let pause {
                defaults.set(pause.until, forKey: Key.pauseUntil)
            } else {
                defaults.removeObject(forKey: Key.pauseUntil)
            }
            // Se mantiene la clave antigua en sincronía para no dejar basura
            // contradictoria en las preferencias.
            defaults.set(pause != nil, forKey: Key.isPaused)
        }
    }

    /// ¿Está la captura pausada **ahora**?
    ///
    /// Sigue siendo asignable para no romper el menú de la barra ni los ajustes:
    /// poner `true` crea una pausa indefinida, que es lo que hacía el booleano.
    var isPaused: Bool {
        get { pause?.isActive() ?? false }
        set { newValue ? pauseCapture(.untilResumed) : resumeCapture() }
    }

    /// Cablea el anuncio a VoiceOver del cambio de pausa. Inyectable para test: sin
    /// esto no hay forma de comprobar que pausar/reanudar avisa, y era exactamente el
    /// hallazgo de la auditoría de cierre — el único mecanismo de anuncio activo del
    /// proyecto vivía solo en `DictationController`, y la pausa del historial —el otro
    /// cambio de estado persistente que la barra de menús refleja— quedaba muda para
    /// quien usa VoiceOver.
    var announcer: @MainActor (String) -> Void = { text in
        var announcement = AttributedString(text)
        announcement.accessibilitySpeechAnnouncementPriority = .high
        AccessibilityNotification.Announcement(announcement).post()
    }

    /// Pausa la captura durante un tiempo concreto.
    func pauseCapture(_ duration: HistoryPause.Duration) {
        pause = .starting(duration)
        // Reusa la clave que ya existe para el mismo estado en el panel — «Historial en
        // pausa» — en vez de una nueva traducida aparte: es el mismo hecho, dicho dos
        // veces por dos canales (visual y hablado), y una sola clave evita que un día
        // diverjan.
        announcer(String(localized: "panel.pause.indefinite", bundle: .localized))
    }

    func resumeCapture() {
        pause = nil
        announcer(String(localized: "history.resumed.announcement", bundle: .localized))
    }

    /// Segundos que quedan de pausa, o `nil` si es indefinida o no hay ninguna.
    /// La interfaz lo usa para poder decirlo en lugar de mostrar solo «pausado».
    var remainingPause: TimeInterval? { pause?.remaining() }

    /// Fuerza el vencimiento de la pausa. Solo para tests: esperar quince minutos no es
    /// una opción, y el vencimiento **no emite ningún evento**, que es justo lo que hay que
    /// poder ejercitar.
    func expirePauseForTesting() {
        pause = HistoryPause(until: Date(timeIntervalSince1970: 0))
    }

    /// Limpia una pausa ya vencida del estado guardado.
    func prunePauseIfExpired() {
        guard let pause, !pause.isActive() else { return }
        self.pause = nil
        // Y se dice. Pausar y reanudar ya avisaban; el **vencimiento** no, y es el único
        // de los tres que ocurre sin que el usuario haga nada: la protección termina sola
        // y quien no ve la pantalla no tiene forma de enterarse. Es el fallo simétrico al
        // que la pausa con duración existe para evitar.
        //
        // Este es el único sitio donde el vencimiento se detecta —el estado se deriva del
        // reloj, así que no hay ningún evento que observar—, y solo entra aquí en la
        // transición, no en cada repintado.
        announcer(String(localized: "history.pause_expired.announcement", bundle: .localized))
    }

    var isOCREnabled: Bool {
        didSet { defaults.set(isOCREnabled, forKey: Key.ocrEnabled) }
    }

    /// Versión del guion de presentación que este usuario ya vio. `0` = ninguna.
    ///
    /// En `UserDefaults` y no en el llavero, a diferencia de la marca de la prueba: que
    /// alguien que borra sus preferencias vuelva a ver la presentación es inofensivo —hasta
    /// razonable—, mientras que reiniciar el contador de la prueba no lo sería.
    var onboardingCompletedVersion: Int {
        didSet { defaults.set(onboardingCompletedVersion, forKey: Key.onboardingCompletedVersion) }
    }

    /// El dictado por voz viene **apagado**, siempre.
    ///
    /// No es prudencia excesiva: activarlo implica el permiso de micrófono y la
    /// instalación de un modelo del sistema. Encender eso sin que nadie lo pida es
    /// intrusivo, y quien no lo quiera no debe pagar nada por su existencia.
    var isDictationEnabled: Bool {
        didSet { defaults.set(isDictationEnabled, forKey: Key.dictationEnabled) }
    }

    /// En vivo (se ve el texto mientras se habla) o diferido (llega al final).
    var dictationMode: DictationMode {
        didSet {
            defaults.set(dictationMode.rawValue, forKey: Key.dictationMode)
            hasChosenDictationMode = true
        }
    }

    /// ¿Ha elegido el usuario el modo, o sigue el propuesto?
    ///
    /// Importa para no pisar una decisión suya: la recomendación solo se aplica
    /// mientras nadie haya elegido.
    private(set) var hasChosenDictationMode: Bool {
        didSet { defaults.set(hasChosenDictationMode, forKey: Key.dictationModeChosen) }
    }

    /// Última medida de capacidad de **esta** máquina, si hay alguna válida.
    ///
    /// Se guarda con la máquina y la versión del sistema con las que se tomó, y se
    /// descarta si cambian: una medida hecha en un Mac potente que viaja en una copia de
    /// seguridad a uno lento seguiría recomendando el modo en vivo, que es justo lo que
    /// la medición existe para evitar.
    var capabilityMeasurement: CapabilityMeasurement? {
        get {
            let factor = defaults.double(forKey: Key.capabilityFactor)
            guard factor > 0,
                  let machine = defaults.string(forKey: Key.capabilityMachine),
                  let system = defaults.string(forKey: Key.capabilitySystem)
            else { return nil }
            let measurement = CapabilityMeasurement(
                realTimeFactor: factor,
                measuredAt: Date(timeIntervalSince1970: defaults.double(forKey: Key.capabilityAt)),
                machineIdentifier: machine,
                systemVersion: system
            )
            guard measurement.isValid(
                machineIdentifier: CapabilityProbe.machineIdentifier(),
                systemVersion: CapabilityProbe.systemVersion()
            ) else { return nil }
            return measurement
        }
        set {
            guard let newValue else {
                defaults.removeObject(forKey: Key.capabilityFactor)
                return
            }
            defaults.set(newValue.realTimeFactor, forKey: Key.capabilityFactor)
            defaults.set(newValue.measuredAt.timeIntervalSince1970, forKey: Key.capabilityAt)
            defaults.set(newValue.machineIdentifier, forKey: Key.capabilityMachine)
            defaults.set(newValue.systemVersion, forKey: Key.capabilitySystem)
        }
    }

    /// Capacidad derivada de la medida, o `.unmeasured` si no hay ninguna válida.
    var capability: Capability {
        guard let measurement = capabilityMeasurement else { return .unmeasured }
        return Capability(realTimeFactor: measurement.realTimeFactor)
    }

    /// Pista del motor para **habla atípica**.
    ///
    /// Es la función de accesibilidad de Apple para quien tiene un habla que los modelos
    /// generales transcriben peor —disartria, tartamudez, voz tras cirugía—. Fue una de
    /// las tres razones para elegir `DictationTranscriber` sobre el otro módulo, y no
    /// tenía ninguna forma de activarse: se perdía «sin que nadie lo decida», que es
    /// exactamente lo que el diseño dice evitar.
    ///
    /// Apagada por defecto porque no es gratis: cambia el modelo acústico, y para quien
    /// no la necesita transcribe algo peor.
    var isAtypicalSpeechEnabled: Bool {
        didSet { defaults.set(isAtypicalSpeechEnabled, forKey: Key.atypicalSpeech) }
    }

    /// Does dictation learn vocabulary from the user's inline corrections?
    ///
    /// On by default — the whole point of correcting a word is not having to correct
    /// it again — but a switch exists because learning writes to disk: whoever wants
    /// corrections to stay ephemeral must be able to say so once, in Settings, and
    /// not per correction.
    var isDictionaryLearningEnabled: Bool {
        didSet { defaults.set(isDictionaryLearningEnabled, forKey: Key.dictionaryLearning) }
    }

    /// ¿Se dispara el dictado manteniendo el atajo?
    ///
    /// Se puede desactivar conservando el botón de micrófono y ⌘D. Hace falta por
    /// *Sticky Keys*: con esa función activa el sistema reporta los modificadores
    /// hundidos tras soltarlos —es literalmente su propósito— así que cualquier
    /// apertura del panel superaría el umbral y abriría el micrófono sin que nadie
    /// mantenga nada. Sin esta casilla, la única salida era renunciar al dictado.
    var isHoldGestureEnabled: Bool {
        didSet { defaults.set(isHoldGestureEnabled, forKey: Key.holdGestureEnabled) }
    }

    /// Aplica el modo propuesto por la medición, si el usuario no ha elegido.
    ///
    /// §6.1 llama a esto «la protección real» mientras no exista la medición: sin
    /// medir se propone el diferido, que funciona en cualquier máquina. Se calculaba
    /// y no se aplicaba, así que la función se estrenaba en vivo — justo lo que ese
    /// párrafo dice evitar.
    func applySuggestedDictationMode(_ suggested: DictationMode) {
        guard !hasChosenDictationMode else { return }
        defaults.set(suggested.rawValue, forKey: Key.dictationMode)
        dictationMode = suggested
        // Sigue sin ser elección del usuario.
        hasChosenDictationMode = false
    }

    /// Preferencias aisladas cuando el arnés pide un directorio de datos propio.
    ///
    /// `AMBAR_DATA_DIR` aislaba el historial pero **no** las preferencias, así que
    /// `AMBAR_PERMISSIONS` imprimía el estado de la máquina de quien lo ejecutara. Una
    /// auditoría independiente estuvo a punto de reportar que la función se estrena
    /// encendida: el `dictado activado=true` que leyó venía del dominio real, no de un
    /// arranque limpio. Un arnés cuya salida depende de la máquina engaña al siguiente que
    /// lo mire, y ese es exactamente su trabajo — no engañar.
    ///
    /// El dominio se deriva del directorio, así que dos ejecuciones con el mismo
    /// `AMBAR_DATA_DIR` comparten estado y dos con directorios distintos no.
    static func reviewDefaults() -> UserDefaults? {
        #if DEBUG
        guard let directory = ProcessInfo.processInfo.environment["AMBAR_DATA_DIR"] else { return nil }
        let suite = "dev.rrios.ambar.review." + String(
            directory.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) ? Character($0) : "-" }
        )
        return UserDefaults(suiteName: suite)
        #else
        return nil
        #endif
    }

    init(defaults: UserDefaults = Settings.reviewDefaults() ?? .standard) {
        self.defaults = defaults

        defaults.register(defaults: [
            // El disparo por gesto nace desactivado si el sistema tiene Teclas
            // Especiales: con los modificadores enclavados, cualquier apertura del
            // panel abriría el micrófono sin que nadie mantenga nada.
            //
            // Va en `register` y no en un `if` posterior: `object(forKey:)` NUNCA
            // devuelve nil una vez registrado el valor por defecto, así que la
            // comprobación «¿lo ha tocado el usuario?» era código muerto y la
            // mitigación no se aplicaba jamás. Lo midió un auditor ejecutándolo.
            Key.holdGestureEnabled: !StickyKeys.isEnabled,
            Key.dictionaryLearning: true,
            // El modo con el que se ESTRENA la función es el diferido (§7), porque funciona
            // en cualquier máquina mientras no haya una medición de capacidad. Estaba solo
            // como fallback del `init` y sin registrar, así que cualquier estado con el
            // dictado activado y esta clave nunca escrita arrancaba **en vivo** — medido por
            // una auditoría en esta misma máquina: `defaults read` devolvía tres claves,
            // ninguna era esta, y el arnés imprimía `modo=live`.
            //
            // La garantía vivía solo en `applyOfferedMode()`, que corre al activar; quien
            // llegara al estado por otro camino se la saltaba.
            Key.dictationMode: DictationMode.deferred.rawValue,
            Key.retentionDays: 30,
            Key.retentionGigabytes: 2.0,
            Key.ocrEnabled: true,
            // Los gestores de contraseñas más comunes vienen excluidos de
            // fábrica. La marca `ConcealedType` cubre a los que la ponen, pero
            // no todos lo hacen y el coste de equivocarse aquí es alto.
            Key.excludedBundleIDs: [
                "com.apple.keychainaccess",
                "com.1password.1password",
                "com.agilebits.onepassword7",
                "com.bitwarden.desktop",
                "in.sinew.Enpass-Desktop",
                "com.dashlane.Dashlane",
                "org.keepassxc.keepassxc",
            ],
        ])

        let storedCode = defaults.integer(forKey: Key.hotKeyCode)
        let storedModifiers = defaults.integer(forKey: Key.hotKeyModifiers)
        self.hotKey = storedCode == 0
            ? .commandShiftV
            : KeyCombination(keyCode: UInt32(storedCode), modifiers: UInt32(storedModifiers))

        self.retentionDays = defaults.integer(forKey: Key.retentionDays)
        self.retentionGigabytes = defaults.double(forKey: Key.retentionGigabytes)
        self.excludedBundleIDs = defaults.stringArray(forKey: Key.excludedBundleIDs) ?? []
        self.launchAtLogin = defaults.bool(forKey: Key.launchAtLogin)
        // Migración desde el booleano: quien tuviera la captura pausada sigue
        // pausado, y de forma indefinida, que es lo que significaba el `true`.
        if let until = defaults.object(forKey: Key.pauseUntil) as? Date {
            self.pause = HistoryPause(until: until)
        } else if defaults.bool(forKey: Key.isPaused) {
            self.pause = .starting(.untilResumed)
        } else {
            self.pause = nil
        }
        self.isOCREnabled = defaults.bool(forKey: Key.ocrEnabled)
        self.onboardingCompletedVersion = defaults.integer(forKey: Key.onboardingCompletedVersion)
        self.isDictationEnabled = defaults.bool(forKey: Key.dictationEnabled)
        self.hasChosenDictationMode = defaults.bool(forKey: Key.dictationModeChosen)
        self.isAtypicalSpeechEnabled = defaults.bool(forKey: Key.atypicalSpeech)
        self.isDictionaryLearningEnabled = defaults.bool(forKey: Key.dictionaryLearning)
        self.isHoldGestureEnabled = defaults.bool(forKey: Key.holdGestureEnabled)
        // `.deferred` y no `.live`: el fallback tiene que coincidir con lo registrado y con
        // §7. Con `.live` aquí, un valor ilegible en las preferencias —o un registro que no
        // llegara a correr— estrenaba la función en el modo que el diseño reserva para
        // cuando hay medición que lo respalde.
        self.dictationMode = DictationMode(
            rawValue: defaults.string(forKey: Key.dictationMode) ?? ""
        ) ?? .deferred
    }

    var retentionPolicy: RetentionPolicy {
        RetentionPolicy(
            maximumAge: retentionDays > 0 ? TimeInterval(retentionDays) * 86_400 : nil,
            maximumBytes: retentionGigabytes > 0
                ? Int(retentionGigabytes * 1024 * 1024 * 1024)
                : nil,
            maximumCount: nil
        )
    }
}
