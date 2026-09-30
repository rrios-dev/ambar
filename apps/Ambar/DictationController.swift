import AppCore
import AppKit
import Foundation
import Observation
import SwiftUI
import VoiceKit

/// Gobierna el dictado dentro de la app: une el gesto, el motor y la entrega.
///
/// Se apoya en la máquina de estados de `VoiceKit` en lugar de llevar su propia
/// contabilidad. Esa máquina es la que garantiza que **el micrófono solo se abra
/// en `listening`**, así que aquí no se decide nada sobre eso: se traducen sucesos
/// a eventos y se obedece el estado resultante.
///
/// El reparto temporal es lo que hace que el gesto se sienta inmediato:
///
/// 1. El atajo se pulsa → empieza la cuenta **y**, en paralelo, la carga del
///    modelo. Cargar es lo caro y no toca el micrófono.
/// 2. La cuenta llega al final → se abre la entrada de audio, que es lo único que
///    enciende el indicador del sistema.
/// 3. Se suelta el atajo → se espera la finalización, con techo, y se entrega.
@MainActor
@Observable
final class DictationController {
    /// Estado de la sesión. La interfaz pinta a partir de aquí.
    private(set) var state: DictationSessionState = .idle

    /// Texto que se va refinando mientras se habla. Vive en el panel, nunca se
    /// escribe en la app de destino hasta que es definitivo.
    private(set) var liveText: String = ""

    /// ¿Lo que se está mostrando es todavía una hipótesis del motor?
    ///
    /// `isVolatile` se producía, viajaba por el protocolo y **nadie lo leía**, con un
    /// comentario afirmando que «gobierna toda la interfaz del modo en vivo». Medido con
    /// el motor real: de once resultados de una frase, diez son volátiles y solo el último
    /// es final, así que el panel pintaba diez hipótesis con exactamente el mismo aspecto
    /// que el texto definitivo.
    ///
    /// La diferencia importa justo al final, que es cuando pasa a firme: es la señal de
    /// «esto ya no va a cambiar» y de que soltar es seguro.
    private(set) var liveTextIsVolatile = false

    /// How many characters at the end of `liveText` are still the engine's hypothesis.
    ///
    /// This is the boundary the expanded transcript draws — and, later, the boundary
    /// the editor refuses to cross: the firm prefix is stable by engine contract, the
    /// tail gets rewritten wholesale on the next result.
    private(set) var liveVolatileCharacters = 0

    /// Whether the panel shows the transcript in full instead of the three-line tail.
    ///
    /// Session-scoped interface state, owned here and not by the view: the view is
    /// recreated on every render, and the panel's keyboard layer needs somewhere
    /// stable to address when a shortcut toggles it.
    private(set) var isTranscriptExpanded = false

    func toggleTranscriptExpansion() {
        isTranscriptExpanded.toggle()
        // Closing the transcript closes any editor inside it. Without this the panel
        // would keep yielding its keyboard to a field that no longer exists — and ⎋
        // would stop closing the panel, with nothing on screen explaining why.
        if !isTranscriptExpanded { isEditingWord = false }
    }

    /// Is an inline word editor open right now?
    ///
    /// The panel installs a **local key monitor** that intercepts keyDown before it
    /// reaches the focused view, and it claims ⏎, ⎋, ↑, ↓ and ⌘⌫ for the history.
    /// While a word editor is open those keys belong to the field instead — without
    /// this flag, pressing ⏎ to commit a correction STOPPED the dictation and ⎋ closed
    /// the whole panel. Measured by reading the monitor: it is why editing looked
    /// dead even once the field appeared.
    private(set) var isEditingWord = false

    func setWordEditing(_ editing: Bool) {
        isEditingWord = editing
    }

    /// Último fallo, para poder contarlo.
    private(set) var lastFailure: DictationFailure?

    /// El motor, por protocolo y no por tipo concreto.
    ///
    /// No es purismo: sin esto el controlador no se puede probar sin micrófono ni
    /// framework de voz, y era la única pieza del dictado sin un solo test — justo
    /// donde vivían cinco de los seis bloqueantes de la auditoría.
    private let engine: any TranscriberEngine

    /// De dónde se lee el permiso de micrófono.
    ///
    /// Inyectable por la misma razón que el motor: sin esto, el coordinador no se
    /// puede probar en un proceso de test —que no tiene permiso concedido— y la
    /// comprobación que evita el «Escuchando» eterno haría fallar toda la suite.
    private let permission: @MainActor () -> MicrophonePermission

    /// ¿Pidió el usuario la pista de habla atípica? Se consulta en cada sesión, no se
    /// copia: cambiarla en Ajustes tiene que valer para el siguiente dictado.
    private let atypicalSpeech: @MainActor () -> Bool

    /// ¿Puede el dictado funcionar de verdad ahora mismo?
    ///
    /// Distinto de «está activado»: el interruptor puede estar encendido con el modelo sin
    /// instalar. Solo gobierna el **gesto**, que es el camino que nadie pidió; los caminos
    /// explícitos —⌘D y el botón del micrófono— siguen intentándolo y contando el fallo,
    /// porque ahí el usuario está esperando una respuesta.
    private let isReady: @MainActor () -> Bool

    /// The user's personal vocabulary, when dictation has one.
    ///
    /// Optional and injected: every existing test builds this controller without a
    /// dictionary, and dictation must work identically without one — the dictionary
    /// is an accelerator, never a dependency.
    private let vocabulary: PersonalDictionary?

    /// Corrections made by the user DURING this session, applied to every fragment
    /// that arrives after them. Session-scoped on purpose: what should outlive the
    /// session lives in the dictionary, and it gets there through learning, not
    /// through this list.
    private(set) var sessionCorrections: [VocabularyCorrector.Rule] = []

    /// Is automatic learning on? Consulted per edit, not copied, so flipping the
    /// Settings switch applies to the very next correction.
    private let learnsVocabulary: @MainActor () -> Bool

    /// A correction the dictionary just learned, while its feedback is on screen.
    struct LearnedCorrection: Equatable {
        let entry: DictionaryEntry
        let heard: String
    }

    /// What the "Aprendido" pill shows. Auto-clears after `learningFeedbackDuration`.
    private(set) var recentLearning: LearnedCorrection?
    private var learningDismissTask: Task<Void, Never>?

    /// How long the learning feedback stays up. Injectable so a test does not wait
    /// four real seconds to assert that it leaves on its own.
    private let learningFeedbackDuration: Duration
    static let defaultLearningFeedbackDuration: Duration = .seconds(4)

    /// Applies the user's inline correction to the transcript, everywhere.
    ///
    /// Three effects, in an order that matters:
    ///
    /// 1. The rule joins `sessionCorrections`, so every FUTURE fragment — the engine
    ///    resends the whole text on each result — re-applies it. Without this, the
    ///    next engine result would visibly revert the edit the user just made.
    /// 2. The visible text updates NOW, firm side only: in deferred mode there may
    ///    never be another fragment to carry the rule.
    /// 3. If the correction looks like vocabulary (see `DictationLearning`) and
    ///    learning is on, the dictionary records it — automatically, with the pill
    ///    plus undo as the visible trace, never a dialog.
    func applyEdit(original: String, corrected: String) {
        let original = original.trimmingCharacters(in: .whitespacesAndNewlines)
        let corrected = corrected.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !original.isEmpty, original != corrected else { return }
        // An emptied word is a deletion, which is editing, not vocabulary. It still
        // applies to the text below; the guard above only rejects no-ops.

        let rule = VocabularyCorrector.Rule(from: original, to: corrected)
        sessionCorrections.append(rule)

        // BOTH sides, each corrected separately so the boundary stays on a word edge.
        //
        // The tail gets it too, and that is not a contradiction with "the tail belongs
        // to the engine": the rule now lives in `sessionCorrections`, and `publish`
        // applies those rules to both sides of every future fragment. So correcting the
        // tail here is exactly what the next fragment would do anyway — while skipping
        // it meant a correction made mid-sentence did nothing visible until the speaker
        // said the next word, and nothing at all if they had just stopped talking.
        let clamped = min(max(liveVolatileCharacters, 0), liveText.count)
        let boundary = liveText.index(liveText.endIndex, offsetBy: -clamped)
        let firm = VocabularyCorrector.apply([rule], to: String(liveText[..<boundary])).text
        let tail = VocabularyCorrector.apply([rule], to: String(liveText[boundary...])).text
        liveText = firm + tail
        // The tail changed length, so the boundary moved with it.
        liveVolatileCharacters = tail.count

        guard learnsVocabulary(), DictationLearning.isLearnable(original: original, corrected: corrected),
              let entry = vocabulary?.learn(heard: original, written: corrected)
        else { return }
        recentLearning = LearnedCorrection(entry: entry, heard: original)
        // The pill is transient; VoiceOver gets the same fact through the channel it
        // can actually hear, at normal urgency — it must not cut off "Listening".
        announcer(
            String(
                format: String(localized: "dictation.learned", bundle: .localized),
                entry.written
            ),
            .normal
        )
        learningDismissTask?.cancel()
        let duration = learningFeedbackDuration
        learningDismissTask = Task { [weak self] in
            try? await Task.sleep(for: duration)
            guard !Task.isCancelled else { return }
            self?.recentLearning = nil
        }
    }

    /// Reverts the learning shown by the pill — the entry, not the edit: the text
    /// keeps the correction, the dictionary forgets it. See `PersonalDictionary`
    /// for why a veteran entry only rolls back this use.
    func undoRecentLearning() {
        guard let recent = recentLearning else { return }
        vocabulary?.undoLearning(of: recent.entry, heard: recent.heard)
        recentLearning = nil
        learningDismissTask?.cancel()
        learningDismissTask = nil
    }

    /// Cómo se publican los anuncios de VoiceOver.
    ///
    /// Inyectable porque si no, no hay forma de comprobar que se publican: la
    /// mutación que los silenciaba por completo dejaba la suite entera en verde, y
    /// son la única señal de estado para quien no ve la pantalla.
    private let announcer: @MainActor (String, AnnouncementUrgency) -> Void
    private let deliver: @MainActor (Transcript) -> Void
    private let onStateChange: @MainActor (DictationSessionState) -> Void

    private var session: (any TranscriptionSession)?
    private var tracker: HoldGestureTracker?
    private var prepareTask: Task<Void, Never>?
    /// Cancelación de la sesión anterior en curso. La siguiente la espera.
    private var releaseTask: Task<Void, Never>?
    private var listenTask: Task<Void, Never>?
    /// La espera de la finalización. Guardada para poder cancelarla: sin esto, una
    /// sesión abandonada seguía viva hasta 2,5 s con capacidad de publicar.
    private var finalizeTask: Task<Void, Never>?
    private var gesture: HoldGesture

    /// Cuánto se espera a que el texto deje de ser volátil antes de entregar lo
    /// que haya.
    ///
    /// El valor sale de medir, no de lo que parece razonable. `session.finish()`
    /// cuesta **0,79–1,16 s la primera vez** —el modelo aún está frío y hay que
    /// analizar los 0,6 s de silencio que la propia sesión inyecta— y 0,13–0,21 s
    /// después. Con el techo en 600 ms, el PRIMER dictado vencía siempre: se
    /// tiraba el texto ya finalizado del motor y se entregaba el último fragmento
    /// volátil, o nada en modo diferido, donde no hay fragmentos.
    ///
    /// Dos segundos y medio cubren el caso frío con margen. Sigue siendo un techo:
    /// más allá de eso el usuario percibiría que la app se ha colgado.
    static let finalizationTimeout: Duration = .milliseconds(2500)

    init(
        engine: any TranscriberEngine = SpeechEngine(),
        gesture: HoldGesture,
        deliver: @escaping @MainActor (Transcript) -> Void,
        onStateChange: @escaping @MainActor (DictationSessionState) -> Void = { _ in },
        permission: @escaping @MainActor () -> MicrophonePermission = { MicrophoneAuthorization.current },
        atypicalSpeech: @escaping @MainActor () -> Bool = { false },
        isReady: @escaping @MainActor () -> Bool = { true },
        vocabulary: PersonalDictionary? = nil,
        learnsVocabulary: @escaping @MainActor () -> Bool = { true },
        learningFeedbackDuration: Duration = DictationController.defaultLearningFeedbackDuration,
        announcer: @escaping @MainActor (String, AnnouncementUrgency) -> Void = { text, urgency in
            var announcement = AttributedString(text)
            announcement.accessibilitySpeechAnnouncementPriority = urgency.priority
            AccessibilityNotification.Announcement(announcement).post()
        }
    ) {
        self.vocabulary = vocabulary
        self.learnsVocabulary = learnsVocabulary
        self.learningFeedbackDuration = learningFeedbackDuration
        self.announcer = announcer
        self.engine = engine
        self.permission = permission
        self.atypicalSpeech = atypicalSpeech
        self.isReady = isReady
        self.gesture = gesture
        self.deliver = deliver
        self.onStateChange = onStateChange
    }

    /// El atajo cambió en Ajustes: el gesto tiene que seguirlo.
    func updateGesture(_ gesture: HoldGesture) {
        self.gesture = gesture
    }

    // MARK: - Entrada del gesto

    /// El atajo se acaba de pulsar y el panel está abierto.
    ///
    /// - Parameter locale: idioma con el que se va a dictar.
    /// - Parameter mode: en vivo o diferido.
    func shortcutPressed(locale: Locale, mode: DictationMode) {
        // El permiso puede haberse revocado en Ajustes del Sistema con la app
        // abierta. Sin esta comprobación el tap se instalaba y entregaba silencio:
        // «Escuchando» eterno que no transcribe, sin fallo y sin explicación.
        // Sin permiso, el gesto simplemente **no arma**, y no se dice nada.
        //
        // Antes se publicaba `.failed(.permissionDenied)` aquí, y eso convertía la
        // acción más frecuente de la app —abrir el historial con el atajo— en un aviso
        // rojo que el usuario no había provocado, en CADA apertura, empujando la lista
        // hacia abajo y con anuncio de VoiceOver incluido. §8 promete lo contrario: «el
        // atajo del historial abre el panel exactamente como hoy».
        //
        // El fallo del permiso sí se cuenta cuando alguien **pide** dictar: el botón del
        // micrófono y ⌘D pasan por `startWithoutGesture`, que lo publica.
        //
        // Lo mismo con el modelo, y esto es lo que faltaba. El interruptor se queda
        // encendido con la oferta en `.needsModel` —a propósito: es el estado del primer
        // arranque y desde ahí se instala—, así que el gesto creaba sesión, `prepare()`
        // fallaba en milisegundos con `modelNotInstalled`, y el resultado era un aviso rojo
        // **en cada apertura del historial por atajo**, con anuncio de VoiceOver de
        // prioridad alta incluido. La carrera la gana siempre el fallo: la consulta que
        // decide tarda 1-4 ms y el vigilante del gesto tiene un tic de 40 ms.
        //
        // Y solo se ve en la máquina que **no** tiene el modelo, o sea en casi todas menos
        // en la de quien lo desarrolla.
        // El permiso YA NO se comprueba aquí. Comprobarlo al empezar la cuenta bloqueaba
        // el gesto entero en silencio —ni progreso, ni aviso, nada— cuando el permiso no
        // estaba concedido: se reportó como «mantengo el atajo y no se pone a grabar». Se
        // comprueba más abajo, justo antes de abrir el micrófono (ver el bloque al
        // principio de `handle(_:)`), que es el mismo momento en que `startWithoutGesture`
        // ya lo hacía. `isReady()` sigue aquí: eso sí tiene que seguir silencioso, porque
        // gatea el modelo y una máquina sin él vería un aviso rojo en cada apertura del
        // historial por atajo — ver el comentario de `isReady` en `AppModel`.
        guard case .idle = state, isReady() else { return }
        guard let next = reduce(state, .gestureBegan) else { return }
        currentMode = mode
        apply(next)
        liveText = ""
        liveTextIsVolatile = false
        liveVolatileCharacters = 0
        isTranscriptExpanded = false
        isEditingWord = false
        lastFailure = nil
        sessionCorrections = []

        // La carga del modelo arranca YA, en paralelo con la cuenta. Es lo que permite que
        // al confirmar solo quede abrir el audio.
        //
        // Pasa en **cada apertura del panel por atajo**, aunque el usuario solo venga a
        // mirar el historial, así que conviene tener el número y no la intuición. Medido en
        // esta máquina, con el modelo de es-ES instalado: la primera preparación del proceso
        // cuesta 126 ms y su cancelación 724 ms; a partir de ahí, con el modelo residente,
        // **5 ms preparar y 12 ms cancelar**, y la huella del proceso sube 1,2 MB la primera
        // vez y ~0,1 MB por apertura después. Lo que no se puede medir desde aquí es lo que
        // el modelo ocupa en el demonio de voz del sistema, que es donde vive de verdad.
        //
        // Con esos números, adelantar la carga se paga solo: el coste recurrente es de
        // milisegundos y lo que compra es que «escuchando» empiece cuando lo dice.
        guard let session = try? engine.makeSession(
            locale: locale,
            mode: mode,
            atypicalSpeech: atypicalSpeech(),
            contextualStrings: vocabulary?.contextualStrings() ?? []
        ) else {
            handle(.failed(.modelUnavailable))
            return
        }
        self.session = session
        // Las dos protecciones que solo tenía el camino sin gesto, y este es el
        // principal: el testigo, para que el fallo de una sesión abandonada no mate a
        // la nueva; y la espera del release, porque la reserva de idioma es global.
        let pendingRelease = releaseTask
        let token = beginSession()
        prepareTask = Task { [weak self] in
            await pendingRelease?.value
            await self?.installSessionHandlers(on: session, token: token)
            do {
                try await session.prepare()
                self?.handle(.preparationFinished, token: token)
            } catch {
                self?.fail(with: error, token: token)
            }
        }

        // El tracker lee el «sigue pulsado» POR EL MISMO SITIO que el coordinador. Con
        // su lector por defecto había dos fuentes para la misma pregunta, y la
        // consecuencia práctica era que el camino con gesto —el principal— no se podía
        // probar de punta a punta: el tracker cancelaba a los 40 ms contra el teclado
        // real mientras el coordinador creía que se seguía manteniendo.
        let tracker = HoldGestureTracker(
            gesture: gesture,
            heldProvider: { [weak self] in self?.stillHeld() ?? false }
        )
        self.tracker = tracker
        tracker.begin { [weak self] update in
            switch update {
            case .progress(let value):
                self?.handle(.gestureProgressed(value))
            case .completed:
                self?.handle(.gestureCompleted)
            case .cancelled(let cause):
                self?.handle(.gestureCancelled(Self.cause(from: cause)))
            }
        }
    }

    /// Registra las dos redes de seguridad de una sesión.
    ///
    /// Van juntas y en un solo sitio porque estaban solo en el camino del gesto, y
    /// el camino accesible —el de quien no puede mantener una tecla— se quedaba sin
    /// techo de duración y sin aviso de cambio de dispositivo.
    private func installSessionHandlers(on session: any TranscriptionSession, token: Int) async {
        // Con testigo los dos: la cancelación de la sesión anterior es ASÍNCRONA
        // (`releaseTask`), así que entre abandonar una sesión y que su `cancel()` corra
        // de verdad, un cambio de dispositivo o el techo de la sesión vieja pasaban su
        // propio guard y mataban a la sesión nueva.
        await session.setDeviceChangeHandler { [weak self] in
            Task { @MainActor in self?.handleDeviceChange(token: token) }
        }
        await session.setSessionLimitHandler { [weak self] in
            // `handleSessionLimit` y NO `.stopRequested`: el techo existe para cuando
            // nadie quiso dictar, así que entregar convierte la red de seguridad en el
            // peor fallo —pegar media hora de audio ambiente en el documento de
            // alguien. Estuvo escrito así y sin cablear, y el commit que decía
            // haberlo arreglado no lo arreglaba.
            Task { @MainActor in self?.handleSessionLimit(token: token) }
        }
    }

    /// Cualquier interacción con el panel aborta la cuenta.
    ///
    /// Es lo que evita que el gesto se dispare mientras el ojo busca en la lista:
    /// quien busca algo hace algo, quien quiere dictar se queda quieto.
    func interactionOccurred(_ cause: HoldGestureCancellation) {
        // Solo cancela la **cuenta**, nunca una sesión en marcha. Es lo que protege al
        // camino de quien no mantiene ninguna tecla —el de quien tiene temblor, que mueve
        // el puntero sin querer— de caerse al primer `.mouseMoved`.
        //
        // Aquí había además un `requiresHold`, y era redundante: `startWithoutGesture`
        // entra por `.startRequested` directo a `.preparing`, así que el camino accesible
        // **nunca pasa por `.arming`**. Quitarlo no cambiaba ningún comportamiento —una
        // mutación lo demostró sobreviviendo—, que es la señal de que la garantía vive en
        // la máquina de estados y no aquí. Se afirma allí, con
        // `accessiblePathNeverArms`.
        guard case .arming = state else { return }
        tracker?.cancel(cause, notifying: nil)
        handle(.gestureCancelled(Self.cause(from: cause)))
    }

    /// Alcanzar el dictado sin el gesto: el botón del micrófono del panel, o su
    /// atajo local. Para quien no puede mantener una tecla.
    func startWithoutGesture(locale: Locale, mode: DictationMode) {
        // Tras entregar, el estado queda en `.delivered` y ahí se quedaba: exigir
        // `.idle` hacía que el botón de micrófono —el único camino para quien no
        // puede mantener una tecla— funcionase UNA vez por lanzamiento.
        switch state {
        case .idle, .delivered, .failed: break
        default: return
        }
        guard permission() == .granted else {
            handle(.gestureBegan)
            handle(.failed(.permissionDenied))
            return
        }
        liveText = ""
        liveVolatileCharacters = 0
        isTranscriptExpanded = false
        isEditingWord = false
        lastFailure = nil
        currentMode = mode
        sessionCorrections = []
        guard let session = try? engine.makeSession(
            locale: locale,
            mode: mode,
            atypicalSpeech: atypicalSpeech(),
            contextualStrings: vocabulary?.contextualStrings() ?? []
        ) else {
            handle(.failed(.modelUnavailable))
            return
        }
        self.session = session
        // Directo a preparar, sin pasar por la cuenta: ver `startRequested`.
        guard let next = reduce(state, .startRequested) else { return }
        apply(next)
        let pendingRelease = releaseTask
        let token = beginSession()
        prepareTask = Task { [weak self] in
            await pendingRelease?.value
            await self?.installSessionHandlers(on: session, token: token)
            do {
                try await session.prepare()
                // Desde `.preparing`, la preparación acabada lleva a escuchar.
                self?.handle(.preparationFinished, token: token)
            } catch {
                self?.fail(with: error, token: token)
            }
        }
    }

    /// La sesión llegó a su duración máxima: se tira lo dictado y se dice por qué.
    /// Unos auriculares que se conectan invalidan el formato negociado.
    ///
    /// §3.2: «la sesión se finaliza **con lo que haya**, se avisa, y no se intenta continuar
    /// con un formato inválido». Emitía `.failed`, que pasa por `cancelEverything()` y **tira
    /// lo transcrito**: se avisaba y no se entregaba nada. Lo que el usuario ya había dictado
    /// no tiene la culpa de que haya cambiado el micrófono.
    ///
    /// Distinto del techo de sesión, que sí descarta a propósito: allí nadie quiso dictar;
    /// aquí sí, y solo se interrumpió.
    private func handleDeviceChange(token: Int) {
        guard isCurrent(token) else { return }
        // Se recuerda la causa antes de finalizar para que el aviso pueda decirla: la
        // entrega la marcará como recortada, y sin esto el usuario vería «puede faltar
        // texto» sin saber por qué.
        lastFailure = .audioDeviceChanged
        handle(.stopRequested, token: token)
    }

    private func handleSessionLimit(token: Int) {
        guard isCurrent(token) else { return }
        lastFailure = .sessionLimitReached
        handle(.discardRequested, token: token)
        if state == .idle { apply(.failed(.sessionLimitReached)) }
    }

    /// Vuelve al reposo si la sesión ya terminó, para que el panel no muestre el
    /// episodio anterior al abrirse.
    func resetIfSettled() {
        switch state {
        case .delivered, .failed:
            liveText = ""
            liveVolatileCharacters = 0
            isTranscriptExpanded = false
            isEditingWord = false
            lastFailure = nil
            apply(.idle)
        default:
            break
        }
    }

    /// Apaga el dictado: cierra lo que haya abierto y vuelve al reposo.
    ///
    /// Hace falta explícitamente porque apagar el interruptor de Ajustes solo
    /// soltaba la referencia al coordinador, y soltarla **no cierra nada**: la tarea
    /// de escucha retiene la sesión y queda suspendida para siempre, y el techo de la
    /// sesión solo avisa por un closure `[weak self]` que ya es nil. El micrófono
    /// podía quedarse abierto indefinidamente, sin panel y sin banner.
    func shutdown() {
        guard state != .idle else { return }
        handle(.discardRequested)
        // `discardRequested` no es legal desde todos los estados; si no lo era, se
        // fuerza el cierre igual.
        if state != .idle {
            cancelEverything()
            apply(.idle)
        }
    }

    /// Parar de escuchar: se soltó el atajo, o se pulsó parar. Entrega lo dictado.
    func stop() {
        handle(.stopRequested)
    }

    /// Tirar lo dictado sin entregarlo.
    ///
    /// Hacía falta una acción distinta de parar: parar pega en la app de destino, y
    /// un gesto disparado sin querer no tenía forma de no acabar escribiendo en el
    /// documento de alguien.
    func discard() {
        handle(.discardRequested)
    }

    /// El panel se cerró.
    func panelDismissed() {
        switch state {
        case .arming:
            interactionOccurred(.panelDismissed)
        case .preparing, .listening, .finalizing:
            // Ocurre: ⎋ y pegar del historial llaman a `hide()` con la sesión viva.
            // Hay que TRANSICIONAR, no solo cancelar: cancelar a secas dejaba el
            // estado publicado en `.listening` para siempre.
            handle(.gestureCancelled(.panelDismissed))
        case .idle, .delivered, .failed:
            break
        }
    }

    // MARK: - Máquina de estados

    /// Testigo de la sesión vigente.
    ///
    /// Sin él, el `catch` de un `prepare()` de una sesión ya abandonada llamaba a
    /// `fail`, y `.failed` es legal desde cualquier estado activo: soltar y volver a
    /// pulsar el atajo con el modelo frío mostraba «No se pudo dictar» sobre una
    /// sesión que estaba perfectamente.
    private var sessionToken = 0

    /// Textos de los anuncios de la cuenta, expuestos para poder afirmar sobre ellos
    /// sin duplicar las claves en el test.
    static var arming: String { String(localized: "dictation.state.arming", bundle: .localized) }

    /// Sustituye la lectura del «sigue pulsado». Solo para tests: en producción la
    /// hace `HoldGesture.stillHeldNow()` sobre el hardware.
    func overrideHeldProviderForTesting(_ provider: @escaping @MainActor () -> Bool) {
        heldOverride = provider
    }

    private var heldOverride: (@MainActor () -> Bool)?

    private func stillHeld() -> Bool {
        heldOverride?() ?? gesture.stillHeldNow()
    }

    /// Fuerza la confirmación de la cuenta. Solo para tests.
    func simulateGestureCompleted() {
        handle(.gestureCompleted)
    }

    /// Empuja el avance de la cuenta. Solo para tests: en producción lo mueve el
    /// `HoldGestureTracker`, cuyo reloj no se puede acelerar desde fuera.
    func simulateArmingProgress(_ progress: Double) {
        handle(.gestureProgressed(progress))
    }

    /// Emite una cancelación del gesto, como haría el vigilante al detectar el soltado.
    ///
    /// Existe porque el test que da nombre al cambio de esta ronda era **vacío**: tras abrir
    /// el micrófono ya nadie consulta `stillHeld()`, así que soltar de verdad no produce
    /// ningún evento y la aserción se cumplía igual con la regla del reductor invertida. Lo
    /// que hay que comprobar es que **la cancelación, si llega, no mata la sesión**.
    func simulateGestureCancelled(_ cause: CancellationCause) {
        handle(.gestureCancelled(cause))
    }

    /// Publica un estado por el camino real de publicación. Solo para tests.
    ///
    /// Existe porque llegar a `.listening` requiere un motor de voz vivo y un permiso
    /// concedido, así que **el cableado hacia la barra de menús y hacia la política de
    /// cierre del panel no tenía ninguna red**: anular cualquiera de los dos dejaba la
    /// suite entera en verde. Esto no simula la transición —eso lo prueban los tests del
    /// reductor— sino que recorre `apply(_:)`, que es donde vive el cableado.
    func simulateStatePublish(_ state: DictationSessionState) {
        apply(state)
    }

    /// Simula la respuesta tardía de la finalización de una sesión ya abandonada.
    ///
    /// Es el camino por el que publica `beginFinalizing`, y su testigo no tenía ninguna red:
    /// borrar la guarda de `handle(_:token:)` dejaba la suite entera en verde —incluida la
    /// local con motor real—. Y lo que protege es el bloqueante de la ronda 7: abandonar una
    /// sesión en `.finalizing` y dictar otra vez dentro de 2,5 s pegaba **el texto del
    /// dictado anterior** en el documento del usuario.
    func simulateStaleFinalization(_ text: String) {
        handle(
            .finalizationFinished(Transcript(text: text, mode: currentMode)),
            token: sessionToken - 1
        )
    }

    /// Simula el techo de duración de una sesión ya abandonada. Solo para tests: la
    /// cancelación de la sesión anterior es asíncrona, así que la ventana en la que su
    /// techo puede llegar tarde existe de verdad y no se puede provocar desde fuera.
    func simulateStaleSessionLimit() {
        handleSessionLimit(token: sessionToken - 1)
    }

    /// Simula un fallo llegado de una sesión ya abandonada. Solo para tests: el
    /// escenario real —el `catch` de un `prepare()` viejo— no se puede provocar desde
    /// fuera.
    func simulateStaleFailure() {
        fail(with: DictationEngineError.modelNotInstalled, token: sessionToken - 1)
    }

    /// ¿Sigue vigente esta sesión?
    private func isCurrent(_ token: Int) -> Bool { token == sessionToken }

    private func beginSession() -> Int {
        sessionToken += 1
        return sessionToken
    }

    private func handle(_ event: DictationEvent, token: Int) {
        guard token == sessionToken else { return }
        handle(event)
    }

    private func fail(with error: Error, token: Int) {
        guard token == sessionToken else { return }
        fail(with: error)
    }

    private func handle(_ event: DictationEvent) {
        // **La cuenta completada es el compromiso.** A partir de ahí no se vuelve a
        // preguntar por la tecla: §8.4.bis promete que el gesto solo arranca y que las
        // manos quedan libres, y esa promesa empieza cuando la cuenta llega al final, no
        // cuando el modelo termina de cargar. (Había dos guardas heredadas del modelo
        // anterior que seguían exigiendo el mantenido durante `.preparing`, y entre las
        // dos se comían la sesión en la ventana de carga del modelo — 126 ms en frío,
        // medido. Se quitaron.)
        //
        // El permiso, en cambio, sí se comprueba aquí — justo antes de abrir el
        // micrófono, en las DOS transiciones que llevan a `.listening`. No al empezar la
        // cuenta: así el gesto arma y cuenta con normalidad —mantener un instante para
        // abrir el panel sigue sin disparar ningún aviso, como siempre— y el usuario solo
        // se entera del problema en el momento en que de verdad iba a grabar. Es el mismo
        // aviso que ya publica `startWithoutGesture` (el botón del micrófono) cuando se
        // pide dictar sin permiso: antes, completar el gesto sin permiso simplemente no
        // hacía nada, sin ninguna explicación.
        let wouldOpenMicrophone: Bool
        switch (state, event) {
        case (.arming(_, true), .gestureCompleted), (.preparing, .preparationFinished):
            wouldOpenMicrophone = true
        default:
            wouldOpenMicrophone = false
        }
        if wouldOpenMicrophone, permission() != .granted {
            // Se recurre al mismo camino que cualquier otro fallo: el switch de abajo ya
            // tiene `case (_, .failed): cancelEverything()`, que suelta la sesión —y con
            // ella la ranura de idioma que sostiene— para CUALQUIER estado previo. No hace
            // falta repetir esa limpieza aquí a mano.
            handle(.failed(.permissionDenied))
            return
        }
        guard let raw = reduce(state, event) else { return }
        // La causa se registra ANTES de publicar el estado: el anuncio a VoiceOver
        // sale de `apply`, y así no llegaba a tiempo de conocerla.
        //
        // Incluida la traducción de «entrega vacía» a fallo, que `apply` hace: sin
        // esto, `lastFailure` se quedaba en nil y el banner mostraba el mensaje
        // genérico en el fallo más frecuente del dictado.
        let next = translated(raw)
        if case .failed(let failure) = next {
            lastFailure = failure
        }
        let previous = state
        apply(next)

        switch (previous, next) {
        case (_, .preparing):
            break
        case (_, .listening):
            beginListening()
        case (_, .finalizing):
            beginFinalizing()
        case (_, .idle):
            cancelEverything()
        case (_, .delivered(let transcript)):
            if transcript.isEmpty {
                // `apply` ya lo tradujo a `.failed(.noSpeechDetected)`, así que aquí
                // solo queda limpiar.
                teardown()
                return
            }
            deliver(transcript)
            teardown()
        case (_, .failed):
            // El motivo ya lo guardó `apply` para que el aviso pueda contarlo.
            cancelEverything()
        default:
            break
        }
    }

    /// Traduce una entrega vacía al fallo que de verdad la explica.
    ///
    /// Es **una sola** función porque estuvo decidido en dos sitios y divergieron: el
    /// registro del motivo respondía siempre «no se oyó nada» mientras el estado sabía
    /// distinguir el permiso revocado. Es idempotente, así que da igual cuántas veces
    /// la atraviese un estado.
    ///
    /// Y la distinción importa: el permiso se puede revocar en Ajustes del Sistema **con
    /// la sesión abierta**. El tap sigue instalado y entrega silencio, así que el síntoma
    /// es idéntico a no haber hablado, y la app culpaba al usuario («No se oyó nada.
    /// Comprueba el micrófono») del único fallo que tiene remedio concreto y un botón
    /// que lo abre.
    private func translated(_ state: DictationSessionState) -> DictationSessionState {
        guard case .delivered(let transcript) = state, transcript.isEmpty else { return state }
        return .failed(permission() == .granted ? .noSpeechDetected : .permissionDenied)
    }

    private func apply(_ next: DictationSessionState) {
        // Un transcript vacío no es una entrega: es «no se oyó nada». Se traduce
        // ANTES de publicar, porque si no VoiceOver anunciaba «Listo» y solo después
        // el fallo — la confirmación de éxito primero, en el fallo más frecuente.
        let next = translated(next)
        let previous = state
        state = next
        onStateChange(next)
        announce(from: previous, to: next)
    }

    /// Mensaje por causa, compartido con el banner para que no divergan.
    static func message(for failure: DictationFailure) -> String {
        switch failure {
        case .permissionDenied: String(localized: "dictation.failed.permission", bundle: .localized)
        case .modelUnavailable: String(localized: "dictation.failed.model", bundle: .localized)
        case .audioDeviceChanged: String(localized: "dictation.failed.device", bundle: .localized)
        case .noSpeechDetected: String(localized: "dictation.failed.no_speech", bundle: .localized)
        case .languageQuotaFull: String(localized: "dictation.failed.quota", bundle: .localized)
        case .sessionLimitReached: String(localized: "dictation.failed.time_limit", bundle: .localized)
        case .engineFailed: String(localized: "dictation.state.failed", bundle: .localized)
        }
    }

    /// Anuncia los cambios a VoiceOver desde aquí y no desde el banner.
    ///
    /// El banner no está en la jerarquía cuando la cuenta empieza —`deservesDisplay`
    /// exige `progress > 0`— así que su `onChange` no corría para el arranque, y
    /// `onChange` tampoco dispara para el valor inicial. Resultado: el primer aviso
    /// llegaba cuando el micrófono **ya estaba abierto**, es decir, cuando ya no
    /// había ventana para soltar a tiempo.
    ///
    /// Y el avance no se puede exponer solo como `accessibilityValue`: eso solo se
    /// lee si el elemento tiene el foco, y el foco vive en el campo de búsqueda. Se
    /// anuncia un hito a mitad de la cuenta, que es lo que da margen real para
    /// soltar.
    /// Cuánta prisa tiene un anuncio.
    ///
    /// VoiceOver **no encola**: un anuncio nuevo interrumpe al que se está locutando.
    /// Con el umbral del gesto en 550 ms, el aviso de la cuenta y el de «Escuchando» caen
    /// a 368 ms de distancia —menos de lo que tarda en decirse una frase de cuatro
    /// palabras—, así que el segundo cortaba al primero por construcción.
    ///
    /// La prioridad lo resuelve por lo que significa cada uno, no por temporizadores:
    ///
    /// - **`.critical`** para abrir el micrófono y para los fallos. Son los dos que no se
    ///   pueden perder: uno declara que se está grabando y el otro es lo único que
    ///   explica por qué no pasó nada.
    /// - **`.background`** para el aviso de la cuenta. Sirve para dar tiempo a soltar; si
    ///   algo más importante llega encima, que pase por delante.
    /// - `.normal` para el resto.
    ///
    /// Los tres nombres estaban mal en esta lista —`.high`, `.low`, `.default`—, que son
    /// los de `AttributedString.accessibilitySpeechAnnouncementPriority`, no los de este
    /// tipo. Quien leyera el docstring buscaría en el código tres casos que no están.
    nonisolated static func urgency(of state: DictationSessionState) -> AnnouncementUrgency {
        switch state {
        case .listening, .failed: .critical
        case .arming: .background
        default: .normal
        }
    }

    private func announce(from previous: DictationSessionState, to next: DictationSessionState) {
        let text: String? = switch (previous, next) {
        // En el MISMO umbral en el que aparece la banda. Anunciarlo con progreso 0
        // significaba decir «mantén para dictar» en cada apertura del historial por
        // atajo, que es la acción más frecuente de la app: los dos canales tienen que
        // decir lo mismo.
        case (.arming(let before, _), .arming(let after, _))
            where before < DictationSessionState.armingDisplayThreshold
                && after >= DictationSessionState.armingDisplayThreshold:
            Self.arming
        // Aquí había dos anuncios más, y sobraban los dos. La cuenta dura 550 ms:
        // avisar al 33 %, otra vez al 70 % y de «preparando» justo antes de
        // «escuchando» son cuatro locuciones en medio segundo, y VoiceOver **interrumpe
        // la anterior** — así que el aviso que existe para dar tiempo a soltar se
        // cortaba a media frase, y el único que de verdad importa, el que declara que el
        // micrófono está abierto, llegaba cuarto.
        //
        // «Preparando» además no es accionable: carga el modelo y no toca el micrófono.
        // Se queda en pantalla, donde no compite con nada.
        case (_, .listening):
            String(localized: "dictation.state.listening", bundle: .localized)
        case (_, .finalizing):
            String(localized: "dictation.state.finalizing", bundle: .localized)
        case (_, .delivered(let transcript)):
            transcript.wasTruncated
                ? String(localized: "dictation.state.truncated", bundle: .localized)
                : String(localized: "dictation.state.delivered", bundle: .localized)
        case (_, .failed(let failure)):
            // La causa, no el genérico: quien usa VoiceOver recibía «No se pudo
            // dictar» mientras la pantalla decía «No se oyó nada. Comprueba el
            // micrófono» —el fallo más frecuente y el único con remedio inmediato.
            Self.message(for: failure)
        default:
            nil
        }

        guard let text, !text.isEmpty else { return }
        announcer(text, Self.urgency(of: next))
    }

    // MARK: - Escuchar

    /// Every correction that applies to engine text right now: what the user taught
    /// across sessions, then what they corrected within this one. Session rules run
    /// last so a correction made seconds ago wins over an older dictionary rule that
    /// happens to share a form.
    private var activeCorrectionRules: [VocabularyCorrector.Rule] {
        (vocabulary?.replacementRules() ?? []) + sessionCorrections
    }

    /// Corrected text for the live panel. Recomputed from scratch on every fragment:
    /// the engine resends the WHOLE accumulated text each time — measured, 13 results
    /// for one 3.2 s sentence — so rules reapply to each arrival, never to a diff.
    private func correctedForDisplay(_ text: String) -> String {
        VocabularyCorrector.apply(activeCorrectionRules, to: text).text
    }

    /// Publishes one engine result to the panel, corrected on both sides of the
    /// volatile boundary SEPARATELY: corrections change text length, so correcting
    /// the joined string and then splitting it by the engine's count would place the
    /// boundary inside the wrong word.
    private func publish(_ fragment: TranscriptFragment) {
        let raw = fragment.text
        let clamped = min(max(fragment.volatileCharacterCount, 0), raw.count)
        let boundary = raw.index(raw.endIndex, offsetBy: -clamped)
        let firm = correctedForDisplay(String(raw[..<boundary]))
        // The tail gets the corrections too — display only, recomputed on the next
        // rewrite anyway — so a known misrecognition never flashes uncorrected.
        let tail = correctedForDisplay(String(raw[boundary...]))
        liveText = firm + tail
        liveVolatileCharacters = tail.count
        liveTextIsVolatile = fragment.isVolatile
    }

    private func beginListening() {
        guard let session else { return }
        let token = sessionToken
        listenTask = Task { [weak self] in
            do {
                let fragments = try await session.start()
                for await fragment in fragments {
                    // Los fragmentos de una sesión abandonada no pueden publicar
                    // texto: el stream sigue vivo tras cancelar.
                    guard let self, self.isCurrent(token) else { break }
                    self.publish(fragment)
                }
            } catch {
                self?.fail(with: error, token: token)
            }
        }

        // **Soltar ya no para.** El gesto sirve para arrancar; a partir de ahí la sesión
        // es manos libres y se cierra con ⏎, con el botón de parar o con ⌘D.
        //
        // Era «mantener mientras hablas» y no aguanta el uso real: para dictar una
        // conversación larga hay que sostener tres teclas varios minutos, y cualquier
        // resbalón corta a mitad. Además, ese modelo obligaba a sondear el teclado a 25 Hz
        // durante toda la escucha —la mayor deuda de energía que arrastraba la función—, y
        // al desaparecer se va sola.
        //
        // Lo que sí se vigila sigue siendo el soltado **durante la preparación**: ahí el
        // usuario todavía no ha visto nada y soltar significa que ha desistido.
    }

    // MARK: - Finalizar

    private func beginFinalizing() {
        guard let session else { return }

        // Guardada Y con testigo, como el resto de la clase. Era la única tarea
        // huérfana que quedaba —nadie la cancelaba— y además publicaba sin comprobar
        // el testigo, así que abandonar una sesión en `.finalizing` (⎋, clic fuera,
        // pegar del historial) y dictar otra vez dentro de los 2,5 s siguientes hacía
        // que la respuesta de la sesión VIEJA se pegara en el documento del usuario:
        // `reduce(.finalizing, .finalizationFinished)` es legal, así que el texto
        // anterior entraba como si fuera el nuevo.
        let token = sessionToken
        finalizeTask = Task { [weak self] in
            guard let self else { return }
            let mode = self.currentMode
            // Techo: el usuario no puede quedarse esperando indefinidamente a que
            // el motor cierre la última palabra.
            switch await Self.withTimeout(Self.finalizationTimeout, { try await session.finish() }) {
            case .value(let transcript):
                // Si la sesión se cortó porque cambió el micrófono, la entrega **se
                // confiesa recortada** aunque el motor respondiera a tiempo. §3.2 promete
                // «se finaliza con lo que haya y se avisa», y el aviso no llegaba nunca:
                // `deservesDisplay` de `.delivered` es `wasTruncated` (`Session.swift:176`),
                // así que en el caso normal —el motor sí responde— la banda ni se pintaba.
                // Medido por una auditoría independiente.
                //
                // Y es verdad además de conveniente: al cambiar el dispositivo se deja de
                // capturar audio, así que puede faltar lo que se dijera después.
                let interrupted = self.lastFailure == .audioDeviceChanged
                // The engine's final text gets the same corrections the panel showed.
                // It must happen HERE and not only on fragments: `finish()` returns the
                // session's own accumulated text, not the panel's, so without this the
                // user would watch a corrected transcript and receive the raw one.
                let (corrected, applied) = VocabularyCorrector.apply(
                    self.activeCorrectionRules,
                    to: transcript.text
                )
                // Credit once per delivery, not per fragment: fragments repeat the
                // same text many times per second and would inflate the ranking that
                // decides which 100 terms bias the engine.
                for written in applied { self.vocabulary?.noteUse(ofWritten: written) }
                self.handle(
                    .finalizationFinished(
                        Transcript(
                            text: corrected,
                            mode: transcript.mode,
                            wasTruncated: interrupted || transcript.wasTruncated
                        )
                    ),
                    token: token
                )

            case .timedOut where await session.hasFinalResultIfAvailable():
                // Venció el techo, pero el motor ya había dado un resultado final:
                // el texto está completo y no hay nada que confesar.
                await session.cancel()
                self.handle(
                    .finalizationTimedOut(
                        Transcript(text: self.liveText, mode: mode, wasTruncated: false)
                    ),
                    token: token
                )

            case .timedOut:
                // Venció el techo: se entrega lo visto, marcado como incompleto, y
                // se suelta la sesión — antes se abandonaba sin cancelar, y con
                // cualquier motor que no limpie en su propio `finish()` eso fuga la
                // reserva del idioma y deja el micrófono abierto.
                await session.cancel()
                self.handle(
                    .finalizationTimedOut(
                        Transcript(text: self.liveText, mode: mode, wasTruncated: true)
                    ),
                    token: token
                )

            case .failed:
                // Un fallo del motor NO es una entrega truncada. Colapsarlos hacía
                // que un error se le presentara al usuario como éxito a medias.
                await session.cancel()
                self.handle(.failed(.engineFailed), token: token)
            }
        }
    }

    /// Resultado de esperar con techo.
    enum TimedResult<T: Sendable>: Sendable {
        case value(T)
        case timedOut
        case failed
    }

    /// Espera un resultado con techo **de verdad**.
    ///
    /// Dos intentos anteriores no acotaban nada, y merece la pena dejarlo escrito:
    /// `withTaskGroup` espera a **todos** sus hijos antes de retornar, así que
    /// `cancelAll()` no devuelve el control mientras la operación siga viva; y
    /// esperar `work.value` con un temporizador que la cancela tampoco sirve,
    /// porque `SpeechSession.finish()` —como el motor real— no coopera con la
    /// cancelación. Medido: 2,92 s tras cancelar a los 50 ms.
    ///
    /// La única forma de acotar es **no esperar al perdedor**: el primero que
    /// responde resuelve la continuación y el otro se abandona. Y se distingue
    /// vencer de fallar, que antes colapsaban en el mismo `nil` y hacían que un
    /// fallo del motor se le presentara al usuario como una entrega truncada.
    private static func withTimeout<T: Sendable>(
        _ timeout: Duration,
        _ operation: @escaping @Sendable () async throws -> T
    ) async -> TimedResult<T> {
        let gate = SingleResumeGate()

        return await withCheckedContinuation { continuation in
            let work = Task {
                do {
                    let value = try await operation()
                    if await gate.claim() { continuation.resume(returning: .value(value)) }
                } catch {
                    if await gate.claim() { continuation.resume(returning: .failed) }
                }
            }
            Task {
                try? await Task.sleep(for: timeout)
                if await gate.claim() {
                    // Se pide la cancelación por cortesía —el motor puede
                    // ignorarla— y se sigue sin esperarla.
                    work.cancel()
                    continuation.resume(returning: .timedOut)
                }
            }
        }
    }

    // MARK: - Limpieza

    private func cancelEverything() {
        // La transcripción parcial no sobrevive a la sesión que la produjo. No se pintaba
        // —`deservesDisplay` es falso en reposo— ni se persistía nunca, pero dejar el texto
        // de alguien en memoria hasta el siguiente dictado no tiene ninguna razón a favor.
        liveText = ""
        liveTextIsVolatile = false
        liveVolatileCharacters = 0
        isTranscriptExpanded = false
        isEditingWord = false
        recentLearning = nil
        learningDismissTask?.cancel()
        learningDismissTask = nil
        // Same rule for the corrections: they were derived from that text.
        sessionCorrections = []
        prepareTask?.cancel()
        prepareTask = nil
        listenTask?.cancel()
        listenTask = nil
        // La espera de la finalización también: el testigo evita que publique, pero
        // dejarla corriendo mantiene viva la sesión abandonada hasta 2,5 s.
        finalizeTask?.cancel()
        finalizeTask = nil
        tracker?.cancel(.released, notifying: nil)
        tracker = nil

        if let session {
            // Suelta el idioma reservado. Sin esto, el cupo del sistema —cinco
            // idiomas— se agota a base de sesiones abandonadas.
            //
            // Se guarda la tarea y la sesión siguiente **espera** a que termine: la
            // reserva es estado global del proceso, y preparar la siguiente mientras
            // la anterior aún la sostiene produce un TOCTOU con un mensaje falso
            // («falta el modelo de voz») en la ventana de ~20 ms que tarda el
            // release.
            releaseTask = Task { await session.cancel() }
        }
        session = nil
    }

    private func teardown() {
        prepareTask = nil
        listenTask?.cancel()
        listenTask = nil
        finalizeTask = nil
        tracker = nil
        session = nil
    }

    private func fail(with error: Error) {
        let failure: DictationFailure = switch error {
        case DictationEngineError.noInputDevice, DictationEngineError.audioEngineFailed:
            .engineFailed
        case DictationEngineError.incompatibleAudioFormat:
            .audioDeviceChanged
        case DictationEngineError.reservationQuotaExceeded:
            .languageQuotaFull
        case DictationEngineError.sessionClosedByLimit:
            .sessionLimitReached
        case DictationEngineError.localeUnsupported,
             DictationEngineError.modelNotInstalled:
            .modelUnavailable
        default:
            .engineFailed
        }
        handle(.failed(failure))
    }

    private static func cause(from cancellation: HoldGestureCancellation) -> CancellationCause {
        switch cancellation {
        case .released: .releasedEarly
        case .pointerMoved: .pointerMoved
        case .typed: .typed
        case .navigated: .navigated
        case .scrolled: .scrolled
        case .panelDismissed: .panelDismissed
        }
    }

    /// Modo de la sesión en curso. Se recuerda al arrancar en lugar de deducirlo:
    /// la versión anterior ignoraba su parámetro y devolvía siempre `.live`, así
    /// que un dictado diferido que vencía el techo se entregaba etiquetado como en
    /// vivo.
    private var currentMode: DictationMode = .live
}

/// Garantiza que una continuación se reanuda **una sola vez**.
///
/// Reanudar dos veces una `CheckedContinuation` es un fallo fatal en tiempo de
/// ejecución, y aquí compiten dos tareas por hacerlo.
actor SingleResumeGate {
    private var done = false

    func claim() -> Bool {
        if done { return false }
        done = true
        return true
    }
}
