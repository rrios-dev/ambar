import AppKit
import Carbon.HIToolbox

/// El gesto de «mantener el atajo» que lleva del historial al dictado.
///
/// La detección se apoya en `NSEvent.modifierFlags`, cuya cabecera dice que
/// devuelve el estado de los dispositivos «independent of which events have been
/// delivered via the event stream». Eso significa dos cosas que hacen viable todo
/// esto: **no depende del foco** y **no exige ningún permiso**. No es una técnica
/// a confirmar — `Paster.waitForModifiersToClear` ya la usa en producción.
///
/// Lo que sí hay que hacer bien es **de dónde salen los modificadores a vigilar**.
public struct HoldGesture: Sendable, Equatable {
    /// Modificadores que deben seguir pulsados para que el gesto siga vivo.
    public let watchedFlags: NSEvent.ModifierFlags

    /// Cuánto hay que mantener para confirmar.
    ///
    /// Es un **valor propio**, no la duración de una animación. La animación lo
    /// representa; con «Reducir movimiento» no hay animación y el umbral sigue
    /// siendo el mismo. Atarlo a la animación dejaría el gesto sin definición
    /// justo para quien más necesita previsibilidad.
    public let threshold: Duration

    /// Umbral por defecto, **provisional**: el diseño exige ajustarlo observando
    /// a gente real hasta que el gesto se entienda sin instrucciones. Se parte de
    /// algo que no pise el tiempo que se tarda en leer la lista del historial.
    public static let provisionalThreshold: Duration = .milliseconds(550)

    /// Deriva el gesto del atajo **que el usuario tenga configurado**.
    ///
    /// Fijar aquí ⇧⌘ por constante fue un bloqueante de la auditoría: el grabador
    /// acepta cualquier combinación con al menos uno de ⌘/⌃/⌥
    /// (`ShortcutRecorder.validate`), así que con ⌃⌘V —una elección
    /// perfectamente normal— vigilar ⇧ daría siempre falso y el gesto no se
    /// dispararía **nunca**, en silencio y solo para quien cambió el atajo.
    public init(combination: KeyCombination, threshold: Duration = HoldGesture.provisionalThreshold) {
        self.watchedFlags = Self.modifierFlags(fromCarbon: combination.modifiers)
        self.threshold = threshold
    }

    public init(watchedFlags: NSEvent.ModifierFlags, threshold: Duration) {
        self.watchedFlags = watchedFlags
        self.threshold = threshold
    }

    /// Traduce los modificadores de Carbon —que es como los guarda
    /// `KeyCombination`— a los de AppKit, que es como los reporta el hardware.
    public static func modifierFlags(fromCarbon carbon: UInt32) -> NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if carbon & UInt32(cmdKey) != 0 { flags.insert(.command) }
        if carbon & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if carbon & UInt32(optionKey) != 0 { flags.insert(.option) }
        if carbon & UInt32(controlKey) != 0 { flags.insert(.control) }
        return flags
    }

    /// ¿Siguen pulsados los modificadores del atajo?
    ///
    /// Se comparan **solo** los cuatro modificadores del atajo. El estado del
    /// hardware trae además bits que no vienen al caso —bloqueo de mayúsculas,
    /// teclado numérico, teclas de función— y exigir igualdad exacta rompería el
    /// gesto a cualquiera que tenga Bloq Mayús activado.
    public func stillHeld(flags: NSEvent.ModifierFlags) -> Bool {
        guard !watchedFlags.isEmpty else { return false }
        return flags.intersection(watchedFlags) == watchedFlags
    }

    /// Estado del hardware ahora mismo. Sin permisos, sin depender del foco.
    @MainActor
    public func stillHeldNow() -> Bool {
        stillHeld(flags: NSEvent.modifierFlags)
    }
}

/// ¿Tiene el sistema los modificadores «enclavados»?
///
/// *Teclas Especiales* (Sticky Keys) mantiene los modificadores activos tras
/// soltarlos —es literalmente su función— y `NSEvent.modifierFlags` los reporta
/// hundidos. Con eso, cualquier apertura del panel supera el umbral del gesto y
/// **abre el micrófono sin que nadie mantenga nada**.
///
/// Y la persona afectada es la que menos va a relacionar «se me abre el micrófono»
/// con un ajuste de accesibilidad, así que no basta con ofrecer una casilla: hay que
/// desactivar el disparo por gesto por defecto cuando esto es cierto.
public enum StickyKeys {
    /// De dónde se lee el ajuste. Sustituible en tests: sin esto, la mitigación no se
    /// puede comprobar sin cambiar los ajustes de accesibilidad de la máquina.
    @MainActor public static var reader: () -> Bool = {
        UserDefaults(suiteName: "com.apple.universalaccess")?
            .bool(forKey: "stickyKey") ?? false
    }

    /// ¿Están los modificadores enclavados por el sistema?
    ///
    /// Si la lectura falla se responde `false`: desactivar el gesto por no poder leer
    /// un ajuste sería peor que dejarlo.
    @MainActor
    public static var isEnabled: Bool { reader() }
}

/// Por qué se abandonó el gesto.
///
/// La causa se distingue porque **cualquier interacción cancela la cuenta**: quien
/// busca algo en el historial mueve el ratón, teclea o pulsa una flecha; quien
/// quiere dictar se queda quieto. Sin esa regla el gesto se dispararía en el flujo
/// más común de la app, porque mucha gente no suelta el atajo mientras el ojo
/// recorre la lista.
public enum HoldGestureCancellation: String, Sendable, Equatable, CaseIterable {
    /// Se soltaron los modificadores. Es el caso normal.
    case released
    case pointerMoved
    case typed
    case navigated
    case scrolled
    case panelDismissed
}

/// Lo que el seguimiento del gesto va reportando.
public enum HoldGestureUpdate: Sendable, Equatable {
    /// Avance de 0 a 1. La interfaz lo representa animado o por pasos.
    case progress(Double)
    /// Se mantuvo hasta el final: el usuario confirma que quiere dictar.
    case completed
    case cancelled(HoldGestureCancellation)
}

/// Sigue el gesto mientras el panel está abierto.
///
/// Vive en el actor principal porque solo tiene sentido con el panel delante, y
/// porque `NSEvent.modifierFlags` se consulta desde ahí.
///
/// La detección es **sondeo**, a 40 ms, y conviene decirlo tal cual: no hay ningún
/// monitor de `.flagsChanged`. Un monitor de eventos costaría menos energía y estuvo
/// escrito aquí como si existiera, que es peor que no tenerlo — el siguiente lector
/// habría dado por hecho que el temporizador era solo una red.
///
/// Por qué el sondeo es aceptable: solo corre con el panel abierto, y el peor caso son 25
/// despertares por segundo en una ventana de medio segundo — la cuenta del gesto y nada
/// más.
///
/// Lo que **no** sería aceptable es que durara toda la sesión de escucha. Este comentario
/// decía «y eso sigue pendiente» mucho después de dejar de estarlo: `beginListening()` no
/// arranca ningún seguimiento, y quien leyera esto se iba a buscar una deuda saldada. Un
/// comentario que mantiene viva una deuda inexistente cuesta el mismo tiempo que una real.
@MainActor
public final class HoldGestureTracker {
    private let gesture: HoldGesture
    private let tick: Duration
    private let now: @MainActor () -> ContinuousClock.Instant
    private let heldProvider: @MainActor () -> Bool
    private var task: Task<Void, Never>?
    private var startedAt: ContinuousClock.Instant?

    /// - Parameters:
    ///   - heldProvider: de dónde se lee si el atajo sigue pulsado. Inyectable
    ///     para poder probar el seguimiento sin un teclado de verdad.
    /// Cada cuánto se comprueba si el atajo sigue pulsado, **en producción**.
    ///
    /// No es un número libre: la banda aparece al 33 % del umbral (§8.4) y la promesa es
    /// que queden ~350 ms de los 550 para soltar sin disparar el dictado. El tic acota la
    /// resolución de esa cuenta — con un tic de 400 ms la banda no aparecería hasta los
    /// 400 y quedarían 150 ms, no 350. Está nombrado y afirmado (`HoldGestureTests`)
    /// porque los cinco tests del seguimiento inyectan el suyo, así que el valor real de
    /// producción no lo ejercitaba nadie: subirlo a 400 ms dejaba la suite verde.
    public static let defaultTick: Duration = .milliseconds(40)

    public init(
        gesture: HoldGesture,
        tick: Duration = HoldGestureTracker.defaultTick,
        now: @escaping @MainActor () -> ContinuousClock.Instant = { ContinuousClock.now },
        heldProvider: (@MainActor () -> Bool)? = nil
    ) {
        self.gesture = gesture
        self.tick = tick
        self.now = now
        // Se delega en `stillHeld` en lugar de repetir la comprobación: la versión
        // anterior usaba `contains(watchedFlags)`, que con una máscara vacía es
        // SIEMPRE cierto, así que el tracker confirmaba el gesto al instante
        // mientras `stillHeldNow()` decía lo contrario.
        self.heldProvider = heldProvider ?? { gesture.stillHeld(flags: NSEvent.modifierFlags) }
    }

    public var isTracking: Bool { task != nil }

    /// Empieza a contar. `update` recibe el avance hasta que se confirme o se
    /// cancele; después, el seguimiento se detiene solo.
    public func begin(update: @escaping @MainActor (HoldGestureUpdate) -> Void) {
        cancel(.released, notifying: nil)
        let start = now()
        startedAt = start
        update(.progress(0))

        task = Task { @MainActor [weak self] in
            while let self, !Task.isCancelled {
                try? await Task.sleep(for: self.tick)
                if Task.isCancelled { return }
                guard self.startedAt == start else { return }

                guard self.heldProvider() else {
                    self.finish()
                    update(.cancelled(.released))
                    return
                }

                let elapsed = self.now() - start
                let ratio = Self.ratio(of: elapsed, over: self.gesture.threshold)
                if ratio >= 1 {
                    self.finish()
                    update(.completed)
                    return
                }
                update(.progress(ratio))
            }
        }
    }

    /// Aborta la cuenta. Lo llama la interfaz ante cualquier interacción.
    public func cancel(
        _ cause: HoldGestureCancellation,
        notifying update: (@MainActor (HoldGestureUpdate) -> Void)?
    ) {
        guard task != nil else { return }
        finish()
        update?(.cancelled(cause))
    }

    private func finish() {
        task?.cancel()
        task = nil
        startedAt = nil
    }

    /// Fracción de umbral transcurrida, acotada a [0, 1].
    ///
    /// `nonisolated` porque es aritmética pura: no toca el estado del seguimiento
    /// y obligar a saltar al actor principal para dividir dos duraciones solo
    /// complicaría a quien la use.
    nonisolated static func ratio(of elapsed: Duration, over threshold: Duration) -> Double {
        let elapsedSeconds = Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1e18
        let thresholdSeconds = Double(threshold.components.seconds)
            + Double(threshold.components.attoseconds) / 1e18
        guard thresholdSeconds > 0 else { return 1 }
        return min(max(elapsedSeconds / thresholdSeconds, 0), 1)
    }
}
