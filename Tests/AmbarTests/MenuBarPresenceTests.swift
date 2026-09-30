import ClipboardKit
import Foundation
import Testing
import VoiceKit

@testable import Ambar

/// El icono de la barra es la única presencia permanente de la app: con el panel
/// cerrado, es lo único que declara que el micrófono está abierto y lo único que
/// declara que la captura está en pausa.
@Suite("Presencia en la barra de menús")
struct MenuBarPresenceTests {

    @Test("escuchar manda sobre la pausa")
    func listeningWinsOverPause() {
        // Este es el fallo que motiva el tipo: la versión anterior refrescaba el icono
        // pasando `listening: false` cada vez que se tocaba la pausa, así que pausar la
        // captura mientras el micrófono estaba abierto **apagaba el indicador del
        // micrófono** con el micrófono abierto.
        let presence = MenuBarPresence.resolve(
            isDictating: true,
            pause: .starting(.untilResumed)
        )
        #expect(presence.glyph == MenuBarPresence.listening.glyph)
    }

    @Test("con la captura pausada el icono lo dice")
    func pauseIsVisible() {
        let presence = MenuBarPresence.resolve(
            isDictating: false,
            pause: .starting(.fifteenMinutes)
        )
        #expect(presence.glyph == MenuBarPresence.paused.glyph)
        // Y lo dice también para VoiceOver: un símbolo sin descripción no informa a
        // quien no ve la barra.
        #expect(!presence.description.isEmpty)
        #expect(presence.description != MenuBarPresence.idle.description)
    }

    @Test("sin pausa y sin dictado, el icono normal")
    func idleIsDefault() {
        #expect(MenuBarPresence.resolve(isDictating: false, pause: nil) == .idle)
    }

    @Test("una pausa vencida no se sigue anunciando")
    func expiredPauseStopsBeingAnnounced() {
        let now = Date(timeIntervalSince1970: 10_000)
        // Empezó hace media hora y duraba quince minutos.
        let pause = HistoryPause.starting(.fifteenMinutes, at: now.addingTimeInterval(-1800))

        // Afirmar una protección caducada es peor que no mostrarla: el usuario cuenta
        // con que nada se guarda cuando en realidad ya se guarda todo.
        #expect(MenuBarPresence.resolve(isDictating: false, pause: pause, now: now) == .idle)
    }

    // MARK: - El despertar del vencimiento

    @Test("una pausa temporal programa su propio refresco")
    func temporaryPauseSchedulesRefresh() {
        let now = Date(timeIntervalSince1970: 10_000)
        let pause = HistoryPause.starting(.fifteenMinutes, at: now)
        let delay = MenuBarPresence.refreshDelay(pause: pause, now: now)

        // Nadie emite un evento cuando una fecha pasa, así que sin este despertar el
        // icono se queda diciendo «pausado» para siempre.
        #expect(delay != nil)
        // Con margen: despertar en el instante exacto deja `now < until` del lado
        // equivocado la mitad de las veces.
        #expect((delay ?? 0) > 15 * 60)
    }

    @Test("una pausa indefinida no deja un temporizador vivo")
    func indefinitePauseSchedulesNothing() {
        // No hay nada que esperar: solo termina si alguien la termina.
        #expect(MenuBarPresence.refreshDelay(pause: .starting(.untilResumed)) == nil)
    }

    @Test("sin pausa, o ya vencida, no hay nada que programar")
    func noPauseSchedulesNothing() {
        let now = Date(timeIntervalSince1970: 10_000)
        #expect(MenuBarPresence.refreshDelay(pause: nil, now: now) == nil)
        let expired = HistoryPause.starting(.fifteenMinutes, at: now.addingTimeInterval(-1800))
        #expect(MenuBarPresence.refreshDelay(pause: expired, now: now) == nil)
    }
}

/// Que el icono se recalcule **desde todos los sitios** que cambian la pausa.
///
/// El tipo puro de arriba puede estar perfecto y el icono seguir mintiendo si nadie
/// lo llama: pausar desde Ajustes o desde el panel no refrescaba nada, porque el
/// refresco colgaba solo del menú de la barra.
@Suite("El icono se recalcula desde donde se pausa")
@MainActor
struct CaptureStateNotificationTests {

    static func model() -> AppModel {
        let defaults = UserDefaults(suiteName: "ambar.tests.capture.\(UUID().uuidString)")!
        return AppModel(settings: Settings(defaults: defaults))
    }

    @Test("sincronizar los ajustes avisa de que la captura pudo cambiar")
    func syncNotifiesCaptureChange() {
        let model = Self.model()
        var notifications = 0
        model.onCaptureStateChange = { notifications += 1 }

        // Es la llamada que hacen Ajustes (el interruptor de pausa), el panel (el botón
        // de reanudar) y el menú de la barra. Los tres caminos, un solo aviso.
        model.syncSettingsToServices()

        #expect(notifications == 1)
    }

    @Test("pausar desde Ajustes deja el estado que el icono va a leer")
    func pausingFromSettingsIsObservable() {
        let model = Self.model()
        var seenPauseWhileNotified: HistoryPause??

        model.onCaptureStateChange = { [weak model] in
            seenPauseWhileNotified = model?.settings.pause
        }
        // Exactamente lo que hace el interruptor de Ajustes.
        model.settings.isPaused = true
        model.syncSettingsToServices()

        // El aviso llega DESPUÉS de que el estado esté puesto: si llegara antes, el
        // icono se recalcularía con el valor viejo y seguiría diciendo lo contrario.
        #expect(seenPauseWhileNotified??.isActive() == true)
    }
}

/// Con cuánta prisa se locuta cada anuncio.
///
/// VoiceOver **no encola**: cada anuncio interrumpe al anterior. Con el umbral del
/// gesto en 550 ms, el aviso de la cuenta y el de «Escuchando» caen a 368 ms de
/// distancia —menos de lo que tarda una frase de cuatro palabras—, así que el segundo
/// cortaba al primero por construcción. La prioridad lo arregla por significado, y no
/// con temporizadores que habría que ajustar a la velocidad de locución de cada uno.
@Suite("Prioridad de los anuncios")
struct AnnouncementUrgencyTests {

    @Test("abrir el micrófono se anuncia con prioridad alta")
    func listeningIsCritical() {
        // Es el anuncio que declara que se está grabando. No puede perderse ni llegar
        // cortado, y es justo el que llegaba último.
        #expect(DictationController.urgency(of: .listening) == .critical)
        #expect(AnnouncementUrgency.critical.priority == .high)
    }

    @Test("los fallos también, porque son lo único que explica que no pasara nada")
    func failuresAreCritical() {
        #expect(DictationController.urgency(of: .failed(.noSpeechDetected)) == .critical)
        #expect(DictationController.urgency(of: .failed(.permissionDenied)) == .critical)
    }

    @Test("el aviso de la cuenta cede el paso")
    func armingIsBackground() {
        // Sirve para dar tiempo a soltar; si algo más importante llega encima, que pase
        // por delante en lugar de cortarlo.
        #expect(DictationController.urgency(of: .arming(progress: 0.4, prepared: false)) == .background)
        #expect(AnnouncementUrgency.background.priority == .low)
    }

    @Test("el resto va con la prioridad normal")
    func othersAreNormal() {
        #expect(DictationController.urgency(of: .preparing) == .normal)
        #expect(DictationController.urgency(of: .finalizing) == .normal)
        #expect(AnnouncementUrgency.normal.priority == .default)
    }
}

/// Que **AppModel** le pase al monitor una pausa derivada del reloj.
///
/// El test que cubría esto lo reimplementaba: asignaba el cierre dentro del propio test, así
/// que comprobaba el contrato del monitor y no el cableado. Sustituir las dos asignaciones de
/// `AppModel` por `{ false }` dejaba la suite verde — y eso significa que la pausa no
/// protege nada. Séptima aparición del patrón «el test reimplementa la guarda», esta vez en
/// la superficie de privacidad.
@Suite("El modelo cablea la pausa al monitor")
@MainActor
struct PauseWiringTests {

    static func model() -> AppModel {
        AppModel(settings: Settings(defaults: UserDefaults(suiteName: "ambar.tests.wiring.\(UUID().uuidString)")!))
    }

    @Test("sincronizar con la captura pausada deja el monitor en pausa")
    func syncPropagatesPause() {
        let model = Self.model()
        let monitor = ClipboardMonitor()
        model.attachMonitorForTesting(monitor)

        model.settings.pauseCapture(.untilResumed)
        model.syncSettingsToServices()

        #expect(monitor.isPaused, "el monitor siguió capturando con la pausa puesta")
    }

    @Test("y al reanudar, el monitor vuelve a capturar")
    func syncPropagatesResume() {
        let model = Self.model()
        let monitor = ClipboardMonitor()
        model.attachMonitorForTesting(monitor)
        model.settings.pauseCapture(.untilResumed)
        model.syncSettingsToServices()

        model.settings.resumeCapture()
        model.syncSettingsToServices()

        #expect(!monitor.isPaused)
    }

    @Test("el monitor recibe un cierre que consulta el reloj, no una copia del valor")
    func monitorReceivesAClockDerivedClosure() {
        let model = Self.model()
        let monitor = ClipboardMonitor()
        model.attachMonitorForTesting(monitor)

        // Se pausa quince minutos y se sincroniza UNA vez. Si lo que viajó fue una copia
        // del booleano, el monitor se quedará pausado para siempre: nadie emite un evento
        // cuando una fecha pasa, y ese fue el fallo que perdía semanas de historial.
        model.settings.pauseCapture(.fifteenMinutes)
        model.syncSettingsToServices()
        #expect(monitor.isPaused)

        // Se vence la pausa sin volver a sincronizar: exactamente lo que ocurre en la app
        // cuando pasan los quince minutos.
        model.settings.expirePauseForTesting()

        #expect(
            !monitor.isPaused,
            "el monitor conservó una copia del valor: seguiría descartando cada copia"
        )
    }
}

/// La decisión completa del icono: qué pintar **y si hace falta repintar**.
///
/// `AppDelegate` es la última capa del proyecto sin tests, y las mutaciones que sobrevivían
/// ahí no eran cosméticas: ignorar `isDictating` apaga el indicador del micrófono con el
/// micrófono abierto, y repintar en cada tic de la cuenta son 25 `NSImage` por segundo en el
/// hilo principal —justo en la ventana donde el producto se define por la latencia—.
@Suite("Qué hacer con el icono de la barra")
struct MenuBarUpdateTests {

    @Test("si no ha cambiado nada, no se repinta")
    func noChangeNoRedraw() {
        let shown = MenuBarPresence.idle
        let update = MenuBarPresence.update(isDictating: false, pause: nil, shown: shown)
        #expect(update.presence == .idle)
        #expect(!update.needsRedraw, "repintaría sin motivo, 25 veces por segundo")
    }

    @Test("empezar a escuchar sí repinta")
    func listeningRedraws() {
        let update = MenuBarPresence.update(
            isDictating: true,
            pause: nil,
            shown: .idle
        )
        #expect(update.presence.glyph == MenuBarPresence.listening.glyph)
        #expect(update.needsRedraw)
    }

    @Test("la primera vez siempre se pinta")
    func firstPaintAlwaysRedraws() {
        // `shown` nil es «todavía no se ha pintado nada»: salir por deduplicación ahí
        // dejaría la barra sin icono.
        #expect(MenuBarPresence.update(isDictating: false, pause: nil, shown: nil).needsRedraw)
    }

    @Test("el micrófono manda sobre la pausa también aquí")
    func dictatingWinsInTheUpdate() {
        // Es la misma prioridad de `resolve`, comprobada en el valor que de verdad consume
        // el delegado: el eslabón que se rompía era este, no aquel.
        let update = MenuBarPresence.update(
            isDictating: true,
            pause: .starting(.untilResumed),
            shown: MenuBarPresence.paused
        )
        #expect(update.presence.glyph == MenuBarPresence.listening.glyph)
        #expect(update.needsRedraw)
    }
}

/// La pausa del historial avisa a VoiceOver, igual que el dictado.
///
/// Hallazgo de la auditoría de cierre (F6): el único mecanismo de anuncio activo del
/// proyecto vivía en `DictationController`, y la pausa del historial —el otro cambio de
/// estado persistente que la barra de menús refleja, junto con el dictado— se quedaba
/// muda para quien usa VoiceOver. Pausar o reanudar cambia la barra de menús y el
/// comportamiento de captura sin que nadie lo anuncie hablado.
@Suite("La pausa avisa a VoiceOver")
@MainActor
struct PauseAnnouncementTests {

    static func settings() -> Settings {
        Settings(defaults: UserDefaults(suiteName: "ambar.tests.pause-announce.\(UUID().uuidString)")!)
    }

    @Test("pausar anuncia el mismo texto que ve el panel")
    func pausingAnnounces() {
        let settings = Self.settings()
        var announced: [String] = []
        settings.announcer = { announced.append($0) }

        settings.pauseCapture(.untilResumed)

        #expect(
            announced == [String(localized: "panel.pause.indefinite", bundle: .localized)],
            "pausar no avisó, o avisó con un texto distinto del que ve el panel: \(announced)"
        )
    }

    @Test("reanudar también anuncia")
    func resumingAnnounces() {
        let settings = Self.settings()
        settings.pauseCapture(.untilResumed)
        var announced: [String] = []
        settings.announcer = { announced.append($0) }

        settings.resumeCapture()

        #expect(
            announced == [String(localized: "history.resumed.announcement", bundle: .localized)],
            "reanudar no avisó: \(announced)"
        )
    }

    @Test("el vencimiento de la pausa también se anuncia")
    func expiryAnnounces() {
        // El único de los tres cambios de estado que ocurre **sin que el usuario haga
        // nada**: la protección termina sola. Quien no ve la pantalla no tenía forma de
        // enterarse de que el historial ha vuelto a grabar.
        // Por el camino real, no por una costura: una pausa vencida guardada en las
        // preferencias es exactamente lo que se encuentra la app al relanzarse después de
        // que venciera. `pause` es `private(set)` a propósito.
        let suite = "ambar.tests.pause-expiry.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.set(Date().addingTimeInterval(-1800), forKey: "general.pauseUntil")
        let settings = Settings(defaults: defaults)
        #expect(settings.pause != nil, "caso mal montado: no cargó la pausa guardada")

        var announced: [String] = []
        settings.announcer = { announced.append($0) }

        settings.prunePauseIfExpired()

        #expect(settings.pause == nil, "no se limpió la pausa vencida")
        #expect(
            announced == [String(localized: "history.pause_expired.announcement", bundle: .localized)],
            "la pausa venció en silencio: \(announced)"
        )
    }

    @Test("una pausa viva no anuncia nada al repintar")
    func liveePauseStaysQuietOnRepaint() {
        // `prunePauseIfExpired` corre en CADA repintado del icono, así que anunciar fuera
        // de la transición convertiría el aviso en ruido continuo.
        let settings = Self.settings()
        settings.pauseCapture(.fifteenMinutes)
        var announced: [String] = []
        settings.announcer = { announced.append($0) }

        settings.prunePauseIfExpired()
        settings.prunePauseIfExpired()

        #expect(announced.isEmpty, "anunció un vencimiento que no ha ocurrido: \(announced)")
    }

    @Test("asignar isPaused también pasa por el anuncio")
    func isPausedSetterAnnouncesToo() {
        // `isPaused` sigue siendo asignable para no romper el menú de la barra ni
        // Ajustes — es un atajo sobre pauseCapture/resumeCapture, no un camino aparte,
        // y tiene que avisar igual que ellos.
        let settings = Self.settings()
        var announced: [String] = []
        settings.announcer = { announced.append($0) }

        settings.isPaused = true
        settings.isPaused = false

        #expect(announced.count == 2, "el atajo isPaused se saltó el anuncio: \(announced)")
    }
}

/// **Quién da la cara en la barra de menús.**
///
/// Es el único sitio donde esta app está presente todo el día, y hasta ahora lo hacía con
/// `doc.on.clipboard`: un símbolo correcto y de nadie — el mismo que usan media docena de
/// gestores de portapapeles.
@Suite("La marca en la barra de menús")
struct MenuBarMarkTests {

    @Test("en reposo, la barra lleva la marca")
    func reposoLlevaLaMarca() {
        #expect(MenuBarPresence.idle.glyph == .mark)
    }

    /// Los estados siguen siendo del sistema, y deben serlo: un micrófono abierto y una
    /// pausa son conceptos que macOS ya dibuja, y reinventarlos obligaría a aprender dos
    /// símbolos nuevos para leer algo que ya se sabe leer.
    @Test("los estados siguen hablando el idioma del sistema")
    func estadosDelSistema() {
        #expect(MenuBarPresence.listening.glyph == .system("mic.fill"))
        #expect(MenuBarPresence.paused.glyph == .system("pause.circle"))
    }

    /// La imagen sube como **plantilla**. Sin eso el sistema no la tiñe: sale negra sobre la
    /// barra oscura y solo se ve al pasar el ratón por encima.
    @MainActor
    @Test("la marca sube a la barra como plantilla, y con nombre")
    func laMarcaEsPlantilla() {
        let imagen = MenuBarGlyph.image()

        #expect(imagen.isTemplate)
        #expect(imagen.accessibilityDescription == "Ámbar")
        // Y no llena la barra: los símbolos del sistema ocupan unos 16 de sus 22 puntos de
        // alto, y pasarse de ahí es lo que delata a un icono de terceros.
        #expect(imagen.size.height == MenuBarGlyph.height)
        #expect(imagen.size.width < imagen.size.height)
    }
}
