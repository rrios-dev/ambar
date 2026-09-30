import Foundation
import Testing

@testable import VoiceKit

/// F1 — la máquina de estados de una sesión de dictado.
///
/// Lo que se prueba aquí no es «que el enum tenga casos»: es que **el micrófono
/// solo pueda estar abierto en un estado**, y que el camino hasta él pase
/// obligatoriamente por la confirmación del usuario. Es la traducción a código de
/// la promesa de privacidad del producto, y la única forma de que siga siendo
/// verdad dentro de seis meses.
@Suite("Sesión de dictado — máquina de estados")
struct SessionStateTests {

    /// Muestra representativa de cada evento, con un valor por variante de payload.
    ///
    /// Se usa para explorar el grafo: no hace falta que sea exhaustiva en valores,
    /// sí en **formas** de evento.
    static let allEvents: [DictationEvent] = [
        .gestureBegan,
        .startRequested,
        .discardRequested,
        .gestureProgressed(0),
        .gestureProgressed(0.5),
        .gestureProgressed(1),
        .gestureCancelled(.releasedEarly),
        .gestureCancelled(.pointerMoved),
        .gestureCancelled(.panelDismissed),
        .gestureCompleted,
        .preparationFinished,
        .stopRequested,
        .finalizationFinished(Transcript(text: "hola", mode: .live)),
        .finalizationTimedOut(Transcript(text: "hola", mode: .live, wasTruncated: true)),
        .failed(.engineFailed),
        .failed(.audioDeviceChanged),
        .failed(.permissionDenied),
    ]

    /// Todos los estados a los que se puede llegar desde `idle` aplicando eventos.
    ///
    /// Recorrido en anchura sobre el grafo real en lugar de una lista escrita a
    /// mano: si alguien añade un estado alcanzable, aparece aquí solo, y los
    /// invariantes se comprueban también sobre él. Una lista a mano se queda
    /// obsoleta en el primer cambio y da una falsa sensación de cobertura.
    static func reachableStates() -> [DictationSessionState] {
        var discovered: [DictationSessionState] = [.idle]
        var frontier: [DictationSessionState] = [.idle]

        while let state = frontier.popLast() {
            for event in allEvents {
                guard let next = reduce(state, event) else { continue }
                if !discovered.contains(next) {
                    discovered.append(next)
                    frontier.append(next)
                }
            }
        }
        return discovered
    }

    // MARK: - El invariante que sostiene la promesa

    @Test("el micrófono solo está abierto mientras se escucha")
    func microphoneOnlyOpenWhileListening() {
        let states = Self.reachableStates()

        // Si esto falla es que el grafo se ha quedado sin explorar: el resto de
        // las comprobaciones serían vacías y pasarían igual.
        #expect(states.count >= 6, "el recorrido no está descubriendo el grafo")

        for state in states {
            if case .listening = state {
                #expect(state.isMicrophoneOpen, "escuchando sin micrófono abierto")
            } else {
                #expect(
                    !state.isMicrophoneOpen,
                    "micrófono abierto en un estado que no es escuchar: \(state)"
                )
            }
        }
    }

    @Test("el panel no puede cerrarse con una sesión que ya toca el motor")
    func panelDismissalInhibitedWhileSessionLive() {
        for state in Self.reachableStates() {
            switch state {
            case .preparing, .listening, .finalizing:
                #expect(
                    state.inhibitsPanelDismissal,
                    "el panel podría cerrarse en \(state) y dejar la sesión huérfana"
                )
            case .idle, .arming, .delivered, .failed:
                // En `arming` cerrar el panel es una cancelación legítima: no hay
                // nada abierto todavía.
                #expect(!state.inhibitsPanelDismissal)
            }
        }
    }

    // MARK: - El camino hasta el micrófono

    @Test("no se llega a escuchar sin completar el gesto")
    func cannotListenWithoutCompletingGesture() {
        // Desde la cuenta, ningún evento que no sea completarla lleva a escuchar.
        let arming = DictationSessionState.arming(progress: 0.9, prepared: true)

        for event in Self.allEvents {
            guard let next = reduce(arming, event) else { continue }
            if case .listening = next {
                #expect(
                    event == .gestureCompleted,
                    "se llega a escuchar con \(event), que no es la confirmación"
                )
            }
        }
    }

    @Test("si el modelo se cargó durante la cuenta, se escucha sin espera")
    func preparedDuringArmingSkipsPreparing() throws {
        var state = DictationSessionState.idle
        state = try #require(reduce(state, .gestureBegan))
        state = try #require(reduce(state, .gestureProgressed(0.4)))
        // El modelo termina de cargarse mientras el usuario mantiene el atajo:
        // esto es lo que compra `prepareToAnalyze` durante la transición.
        state = try #require(reduce(state, .preparationFinished))
        #expect(state == .arming(progress: 0.4, prepared: true))
        #expect(!state.isMicrophoneOpen, "la preparación no puede abrir el micrófono")

        state = try #require(reduce(state, .gestureCompleted))
        #expect(state == .listening)
    }

    @Test("si el modelo aún no está listo, se espera visiblemente y sin micrófono")
    func notPreparedGoesThroughPreparing() throws {
        var state = DictationSessionState.idle
        state = try #require(reduce(state, .gestureBegan))
        state = try #require(reduce(state, .gestureCompleted))

        #expect(state == .preparing)
        #expect(!state.isMicrophoneOpen, "se abriría el micrófono antes de tener modelo")

        state = try #require(reduce(state, .preparationFinished))
        #expect(state == .listening)
    }

    @Test("soltar durante la cuenta vuelve al reposo sin haber abierto nada")
    func cancellingArmingReturnsToIdle() throws {
        for cause in CancellationCause.allCases {
            var state = DictationSessionState.idle
            state = try #require(reduce(state, .gestureBegan))
            state = try #require(reduce(state, .gestureProgressed(0.7)))
            state = try #require(reduce(state, .gestureCancelled(cause)))
            #expect(state == .idle, "cancelar por \(cause) no vuelve al reposo")
        }
    }

    @Test("soltar mientras se espera al modelo cancela sin abrir el micrófono")
    func cancellingPreparingReturnsToIdle() throws {
        var state = DictationSessionState.idle
        state = try #require(reduce(state, .gestureBegan))
        state = try #require(reduce(state, .gestureCompleted))
        #expect(state == .preparing)

        state = try #require(reduce(state, .stopRequested))
        #expect(state == .idle)
    }

    @Test("la cuenta se mantiene entre 0 y 1")
    func armingProgressIsClamped() throws {
        var state = try #require(reduce(.idle, .gestureBegan))

        state = try #require(reduce(state, .gestureProgressed(-3)))
        #expect(state == .arming(progress: 0, prepared: false))

        state = try #require(reduce(state, .gestureProgressed(42)))
        #expect(state == .arming(progress: 1, prepared: false))
    }

    // MARK: - Entrega

    @Test("la finalización entrega, tanto si acaba como si vence el techo")
    func finalizationAlwaysDelivers() throws {
        let complete = Transcript(text: "con formato", mode: .live)
        let truncated = Transcript(text: "con form", mode: .live, wasTruncated: true)

        for (event, expected) in [
            (DictationEvent.finalizationFinished(complete), complete),
            (DictationEvent.finalizationTimedOut(truncated), truncated),
        ] {
            var state = DictationSessionState.idle
            state = try #require(reduce(state, .gestureBegan))
            state = try #require(reduce(state, .preparationFinished))
            state = try #require(reduce(state, .gestureCompleted))
            state = try #require(reduce(state, .stopRequested))
            #expect(state == .finalizing)

            state = try #require(reduce(state, event))
            #expect(state == .delivered(expected))
            #expect(!state.isMicrophoneOpen, "el micrófono sigue abierto tras entregar")
        }
    }

    @Test("lo entregado por techo queda marcado como posiblemente incompleto")
    func timedOutTranscriptIsMarked() throws {
        let truncated = Transcript(text: "medio", mode: .live, wasTruncated: true)
        var state = DictationSessionState.idle
        state = try #require(reduce(state, .gestureBegan))
        state = try #require(reduce(state, .preparationFinished))
        state = try #require(reduce(state, .gestureCompleted))
        state = try #require(reduce(state, .stopRequested))
        state = try #require(reduce(state, .finalizationTimedOut(truncated)))

        guard case .delivered(let transcript) = state else {
            Issue.record("no se entregó")
            return
        }
        #expect(transcript.wasTruncated, "se entrega sin decir que puede faltar texto")
    }

    // MARK: - Transiciones ilegales

    @Test("un evento imposible no cambia el estado a medias")
    func illegalTransitionsAreRejected() {
        let illegal: [(DictationSessionState, DictationEvent)] = [
            (.idle, .stopRequested),
            (.idle, .gestureCompleted),
            (.idle, .gestureProgressed(0.5)),
            (.idle, .preparationFinished),
            (.listening, .gestureBegan),
            (.listening, .gestureCompleted),
            (.finalizing, .stopRequested),
            (.preparing, .gestureCompleted),
        ]

        for (state, event) in illegal {
            #expect(
                reduce(state, event) == nil,
                "\(event) debería ser ilegal en \(state)"
            )
        }
    }

    @Test("un fallo sin sesión activa es ruido, no un fallo")
    func failureOnlyAppliesToActiveSessions() {
        // Desde reposo, un fallo del motor no debe pintar un error al usuario:
        // no había nada en marcha.
        #expect(reduce(.idle, .failed(.engineFailed)) == nil)

        // Con sesión en marcha sí corta, en cualquiera de sus fases.
        for state in [
            DictationSessionState.arming(progress: 0.2, prepared: false),
            .preparing,
            .listening,
            .finalizing,
        ] {
            #expect(reduce(state, .failed(.engineFailed)) == .failed(.engineFailed))
        }
    }

    /// Descartar es el control que evita que un gesto disparado sin querer acabe
    /// escribiendo en el documento de alguien. No tenía ni un test.
    @Test("descartar vuelve al reposo desde cualquier fase, sin entregar")
    func discardingReturnsToIdle() throws {
        for state in [
            DictationSessionState.arming(progress: 0.4, prepared: false),
            .preparing,
            .listening,
            .finalizing,
        ] {
            #expect(
                reduce(state, .discardRequested) == .idle,
                "descartar desde \(state) no vuelve al reposo"
            )
        }
        // Y no es legal cuando no hay nada que descartar.
        #expect(reduce(.idle, .discardRequested) == nil)
    }

    /// El camino sin gesto va directo a preparar: pasar por `.arming` pedía «mantén
    /// para dictar» a quien pulsó un botón por no poder mantener nada, y lo dejaba a
    /// merced de la cancelación por interacción.
    @Test("pedir dictado sin gesto va directo a preparar")
    func startRequestedSkipsArming() {
        #expect(reduce(.idle, .startRequested) == .preparing)
        #expect(reduce(.delivered(Transcript(text: "x", mode: .live)), .startRequested) == .preparing)
        #expect(reduce(.failed(.engineFailed), .startRequested) == .preparing)
        // No tiene sentido en mitad de una sesión.
        #expect(reduce(.listening, .startRequested) == nil)
    }

    /// La cuenta solo se pinta cuando ya ha avanzado: mostrarla en el instante 0
    /// insertaba y retiraba la banda en cada apertura del panel.
    @Test("la cuenta no se pinta hasta que ha avanzado de verdad")
    func armingIsNotDisplayedEarly() {
        // Con `> 0` el primer tick (40 ms → progreso 0,09) ya pintaba la banda, así
        // que una pulsación corriente del atajo la insertaba y la retiraba, saltando
        // la lista y ocultando el botón de micrófono.
        #expect(!DictationSessionState.arming(progress: 0, prepared: false).deservesDisplay)
        #expect(!DictationSessionState.arming(progress: 0.09, prepared: false).deservesDisplay)
        #expect(!DictationSessionState.arming(progress: 0.2, prepared: false).deservesDisplay)
        #expect(DictationSessionState.arming(progress: 0.5, prepared: false).deservesDisplay)
        #expect(DictationSessionState.arming(progress: 1, prepared: false).deservesDisplay)
    }

    @Test("tras entregar o fallar se puede volver a dictar")
    func sessionsAreRepeatable() throws {
        let delivered = DictationSessionState.delivered(
            Transcript(text: "uno", mode: .deferred)
        )
        #expect(reduce(delivered, .gestureBegan) == .arming(progress: 0, prepared: false))

        let failed = DictationSessionState.failed(.engineFailed)
        #expect(reduce(failed, .gestureBegan) == .arming(progress: 0, prepared: false))
    }
}
