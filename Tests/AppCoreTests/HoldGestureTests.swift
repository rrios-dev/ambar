import AppKit
import Carbon.HIToolbox
import Testing

@testable import AppCore

/// F3 — el gesto de mantener el atajo.
///
/// El test central es el del atajo configurable: la auditoría marcó como
/// bloqueante que la detección fijara ⇧⌘ por constante, porque con ⌃⌘V —el atajo
/// que usa hoy el autor de la app— el gesto no se dispararía nunca. El fallo sería
/// silencioso y solo lo sufriría quien hubiera cambiado el atajo.
@Suite("Gesto de mantener el atajo")
struct HoldGestureTests {

    // MARK: - La máscara sale del atajo, no de una constante

    @Test("la máscara se deriva del atajo configurado, sea el que sea")
    func maskDerivesFromCombination() {
        let cases: [(String, UInt32, NSEvent.ModifierFlags)] = [
            ("⇧⌘V (el de fábrica)", UInt32(cmdKey | shiftKey), [.command, .shift]),
            ("⌃⌘V (el del autor)", UInt32(cmdKey | controlKey), [.command, .control]),
            ("⌥⌘V", UInt32(cmdKey | optionKey), [.command, .option]),
            ("⌃⌥⌘V", UInt32(cmdKey | optionKey | controlKey), [.command, .option, .control]),
            ("⌃⇧V", UInt32(controlKey | shiftKey), [.control, .shift]),
        ]

        for (name, carbon, expected) in cases {
            let gesture = HoldGesture(
                combination: KeyCombination(keyCode: UInt32(kVK_ANSI_V), modifiers: carbon)
            )
            #expect(gesture.watchedFlags == expected, "máscara incorrecta para \(name)")
        }
    }

    /// Éste es el bloqueante convertido en test.
    @Test("con ⌃⌘V el gesto se detecta; con la máscara fija de ⇧⌘ no se detectaría")
    func controlCommandShortcutIsDetected() {
        let controlCommand = HoldGesture(
            combination: KeyCombination(
                keyCode: UInt32(kVK_ANSI_V),
                modifiers: UInt32(cmdKey | controlKey)
            )
        )
        // El usuario mantiene ⌃⌘ pulsados.
        let held: NSEvent.ModifierFlags = [.command, .control]
        #expect(controlCommand.stillHeld(flags: held))

        // Lo que hacía la versión anterior del diseño: vigilar ⇧⌘ siempre.
        let hardcoded = HoldGesture(watchedFlags: [.command, .shift], threshold: .milliseconds(500))
        #expect(
            !hardcoded.stillHeld(flags: held),
            "vigilar ⇧⌘ con un atajo ⌃⌘ no puede dar positivo: es el bloqueante"
        )
    }

    // MARK: - Robustez de la comparación

    @Test("los modificadores irrelevantes no rompen el gesto")
    func irrelevantFlagsAreIgnored() {
        let gesture = HoldGesture(
            combination: KeyCombination(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(cmdKey | shiftKey))
        )
        // Alguien con Bloq Mayús activado, o con el teclado numérico implicado,
        // tiene que poder dictar igual. Exigir igualdad exacta lo excluiría.
        #expect(gesture.stillHeld(flags: [.command, .shift, .capsLock]))
        #expect(gesture.stillHeld(flags: [.command, .shift, .numericPad]))
        #expect(gesture.stillHeld(flags: [.command, .shift, .function, .capsLock]))
    }

    @Test("soltar cualquiera de los modificadores termina el gesto")
    func releasingAnyModifierEndsGesture() {
        let gesture = HoldGesture(
            combination: KeyCombination(
                keyCode: UInt32(kVK_ANSI_V),
                modifiers: UInt32(cmdKey | optionKey | controlKey)
            )
        )
        #expect(gesture.stillHeld(flags: [.command, .option, .control]))
        #expect(!gesture.stillHeld(flags: [.command, .option]))
        #expect(!gesture.stillHeld(flags: [.command]))
        #expect(!gesture.stillHeld(flags: []))
    }

    @Test("un atajo sin modificadores no puede sostener un gesto")
    func emptyMaskNeverHolds() {
        // El grabador no permite atajos sin ⌘/⌃/⌥, pero si algún día lo hiciera,
        // «mantener» no significaría nada: mejor que no se dispare que que se
        // dispare siempre.
        let gesture = HoldGesture(watchedFlags: [], threshold: .milliseconds(500))
        #expect(!gesture.stillHeld(flags: []))
        #expect(!gesture.stillHeld(flags: [.command, .shift]))
    }

    // MARK: - El umbral no depende de la animación

    @Test("el avance se calcula sobre el umbral y se acota")
    func ratioIsClamped() {
        let threshold = Duration.milliseconds(500)
        #expect(HoldGestureTracker.ratio(of: .zero, over: threshold) == 0)
        #expect(abs(HoldGestureTracker.ratio(of: .milliseconds(250), over: threshold) - 0.5) < 0.001)
        #expect(HoldGestureTracker.ratio(of: .milliseconds(500), over: threshold) == 1)
        // Pasarse no da más de 1.
        #expect(HoldGestureTracker.ratio(of: .seconds(5), over: threshold) == 1)
        // Un umbral degenerado completa en vez de dividir por cero.
        #expect(HoldGestureTracker.ratio(of: .milliseconds(10), over: .zero) == 1)
    }

    @Test("el umbral es un valor propio, independiente de cualquier animación")
    func thresholdIsItsOwnValue() {
        // Si algún día el umbral se deriva de una duración de animación, este test
        // deja de tener sentido — y ése es justamente el error que evita: con
        // «Reducir movimiento» no hay animación y el gesto tiene que seguir
        // teniendo la misma duración.
        let a = HoldGesture(
            combination: KeyCombination(keyCode: 9, modifiers: UInt32(cmdKey | shiftKey))
        )
        #expect(a.threshold == HoldGesture.provisionalThreshold)

        let b = HoldGesture(
            combination: KeyCombination(keyCode: 9, modifiers: UInt32(cmdKey | shiftKey)),
            threshold: .milliseconds(900)
        )
        #expect(b.threshold == .milliseconds(900))
        #expect(b.watchedFlags == a.watchedFlags)
    }

    // MARK: - Seguimiento

    @MainActor
    @Test("mantener hasta el final confirma el gesto")
    func holdingCompletes() async {
        var updates: [HoldGestureUpdate] = []
        // El reloj se inyecta en lugar de confiar en el planificador: con la suite
        // completa en paralelo, los `Task.sleep` se retrasan y el primer tick podía
        // rebasar ya el umbral, dejando el test sin avances intermedios que
        // comprobar. Un reloj controlado hace la comprobación determinista sin
        // aflojar lo que se afirma.
        let base = ContinuousClock.now
        var elapsed = Duration.zero
        let tracker = HoldGestureTracker(
            gesture: HoldGesture(watchedFlags: [.command, .shift], threshold: .milliseconds(100)),
            tick: .milliseconds(5),
            now: {
                elapsed += .milliseconds(20)
                return base.advanced(by: elapsed)
            },
            heldProvider: { true }
        )
        tracker.begin { updates.append($0) }

        // Se espera por la CONDICIÓN, no por el reloj. Con una dormida fija de 400 ms este
        // test falló 2 de 8 pasadas: el reloj del tracker es falso, pero sus tics son
        // tareas reales, y con el actor principal saturado por la suite en paralelo solo
        // llegaban dos de los cinco. Un test intermitente no es una red de seguridad —y
        // además envenena cualquier medición por mutación, porque un rojo deja de
        // significar «la mutación se detectó».
        // El diagnóstico de arriba era correcto y el plazo se quedó corto igualmente: en el
        // runner de CI —una VM, más lenta que la máquina donde se escribió esto— llegaron
        // TRES tics en cinco segundos, y el gesto se quedó en `progress(0.4)`.
        //
        // Se cambian dos cosas, y la primera importa más que la segunda: **sondear cada
        // 25 ms en vez de cada 5**. Este bucle vive en el mismo actor principal que los
        // tics del tracker, así que despertar cinco veces más a menudo es quitarles turnos
        // justo a lo que se está esperando. Menos sondeo, más sitio para que progresen.
        //
        // Y el plazo a 30 s, que no afloja nada: si el gesto no confirma, esto falla igual.
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while !updates.contains(.completed), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(25))
        }
        #expect(updates.contains(.completed), "no se confirmó: \(updates)")
        #expect(!tracker.isTracking, "el seguimiento sigue vivo tras confirmar")
        // Y por el camino informó del avance, que es lo que la interfaz pinta.
        let progresses = updates.compactMap { update -> Double? in
            if case .progress(let value) = update { return value }
            return nil
        }
        #expect(progresses.first == 0, "la realimentación no empieza en el primer instante")
        #expect(progresses.count >= 2, "sin avance intermedio no hay nada que enseñar")
    }

    @MainActor
    @Test("soltar antes del umbral cancela y no confirma")
    func releasingBeforeThresholdCancels() async {
        var updates: [HoldGestureUpdate] = []
        let held = TestBox(true)
        let tracker = HoldGestureTracker(
            gesture: HoldGesture(watchedFlags: [.command, .shift], threshold: .seconds(5)),
            tick: .milliseconds(20),
            heldProvider: { held.value }
        )
        tracker.begin { updates.append($0) }
        try? await Task.sleep(for: .milliseconds(60))
        held.value = false
        try? await Task.sleep(for: .milliseconds(120))

        #expect(updates.contains(.cancelled(.released)))
        #expect(!updates.contains(.completed), "confirmó un gesto que se soltó")
        #expect(!tracker.isTracking)
    }

    @MainActor
    @Test("cualquier interacción cancela la cuenta")
    func anyInteractionCancels() async {
        // Es lo que evita que el gesto se dispare mientras el ojo busca en la
        // lista: quien busca algo hace algo, quien quiere dictar se queda quieto.
        for cause in HoldGestureCancellation.allCases where cause != .released {
            var updates: [HoldGestureUpdate] = []
            let tracker = HoldGestureTracker(
                gesture: HoldGesture(watchedFlags: [.command], threshold: .seconds(5)),
                tick: .milliseconds(20),
                heldProvider: { true }
            )
            tracker.begin { updates.append($0) }
            tracker.cancel(cause) { updates.append($0) }

            #expect(updates.contains(.cancelled(cause)), "no canceló por \(cause)")
            #expect(!tracker.isTracking)

            try? await Task.sleep(for: .milliseconds(80))
            #expect(!updates.contains(.completed), "siguió contando tras cancelar por \(cause)")
        }
    }

    @MainActor
    @Test("cancelar sin gesto en curso no hace nada")
    func cancellingIdleTrackerIsHarmless() {
        var updates: [HoldGestureUpdate] = []
        let tracker = HoldGestureTracker(
            gesture: HoldGesture(watchedFlags: [.command], threshold: .seconds(1)),
            heldProvider: { true }
        )
        tracker.cancel(.pointerMoved) { updates.append($0) }
        #expect(updates.isEmpty, "notificó una cancelación que no ocurrió")
    }

    @MainActor
    @Test("empezar de nuevo descarta el gesto anterior")
    func restartingSupersedesPreviousGesture() async {
        var first: [HoldGestureUpdate] = []
        var second: [HoldGestureUpdate] = []
        let tracker = HoldGestureTracker(
            gesture: HoldGesture(watchedFlags: [.command], threshold: .milliseconds(120)),
            tick: .milliseconds(20),
            heldProvider: { true }
        )
        tracker.begin { first.append($0) }
        tracker.begin { second.append($0) }

        // Espera acotada, no dormida fija: el sondeo corre en el hilo principal y con la
        // suite entera en marcha 400 ms no siempre bastaban. Un test que depende de la
        // carga de la máquina acaba enseñando a ignorar los rojos.
        // Mismo ajuste que en «mantener hasta el final», y por el mismo motivo medido: el
        // sondeo comparte actor con los tics que espera, así que se sondea cada 25 ms en
        // lugar de cada 10, y el plazo sube a 30 s. Este usa el reloj REAL —no inyecta
        // `now`—, así que depende del planificador aún más que su hermano.
        let deadline = ContinuousClock.now.advanced(by: .seconds(30))
        while ContinuousClock.now < deadline, !second.contains(.completed) {
            try? await Task.sleep(for: .milliseconds(25))
        }
        #expect(second.contains(.completed))
        #expect(!first.contains(.completed), "el gesto viejo confirmó por su cuenta")
    }
}

/// F3 — cuándo puede el panel cerrarse al perder el foco.
///
/// Los dos casos que cubre fueron bloqueantes de la auditoría, y los dos acaban
/// en el mismo sitio: el micrófono abierto sin nada en pantalla que lo diga.
@Suite("Cierre del panel durante el dictado")
struct PanelDismissalTests {

    @Test("sin dictado, el panel se cierra como siempre")
    func defaultBehaviourUnchanged() {
        #expect(PanelDismissalPolicy.default.shouldHideOnResignKey)
    }

    @Test("con una sesión viva el panel no puede cerrarse")
    func activeSessionKeepsPanelOpen() {
        // Cerrarlo dejaría el micrófono abierto y el indicador del sistema
        // apuntando a una app sin icono en el Dock.
        let policy = PanelDismissalPolicy(dictationSessionActive: true)
        #expect(!policy.shouldHideOnResignKey)
    }

    @Test("mientras se pide el permiso, el diálogo del sistema no cierra el panel")
    func permissionPromptKeepsPanelOpen() {
        // El diálogo de TCC roba la condición de ventana clave: sin esto, el
        // usuario concede el permiso y se queda sin panel delante.
        let policy = PanelDismissalPolicy(permissionPromptInFlight: true)
        #expect(!policy.shouldHideOnResignKey)
    }

    @Test("cualquiera de los dos motivos basta")
    func eitherReasonIsEnough() {
        for policy in [
            PanelDismissalPolicy(dictationSessionActive: true, permissionPromptInFlight: false),
            PanelDismissalPolicy(dictationSessionActive: false, permissionPromptInFlight: true),
            PanelDismissalPolicy(dictationSessionActive: true, permissionPromptInFlight: true),
        ] {
            #expect(!policy.shouldHideOnResignKey)
        }
    }
}

/// El tic de sondeo **de producción**, que ningún test ejercitaba.
///
/// Los cinco tests del seguimiento inyectan su propio tic para no depender del reloj, así
/// que el valor real —el que usa el único consumidor, `DictationController`— no lo
/// afirmaba nadie: subirlo a 400 ms dejaba la suite entera en verde. Lo encontró una
/// auditoría independiente.
@Suite("El tic de sondeo del gesto")
struct HoldGestureTickTests {

    @MainActor
    @Test("el tic de producción mantiene la promesa de los 350 ms para soltar")
    func productionTickKeepsTheReleaseWindow() {
        // §8.4: la banda aparece al 33 % del umbral y quedan ~350 ms de los 550 para
        // soltar. El tic acota la resolución de esa cuenta, así que un tic grande se come
        // esa ventana sin que nada más cambie.
        let threshold = HoldGesture.provisionalThreshold
        let tick = HoldGestureTracker.defaultTick

        // La banda no puede aparecer más de un tic tarde respecto al umbral del 33 %.
        let displayPoint = threshold * DictationDisplayThreshold.fraction
        let worstCaseDisplay = displayPoint + tick
        let remaining = threshold - worstCaseDisplay

        #expect(
            remaining >= .milliseconds(250),
            "con un tic de \(tick) solo quedan \(remaining) para soltar, no los ~350 ms que promete §8.4"
        )
    }
}

/// El 33 % vive en `VoiceKit` (`DictationSessionState.armingDisplayThreshold`) y este
/// target no depende de él, así que se replica aquí **como constante local declarada**, no
/// como número suelto: si un día divergen, el test de arriba pierde sentido y este
/// comentario es la señal de dónde mirar.
enum DictationDisplayThreshold {
    static let fraction = 0.33
}

/// Valor mutable que un cierre `@Sendable` puede leer mientras el test lo cambia.
///
/// Swift 6 avisa —«mutated after capture by sendable closure»— cuando un test captura una
/// `var` local en un `heldProvider` y luego la modifica: es una carrera real aunque en la
/// práctica ambos lados corran en el hilo principal. El aviso tenía razón y estaba
/// silenciado por costumbre; el cerrojo lo resuelve sin cambiar lo que el test prueba.
final class TestBox<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}
