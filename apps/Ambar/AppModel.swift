import AppCore
import AppKit
import BlobStore
import ClipboardKit
import CryptoKit
import Foundation
import Observation
import VoiceKit

/// Estado de la aplicación y única puerta entre la interfaz y los servicios.
///
/// Las vistas no hablan con el store ni con el portapapeles: piden acciones
/// aquí. Así la lógica de selección, filtrado y pegado se puede razonar —y
/// probar— en un solo sitio.
@Observable
@MainActor
final class AppModel {
    // MARK: - Estado observable

    private(set) var items: [ClipboardItem] = []
    private(set) var isReady = false
    private(set) var lastError: String?

    var searchText: String = "" {
        didSet { scheduleRefresh() }
    }

    var selectedIndex: Int = 0

    var selectedItem: ClipboardItem? {
        items.indices.contains(selectedIndex) ? items[selectedIndex] : nil
    }

    /// La app puede funcionar sin permiso de accesibilidad; lo que pierde es
    /// pegar sola. La interfaz lo comunica en vez de fallar en silencio.
    private(set) var canAutoPaste = false

    /// ¿Se quedó Ámbar sin su atajo global porque otro proceso lo tiene?
    ///
    /// **El fallo que esto arregla era silencioso y total.** `RegisterEventHotKey` devuelve
    /// error si la combinación ya está tomada por **otro proceso** —otra app, o una segunda
    /// copia de Ámbar—, `HotKeyCenter.register` traduce eso a `nil`, y el delegado lo
    /// descartaba: la app arrancaba entera, ponía su icono en la barra, y su atajo no hacía
    /// absolutamente nada. Sin mensaje, sin registro, sin forma de saberlo.
    ///
    /// Ocurrió de verdad, y el diagnóstico costó: una instancia de pruebas quedó viva ocho
    /// minutos con el atajo registrado y sus preferencias aisladas, así que el atajo abría
    /// un panel sin historial y sin dictado. El síntoma que produce eso —«el reconocimiento
    /// de voz ya no está disponible»— no se parece en nada a su causa.
    private(set) var isHotKeyUnavailable = false

    /// Anota si el registro del atajo salió bien. La llama el delegado, que es quien posee
    /// el registro Carbon.
    ///
    /// Es una función y no una propiedad asignable desde fuera para que exista un sitio —uno
    /// solo— donde este hecho se convierte en algo que la interfaz puede contar.
    func applyHotKeyRegistration(succeeded: Bool) {
        let wasUnavailable = isHotKeyUnavailable
        isHotKeyUnavailable = !succeeded
        // El menú de la barra es donde mira quien pulsa el atajo y no ve nada, así que hay
        // que reconstruirlo para que lleve el aviso.
        if wasUnavailable != isHotKeyUnavailable { onCaptureStateChange?() }
    }

    /// Sube cada vez que se intenta pegar sin permiso. La interfaz lo observa
    /// para llamar la atención sobre el aviso del pie: un intento fallido y
    /// silencioso es indistinguible de una app rota.
    private(set) var missingPermissionAttempts = 0

    /// Lo asigna el delegado de la app, que es quien posee el registro Carbon.
    ///
    /// El modelo no habla directamente con `HotKeyCenter`: así la vista de
    /// ajustes puede pedir «vuelve a registrar el atajo» sin conocer nada del
    /// mecanismo que lo implementa.
    var onHotKeyChange: (() -> Void)?

    /// Avisa de que el dictado ha cambiado de estado. Lo usa el delegado para
    /// reflejar en la barra de menús que el micrófono está abierto: es la única
    /// presencia permanente de la app y, con el panel cerrado, lo único que puede
    /// contestar «¿quién me está escuchando?».
    var onDictationStateChange: ((Bool) -> Void)?

    /// Abre la ventana de Ajustes. La asigna el delegado, que es quien la posee.
    var onOpenSettings: (() -> Void)?

    /// Vuelve a mostrar la presentación de primer uso, a petición del usuario.
    ///
    /// La ventana la posee el delegado, igual que la de Ajustes. Existe porque cerrar la
    /// presentación cuenta como vista —para no insistir en cada arranque—, y sin una forma
    /// de recuperarla eso significaría que quien la cierra sin leerla no puede volver.
    var onReplayOnboarding: (() -> Void)?

    /// Avisa de que la captura ha cambiado —pausada, reanudada, excluida—.
    ///
    /// Existe porque el icono de la barra de menús tiene que reflejar la pausa, y antes
    /// solo se refrescaba al pausar **desde el menú**: hacerlo desde Ajustes o desde el
    /// panel dejaba el icono afirmando que se seguía guardando.
    var onCaptureStateChange: (() -> Void)?

    func reloadHotKey() {
        onHotKeyChange?()
    }

    /// El permiso de Accesibilidad se concedió **durante esta ejecución**.
    ///
    /// Lo consume la interfaz para ofrecer el reinicio: ver la nota del vigilante que lo
    /// enciende. Se apaga al reiniciar, porque entonces el proceso ya nace con el permiso.
    private(set) var grantedWhileRunning = false

    /// Vuelve a abrir Ámbar y cierra esta copia.
    ///
    /// Reusa el relanzado del traslado a Aplicaciones: mismo problema —una copia que tiene que
    /// dar paso a otra— y misma solución, en lugar de dos mecanismos que hacen lo mismo.
    func restart() {
        AppRelocation.relaunch(at: Bundle.main.bundleURL) { NSApp.terminate(nil) }
    }

    /// El ⌘V sintético no llegó a enviarse, con el permiso concedido.
    ///
    /// Pasa cuando el sistema rechaza el evento pese a que `AXIsProcessTrusted()` dice que sí
    /// —el caso conocido es haber concedido el permiso con la app ya en marcha—. El contenido
    /// está en el portapapeles, así que lo que falta es decirlo en vez de cerrar el panel y
    /// dejar al usuario mirando una app que aparentemente no hizo nada.
    func reportPasteFailure() {
        lastError = String(localized: "paste.failed", bundle: .localized)
    }

    /// Descarta el aviso de error. Solo lo cierra quien lo ha leído.
    func dismissError() {
        lastError = nil
    }

    // MARK: - Dictado

    /// Qué se le puede ofrecer al usuario ahora mismo: no disponible y por qué,
    /// pendiente de instalar el modelo, o listo. Lo consume Ajustes.
    /// Arranca sin afirmar nada: `nil` significa «todavía no se ha comprobado».
    ///
    /// El valor inicial anterior era `.unavailable(.localeUnsupported)`, y como
    /// nadie lo refrescaba, Ajustes decía «El dictado no admite tu idioma» a todo
    /// el mundo. Un estado desconocido no puede disfrazarse de diagnóstico.
    private(set) var dictationOffer: DictationOffer?

    /// Se está pidiendo el permiso del sistema.
    ///
    /// Lo lee la interfaz de Ajustes para deshabilitar el interruptor mientras el
    /// diálogo está en pantalla. La protección del panel la aplica
    /// `PanelDismissalPolicy.permissionPromptInFlight`, que se fija junto a esto.
    private(set) var isRequestingMicrophone = false

    /// Solo existe si el usuario lo ha activado.
    ///
    /// Crearlo perezosamente no es una optimización cosmética: con el dictado
    /// apagado no se instancia nada de `VoiceKit`, no se pide micrófono y no se
    /// toca el motor de voz. Es lo que hace que «opcional» signifique algo.
    private(set) var dictation: DictationController?

    /// Activa el dictado: pide el permiso —aquí, no durante el gesto— y averigua
    /// qué se puede ofrecer.
    ///
    /// Devuelve `false` si no se pudo activar, para que el interruptor no se quede
    /// encendido prometiendo algo que no va a funcionar.
    /// Panel al que avisar mientras se pide el permiso. Se recuerda al sincronizar
    /// para que Ajustes no tenga que conocerlo.
    private weak var dictationPanel: PanelController?

    @discardableResult
    func enableDictation() async -> Bool {
        let panel = dictationPanel
        // La app es un agente sin icono en el Dock: sin activarla, el diálogo del
        // sistema aparece detrás y el usuario no sabe de dónde ha salido.
        NSApp.activate()

        isRequestingMicrophone = true
        panel?.dismissalPolicy.permissionPromptInFlight = true
        let permission = await MicrophoneAuthorization.request()
        isRequestingMicrophone = false
        panel?.dismissalPolicy.permissionPromptInFlight = false

        await refreshDictationOffer(permission: permission)
        // Si la oferta recomienda un modo y el usuario no ha elegido, se aplica.
        // La sugerencia se aplica también con `.needsModel`: en el primer arranque la
        // oferta es esa, así que solo mirando `.available` la función se estrenaba en
        // vivo — justo lo que §6.1 llama «la protección real» que evitar.
        applyOfferedMode()
        guard case .unavailable = dictationOffer else {
            settings.isDictationEnabled = true
            if let panel { syncDictation(panel: panel) }
            return true
        }
        settings.isDictationEnabled = false
        return false
    }

    /// Pide el permiso del micrófono y recalcula la oferta con la respuesta.
    ///
    /// Existe como camino propio —además del de activar la función— porque hay un estado en
    /// el que el dictado ya está **activado** y el permiso sin pedir: la app se activó en otra
    /// copia, se movió, se reinstaló, o alguien corrió `tccutil reset Microphone`. Sin esta
    /// puerta, ese estado no tenía salida: el interruptor ya estaba encendido, así que
    /// apagarlo y volverlo a encender era el único camino que pedía el permiso, y nadie
    /// adivina eso.
    ///
    /// Pedirlo es además lo único que mete a Ámbar en la lista de Ajustes del Sistema →
    /// Privacidad y seguridad → Micrófono: macOS solo enumera ahí lo que ha solicitado el
    /// permiso, y no hay forma de añadir una app a mano.
    @discardableResult
    func requestMicrophonePermission() async -> MicrophonePermission {
        // La app es un agente sin icono en el Dock: sin activarla, el diálogo del sistema
        // sale detrás y el usuario no sabe de dónde viene.
        NSApp.activate()
        isRequestingMicrophone = true
        dictationPanel?.dismissalPolicy.permissionPromptInFlight = true
        let permission = await MicrophoneAuthorization.request()
        isRequestingMicrophone = false
        dictationPanel?.dismissalPolicy.permissionPromptInFlight = false
        await refreshDictationOffer(permission: permission)
        // Con el permiso recién concedido, el coordinador puede montarse ya: si no, el
        // dictado seguiría sin funcionar hasta la siguiente apertura del panel.
        if let panel = dictationPanel { syncDictation(panel: panel) }
        return permission
    }

    /// Apaga el dictado ahora mismo, sin esperar a la siguiente apertura del panel.
    func disableDictation() {
        settings.isDictationEnabled = false
        dictation?.shutdown()
        dictation = nil
        dictationPanel?.dismissalPolicy = .default
        onDictationStateChange?(false)
        dictationOffer = nil

        // Apagar tiene que **devolver al sistema** lo que la función tenía cogido: la
        // ranura de idioma —una de las cinco de toda la máquina— y el modelo residente.
        //
        // Sin esto quedaba tomada para siempre: consultar la oferta con el dictado
        // encendido se la queda con razón («uso legítimo»), y una consulta posterior ya
        // con el dictado apagado la veía «no nuestra» y decidía no soltarla. La segunda
        // cara del mismo hallazgo, y sin síntoma local: se manifiesta en otra app.
        let catalog = catalogProvider(settings.dictationMode)
        // Se suelta **lo que se reservó**, no lo que resuelva una consulta nueva: con una
        // resolución no determinista, preguntar otra vez devuelve otra variante y la ranura
        // se queda cogida. Lo destapó un doble de test que cambia de variante en cada
        // llamada, como hace el framework de verdad.
        //
        // Y se sueltan **todas**, no la última: mientras esto guardó un solo idioma, cada
        // cambio del idioma resuelto dejaba la anterior sin dueño y sin nadie que la
        // soltara nunca.
        let held = reservedLocales
        reservedLocales = []
        Task {
            for locale in held { await catalog.release(locale: locale) }
            await catalog.endModelRetention()
        }
    }

    /// Recalcula la oferta con el estado real del sistema.
    func refreshDictationOffer(permission: MicrophonePermission? = nil) async {
        let catalog = catalogProvider(settings.dictationMode)
        // Reservar ANTES de creer el estado (§11.1): sin la reserva,
        // `availability` responde `supported` para un modelo que ya está en la
        // máquina, y Ajustes anunciaba una descarga a quien no la necesita. Medido:
        // sin reservar `supported`, tras reservar `installed`.
        //
        // Pero la reserva es un recurso del **sistema**, con cupo de cinco idiomas
        // para toda la máquina. Consultar y quedárselo convertía abrir Ajustes con el
        // dictado APAGADO en coger una de esas cinco ranuras para siempre, que es
        // justo lo que §4 promete que no pasa. Así que se suelta al salir salvo que la
        // función esté encendida —y entonces sí es uso legítimo— o que ya estuviera
        // reservado antes de entrar aquí, caso en el que no es nuestra para soltarla.
        // **Un solo idioma resuelto para todo el ciclo.** `supportedLocale(equivalentTo:)`
        // no es determinista cuando el idioma pedido no casa exacto —medido: `de_ES` da
        // `de_AT`, `de_CH` o `de_DE` en llamadas distintas del mismo proceso—, y aquí se
        // resolvía **seis veces** por separado: comprobar, reservar, consultar, pedir el
        // peso y soltar. Reservar una variante y soltar otra deja cogida una de las cinco
        // ranuras de toda la máquina hasta que Ámbar termine, que en una app de barra de
        // menús son semanas.
        //
        // El arreglo se hizo en `SpeechSession` y no llegó aquí, que es el sitio por el que
        // pasa **abrir Ajustes** — o sea, el camino que recorre todo el mundo.
        // **Barrido de arranque.** Las reservas no se van al cerrar la app: son un apunte
        // persistente del sistema, y lo que un día se reservó sin soltar sigue ahí semanas
        // después. Medido: un proceso reserva, termina, y el siguiente lo encuentra puesto.
        //
        // Así que antes de nada se devuelve todo: lo que haga falta se vuelve a reservar
        // tres líneas más abajo. Una sola vez y aquí, que es el primer refresco y el único
        // momento en que se puede afirmar que no hay ninguna sesión de dictado viva a la
        // que quitarle el idioma a mitad.
        // **Except when another Ámbar is alive.** The reservation is per app, not per
        // process, so a second instance sweeping at launch took the language away from the
        // one already running: measured on 2026-10-01, the running app answered "Falta el
        // modelo de voz" with the model installed after other instances had started. It
        // happens whenever two copies overlap: a relaunch, an update, a build under test.
        if !hasReclaimedStrayReservations {
            hasReclaimedStrayReservations = true
            if !anotherInstanceIsRunning() {
                await catalog.releaseReservations(keeping: nil)
            }
            reservedLocales = []
        }

        let locale = await catalog.supportedLocale(equivalentTo: Locale.current) ?? Locale.current

        // Soltar lo que retenemos de OTROS idiomas antes de reservar este.
        //
        // Aquí estaba la fuga que dejaba el dictado inservible. La reserva se conserva a
        // propósito cuando la función está encendida —es uso legítimo—, pero solo se
        // recordaba UNA: al cambiar el idioma resuelto, la línea de abajo pisaba el
        // recuerdo y la reserva anterior se quedaba sin dueño. Nadie volvía a soltarla,
        // porque el único camino que suelta —apagar el dictado— suelta lo recordado, que
        // ya apuntaba a otro sitio. Y el idioma resuelto cambia por dos vías: cambiar el
        // del sistema, y la propia resolución, que sin coincidencia exacta devuelve
        // variantes distintas en llamadas sucesivas (medido: `de_ES` da `de_AT`, `de_CH`
        // o `de_DE`). Cinco cambios y el sexto dictado moría con «no caben más idiomas»,
        // señalando a Ajustes del Sistema, donde no había nada que soltar: las cinco
        // ranuras las retenía Ámbar, y solo se liberaban al cerrarla.
        //
        // Se sueltan **las nuestras**, no todo lo que el inventario liste: ahí dentro
        // puede haber la reserva de una sesión de dictado en curso, y quitársela a mitad
        // convertiría el arreglo de una fuga en un fallo peor. Lo guarda el test «una
        // reserva que ya estaba no se suelta», que es el que tumbó el primer intento.
        let stale = reservedLocales.filter { $0.identifier != locale.identifier }
        reservedLocales.removeAll { $0.identifier != locale.identifier }
        for previous in stale { await catalog.release(locale: previous) }

        let heldBefore = await catalog.holdsReservation(forLocale: locale)
        _ = try? await catalog.reserve(locale: locale)
        // Se **recuerda** cuál se reservó. Resolver otra vez al soltar suelta una variante
        // distinta y deja la ranura cogida: es la misma fuga, un paso más tarde.
        if !heldBefore, !reservedLocales.contains(where: { $0.identifier == locale.identifier }) {
            reservedLocales.append(locale)
        }
        // Se suelta al final, no en un `defer` con `Task`: dentro de un `defer` la
        // liberación quedaba en una tarea suelta que nadie espera, así que un test no
        // podía comprobarla y —peor— dos consultas seguidas podían soltar la reserva
        // de una sesión que acababa de empezar.
        let availability = await catalog.availability(forLocale: locale)
        if availability == .supported,
           let bytes = await catalog.installationSize(forLocale: locale) {
            dictationModelSize = ByteCountFormatter.string(
                fromByteCount: bytes,
                countStyle: .file
            )
        } else {
            dictationModelSize = nil
        }
        dictationOffer = DictationReadiness(
            availability: availability,
            permission: permission ?? permissionProvider(),
            hasInputDevice: inputDeviceProvider(),
            // La medida real de ESTA máquina, si el usuario la ha pedido alguna vez.
            // Estuvo fijo en `.unmeasured`, y eso dejaba todo el eje de capacidad como
            // código muerto: `OfferTone.warning` no podía ocurrir, así que la
            // recomendación de no usar el modo en vivo en una máquina justa —la decisión
            // del primer día— no llegaba a ninguna parte.
            capability: settings.capability
        ).offer

        if !heldBefore, !settings.isDictationEnabled {
            await catalog.release(locale: locale)
            reservedLocales.removeAll { $0.identifier == locale.identifier }
        }
    }

    /// Avisos para poder afirmar el cableado del panel desde un test.
    ///
    /// El coordinador del dictado necesita permiso de micrófono y motor real, así que
    /// observar «¿avisó al cerrar?» y «¿armó el gesto?» exigía un doble a la altura del
    /// modelo. Son dos cierres opcionales, nil en producción.
    var onPanelDismissedForTesting: (() -> Void)?

    /// Comprueba la oferta si el dictado quedó activado.
    ///
    /// Es una función y no dos líneas dentro de `start()` para que el test la llame **a
    /// ella** y no la reimplemente: escribir el helper de test copiando la condición es
    /// exactamente el fallo de método que este proyecto lleva diez rondas cazando, y lo
    /// acabo de hacer otra vez al arreglar esto.
    func refreshOfferIfDictationEnabled() {
        guard settings.isDictationEnabled else { return }
        Task { await refreshDictationOffer() }
    }

    /// Aplica el modo que la oferta recomienda, si el usuario no ha elegido.
    ///
    /// Vive aparte de `enableDictation` para poder afirmarlo: activar el dictado pasa por
    /// el diálogo del sistema, así que un test no puede recorrer ese camino, y con la
    /// decisión en línea sustituirla por `break` no rompía nada. Lo que se pierde con eso
    /// es lo que §6.1 llama la protección real: **sin ninguna medida, la función se
    /// estrenaba en vivo**, que es el modo que puede no ir en una máquina justa.
    func applyOfferedMode() {
        switch dictationOffer {
        case .available(_, let suggested):
            settings.applySuggestedDictationMode(suggested)
        case .needsModel, .installingModel, .needsMicrophonePermission:
            // En el primer arranque la oferta es esta, así que mirar solo `.available`
            // dejaba el estreno en vivo. El permiso pendiente cuenta igual: se va a poder
            // usar en cuanto se resuelva, y el modo con el que se estrena ya está decidido.
            settings.applySuggestedDictationMode(Capability.unmeasured.suggestedMode)
        case .unavailable, nil:
            break
        }
    }

    /// Sondeo del permiso de **micrófono**, mientras Ajustes esté abierto.
    ///
    /// §4.1 dice que el permiso denegado se presenta «con un acceso directo a Ajustes del
    /// Sistema, **igual que ya se hace con Accessibility**», y esa comparación no se
    /// sostenía: la accesibilidad se autocuraba en 1,5 s y el micrófono no se volvía a
    /// mirar nunca. Tras concederlo, Ajustes seguía diciendo «Ámbar no tiene permiso» y el
    /// interruptor seguía apagado.
    ///
    /// Solo corre con la ventana de Ajustes abierta y solo mientras falte el permiso: es
    /// el único momento en que alguien está mirando lo que refresca. Un sondeo que
    /// sobrevive a su ventana es el patrón que esta misma ronda tuvo que arreglar en el
    /// vigilante de accesibilidad.
    private var microphoneWatcher: Timer?

    /// De dónde sale el estado del permiso, sustituible en tests.
    ///
    /// Sin esta costura las tres decisiones de `startMicrophonePermissionWatcher` eran
    /// inalcanzables desde `swift test`: el estado real de TCC no se puede inyectar, así
    /// que una auditoría independiente pudo borrar el guard, la holgura y la parada al
    /// cerrar Ajustes, las tres, con los 471 tests en verde.
    var microphonePermission: @MainActor () -> MicrophonePermission = { MicrophoneAuthorization.current }

    /// ¿Está el sondeo del permiso en marcha? Para poder afirmar que se enciende cuando
    /// toca y —sobre todo— que se apaga.
    var isWatchingMicrophonePermissionForTesting: Bool { microphoneWatcher != nil }

    /// Holgura del sondeo. Es una propiedad que no cambia nada observable salvo el
    /// consumo, o sea justo lo que desaparece en una refactorización sin que nadie lo eche
    /// de menos hasta que a alguien se le acaba la batería.
    var microphoneWatcherToleranceForTesting: TimeInterval? { microphoneWatcher?.tolerance }

    /// Cuántos temporizadores de este sondeo siguen **vivos en el run loop**, no cuántos
    /// tiene guardados el modelo.
    ///
    /// La diferencia es justo el fallo que se persigue: `stopMicrophonePermissionWatcher()`
    /// pone la propiedad a `nil` incondicionalmente, así que preguntar por la propiedad
    /// después de pararlo da la respuesta correcta **haga lo que haga** `start()`. Un test
    /// que solo mirase eso pasaría con un `start()` que sobrescribe la propiedad y deja el
    /// anterior despertando al procesador para siempre, sin nadie que pueda invalidarlo.
    /// Medido: esa mutación sobrevivía.
    var liveMicrophoneWatchersForTesting: Int {
        allMicrophoneWatchers.filter { $0.timer?.isValid == true }.count
    }

    /// Todos los que ha creado esta instancia, con referencia débil para no mantenerlos
    /// vivos artificialmente. Solo se usa desde los tests.
    private var allMicrophoneWatchers: [WeakTimer] = []

    func startMicrophonePermissionWatcher() {
        stopMicrophonePermissionWatcher()
        // Si ya está concedido no hay nada que vigilar. Sin este guard, abrir Ajustes con
        // el permiso puesto deja 40 despertares por minuto sondeando para siempre una
        // respuesta que ya se tiene.
        guard microphonePermission() != .granted else { return }
        // El `Timer` no se captura en el cierre —Swift 6 lo rechaza como envío entre
        // dominios—: se apaga por la propiedad, que solo se toca desde el actor principal.
        // Sin `tolerance`, el sistema tiene que despertar el procesador en el instante
        // exacto y no puede agrupar este despertar con ningún otro. Es la palanca de
        // energía más barata que existe para un temporizador repetido, y no había ninguna
        // en toda la app. Un 10 % del intervalo es holgura invisible aquí: nadie nota que
        // el estado del micrófono se refresque 150 ms más tarde.
        let watcher = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                guard self.microphonePermission() == .granted else { return }
                self.stopMicrophonePermissionWatcher()
                // Concederlo fuera de la app no emite ningún evento: esto es lo que hace
                // que la interfaz deje de afirmar algo que ya no es cierto.
                await self.refreshDictationOffer()
            }
        }
        watcher.tolerance = 0.15
        microphoneWatcher = watcher
        allMicrophoneWatchers.append(WeakTimer(watcher))
        // Al modo `.common`, como el resto de los temporizadores de la app: con un menú
        // abierto, el modo por omisión no dispara.
        RunLoop.main.add(watcher, forMode: .common)
    }

    func stopMicrophonePermissionWatcher() {
        microphoneWatcher?.invalidate()
        microphoneWatcher = nil
    }

    /// ¿Se está midiendo la capacidad ahora mismo?
    private(set) var isMeasuringCapability = false

    /// Mide esta máquina y guarda el resultado.
    ///
    /// La medición la pide el usuario: cuesta unos segundos, necesita el modelo instalado
    /// y su resultado solo vale para esta máquina y este sistema. Un fallo aquí no es un
    /// fallo del dictado —se queda sin medir, que es un estado legítimo—.
    func measureCapability() async {
        guard !isMeasuringCapability else { return }
        isMeasuringCapability = true
        defer { isMeasuringCapability = false }

        do {
            // Se mide **el modo en vivo**, no el que el usuario tenga puesto: es el modo
            // que la medida decide si se puede ofrecer, y el que más cuesta. Medir el
            // diferido —el valor por defecto, justamente por §6.1— daría un factor
            // optimista para la decisión que se está tomando.
            let measurement = try await CapabilityProbe().measure(
                locale: Locale.current,
                mode: .live
            )
            settings.capabilityMeasurement = measurement
            capabilityError = nil
        } catch {
            capabilityError = String(localized: "dictation.measure.failed", bundle: .localized)
        }
        await refreshDictationOffer()
        // Si la máquina no da para el modo en vivo, la recomendación se aplica sola —a
        // menos que el usuario ya haya elegido.
        applyOfferedMode()
    }

    /// Por qué no se pudo medir, si no se pudo.
    private(set) var capabilityError: String?

    /// Los idiomas que esta app tiene reservados ahora mismo, ya resueltos.
    ///
    /// Se guardan porque la resolución **no es determinista** sin coincidencia exacta, así que
    /// «vuelve a resolver y suelta eso» deja cogida una de las cinco ranuras de la máquina.
    ///
    /// Y son una lista, no un solo valor: mientras fue un solo valor, cambiar el idioma
    /// resuelto pisaba el recuerdo y dejaba la reserva anterior sin nadie que la soltara.
    /// Cinco cambios agotaban las cinco ranuras, y el dictado dejaba de arrancar hasta
    /// cerrar la app — que es lo único que las devolvía.
    private var reservedLocales: [Locale] = []

    /// ¿Se ha hecho ya el barrido de ranuras sobrantes de ejecuciones anteriores?
    ///
    /// Una vez por arranque. Repetirlo más tarde arriesgaría soltar el idioma de una
    /// sesión de dictado en curso, que es peor que la fuga que repara.
    private var hasReclaimedStrayReservations = false

    /// ¿Puede el dictado funcionar ahora mismo?
    ///
    /// `nil` —todavía no comprobado— cuenta como **no**: el gesto es el camino que nadie
    /// pidió, así que ante la duda no arma. Los caminos explícitos sí lo intentan y cuentan
    /// el fallo, que es donde el usuario está esperando una respuesta.
    var dictationCanRun: Bool {
        if case .available = dictationOffer { return true }
        return false
    }

    /// De dónde se lee el permiso de micrófono. Inyectable para los tests: sin esto,
    /// `refreshDictationOffer` sin argumento explícito consulta el TCC real del proceso
    /// de test, y su resultado depende del historial de permisos de la MÁQUINA donde
    /// corre la suite, no del código. Medido: un test que dependía de esto empezó a
    /// fallar sin que nadie tocara una línea suya.
    var permissionProvider: @MainActor () -> MicrophonePermission = { MicrophoneAuthorization.current }

    /// Si hay entrada de audio en el sistema. Inyectable por el mismo motivo que el de
    /// arriba, un paso más allá: aquello dependía del historial de permisos de la máquina,
    /// y esto depende de su **hardware**. `hasInputDevice` abre una
    /// `AVCaptureDevice.DiscoverySession`, y en una máquina sin entrada de audio —la VM del
    /// runner de CI— esa enumeración tarda lo suyo: el test de arranque agotó sus 3 s de
    /// plazo esperando una oferta que no llegaba, y falló por el hardware ausente, no por
    /// el código.
    ///
    /// El arreglo de `permissionProvider` está a cuatro líneas y le faltó al hermano, que
    /// es el patrón que este proyecto lleva rondas cazando.
    var inputDeviceProvider: @MainActor () -> Bool = { MicrophoneAuthorization.hasInputDevice }

    /// Whether another process of this same app is running. Injectable so the launch
    /// sweep can be tested both ways; see `refreshDictationOffer`.
    var anotherInstanceIsRunning: @MainActor () -> Bool = {
        // Only an installed app has siblings worth sparing; a test runner has none.
        guard Bundle.main.bundleURL.pathExtension == "app",
              let identifier = Bundle.main.bundleIdentifier else { return false }
        let mine = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: identifier)
            .contains { $0.processIdentifier != mine }
    }

    /// De dónde sale el motor de transcripción del controlador.
    ///
    /// Inyectable para los tests: el motor real **reserva una ranura de idioma del sistema**
    /// y arranca la carga del modelo en cuanto el gesto arma. Eso es estado global de la
    /// máquina, compartido con las demás suites —que corren en procesos distintos, donde un
    /// cerrojo dentro del proceso no llega—, y el síntoma es un fallo intermitente en otro
    /// test que no tiene nada que ver.
    var engineProvider: @MainActor () -> any TranscriberEngine = { SpeechEngine() }

    /// Declara la oferta como utilizable sin tocar el catálogo del sistema. Solo para tests:
    /// la disponibilidad real depende de qué modelos tenga instalados la máquina, y un test
    /// que dependa de eso mide la máquina, no el código.
    func markDictationAvailableForTesting() {
        dictationOffer = .available(tone: .inviting, suggestedMode: .live)
    }

    /// Peso de la instalación pendiente, ya formateado. `nil` si no se sabe.
    private(set) var dictationModelSize: String?

    /// Instala el modelo del idioma actual, informando del avance.
    /// Cablea el anuncio a VoiceOver de la instalación del modelo. Inyectable, mismo
    /// patrón que `Settings.announcer`: descarga de un modelo de voz es la otra mitad
    /// del hallazgo de la auditoría de cierre (F6) sobre anuncios que faltaban — quien
    /// pulsa «Instalar» y usa VoiceOver no se enteraba de que empezó ni de que acabó,
    /// solo de que una barra de progreso apareció y desapareció en algún momento.
    var installAnnouncer: @MainActor (String) -> Void = { text in
        var announcement = AttributedString(text)
        announcement.accessibilitySpeechAnnouncementPriority = .high
        AccessibilityNotification.Announcement(announcement).post()
    }

    func installDictationModel(onProgress: @escaping @Sendable (Double) -> Void) async {
        installAnnouncer(String(localized: "dictation.model.installing", bundle: .localized))
        // `catalogProvider`, no `SpeechModelCatalog` directo — mismo motivo que en
        // `refreshDictationOffer`/`disableDictation`: sin el punto de inyección, probar
        // que esto avisa a VoiceOver exigía una instalación real contra el modelo de voz
        // del sistema.
        let catalog = catalogProvider(settings.dictationMode)
        // El idioma, RESUELTO antes de pedir la instalación.
        //
        // `supportedLocale(equivalentTo:)` **no es determinista**: medido con 40 llamadas
        // por identificador en un mismo proceso, `de` devuelve unas veces `de_AT` y otras
        // `de_DE`, y `fr` reparte entre `fr_BE`, `fr_CH` y `fr_FR`. Los regionales
        // (`fr_FR`) sí son estables. Pasar `Locale.current` sin resolver dejaba que el
        // catálogo resolviera por su cuenta ahí dentro, así que se podía descargar una
        // variante y comprobar después otra: el usuario pulsaba «Instalar», la descarga
        // terminaba, y seguía leyendo «Falta el modelo de voz».
        //
        // Es la misma fuga que `refreshDictationOffer` ya arreglaba resolviendo una vez y
        // recordando el resultado. Su comentario dice «el arreglo se hizo en
        // `SpeechSession` y no llegó aquí»; tampoco había llegado a este método, que es el
        // que recorre quien pulsa el botón.
        let locale = await catalog.supportedLocale(equivalentTo: Locale.current) ?? Locale.current
        do {
            try await catalog.installModel(forLocale: locale, onProgress: onProgress)
            dictationInstallError = nil
            installAnnouncer(String(localized: "dictation.model.installed.announcement", bundle: .localized))
        } catch {
            // Sin red, el `try?` anterior dejaba desaparecer la barra de progreso y
            // no decía nada: el usuario pulsaba «Instalar» y no pasaba nada nunca.
            dictationInstallError = String(localized: "dictation.model.failed", bundle: .localized)
            // El error ya se pinta como texto (`dictationInstallError`), pero un texto
            // que aparece sin mover el foco no se lee solo: se anuncia igual que el
            // éxito, no solo la mitad feliz.
            installAnnouncer(String(localized: "dictation.model.failed", bundle: .localized))
        }
        await refreshDictationOffer()
        // Tras instalar, aplicar la sugerencia de modo: en el primer arranque la
        // oferta es `.needsModel`, así que al activar no se aplicaba y la función se
        // estrenaba en vivo — justo lo que §6.1 dice evitar.
        if case .available(_, let suggested) = dictationOffer {
            settings.applySuggestedDictationMode(suggested)
        }
    }

    /// Último error de instalación, para poder decirlo.
    private(set) var dictationInstallError: String?

    /// Prepara el dictado si está activado, y lo desmonta si se ha desactivado.
    func syncDictation(panel: PanelController) {
        dictationPanel = panel
        guard settings.isDictationEnabled else {
            // Apagar tiene que CERRAR, no solo soltar la referencia.
            dictation?.shutdown()
            dictation = nil
            panel.dismissalPolicy = .default
            return
        }
        if let dictation {
            // El atajo puede haber cambiado en Ajustes.
            dictation.updateGesture(HoldGesture(combination: settings.hotKey))
            return
        }
        dictation = DictationController(
            engine: engineProvider(),
            gesture: HoldGesture(combination: settings.hotKey),
            deliver: { [weak self, weak panel] transcript in
                guard let self, let panel else { return }
                self.deliverDictation(
                    transcript,
                    targetBundleID: panel.previousApplication?.bundleIdentifier,
                    paste: { panel.pasteDictated($0) }
                )
            },
            onStateChange: { [weak self, weak panel] state in
                self?.onDictationStateChange?(state.isMicrophoneOpen)
                // Con una sesión viva el panel no puede cerrarse al perder el
                // foco: dejaría el micrófono abierto sin nada en pantalla.
                // Se muta solo el campo: reasignar la política completa borraba
                // `permissionPromptInFlight`, y con él la protección que evita que el
                // panel se cierre mientras el diálogo de TCC está en pantalla.
                panel?.dismissalPolicy.dictationSessionActive = state.inhibitsPanelDismissal
            },
            atypicalSpeech: { [weak settings] in settings?.isAtypicalSpeechEnabled ?? false },
            // El gesto solo arma si el dictado puede funcionar de verdad. Ver `isReady`.
            isReady: { [weak self] in self?.dictationCanRun ?? false },
            vocabulary: personalDictionary,
            learnsVocabulary: { [weak settings] in settings?.isDictionaryLearningEnabled ?? true }
        )
    }

    /// Entrega lo dictado: al historial y, si hay dónde, a la app de destino.
    ///
    /// Recibe el destino y el pegado por parámetro, y no un `PanelController`, para que
    /// un test pueda **cerrar el circuito hasta la ingesta real**. Es el arreglo de un
    /// fallo de método que se repitió cuatro veces: el test anterior comprobaba el
    /// predicado (`shouldArchive`) y reimplementaba la guarda en el propio test, así que
    /// sustituir la de aquí por `if true` dejaba la suite entera en verde — es decir,
    /// dictar dentro de un gestor de contraseñas podía volver al historial sin que nada
    /// fallara.
    func deliverDictation(
        _ transcript: Transcript,
        targetBundleID: String?,
        paste: (DictationDelivery) -> Void
    ) {
        guard let plan = DictationDelivery.plan(
            transcript: transcript,
            settings: settings,
            targetBundleID: targetBundleID
        ) else { return }

        if plan.archives {
            recordDictation(plan.text)
            refresh()
        }
        paste(plan)
    }

    /// Huella estable entre arranques.
    static func stableFingerprint(of text: String) -> String {
        SHA256.hash(data: Data(text.utf8))
            .compactMap { String(format: "%02x", $0) }
            .joined()
    }

    /// Avisa de que lo pegado puede estar incompleto.
    ///
    /// Va por el aviso general del modelo y no por la banda del panel: la banda muere
    /// con el panel, y el panel tiene que cerrarse antes de pegar.
    func reportTruncatedDictation() {
        lastError = String(localized: "dictation.state.truncated", bundle: .localized)
    }

    /// Marca el contenido actual del portapapeles como escrito por nosotros.
    /// Escribe lo dictado en el portapapeles **y** avisa al monitor, en un solo paso.
    ///
    /// Van juntos, y conviene ser exacto sobre por qué: la entrada duplicada la impide en
    /// última instancia la marca `AutoGeneratedType` que pone `Paster`, no este acuse
    /// —medido: sin acuse el vigilante lee el portapapeles y lo descarta como
    /// `markedPrivate`—. Lo que aporta el acuse es que **ni siquiera lo lea**: sin él, cada
    /// dictado provoca una lectura completa del portapapeles, con su inspección de tipos y
    /// su huella, para acabar tirándola. Dos defensas, una detrás de otra, y el comentario
    /// anterior le atribuía a esta el mérito de la otra.
    func writeDictatedToPasteboard(
        _ plan: DictationDelivery,
        to pasteboard: NSPasteboard = .general
    ) {
        Paster.writePlainText(plan.text, concealed: plan.concealed, to: pasteboard)
        monitor?.acknowledgeCurrentState()
    }

    /// ¿Se archiva este dictado en el historial?
    ///
    /// Tres reglas, y las tres importan: la pausa manda; la lista de apps excluidas
    /// vale igual que para una copia —dictar dentro de un gestor de contraseñas no
    /// puede acabar en el historial solo porque el texto entrara por voz—; y un
    /// destino desconocido se trata como excluido, eligiendo el lado que no deja
    /// rastro.
    static func shouldArchive(settings: Settings, targetBundleID: String?) -> Bool {
        guard !settings.isPaused else { return false }
        guard let targetBundleID else { return false }
        return !settings.excludedBundleIDs.contains(targetBundleID)
    }

    /// Cuántas entradas tiene el historial. Para poder afirmar sobre la ingesta real.
    func historyCount() -> Int {
        (try? store?.count()) ?? 0
    }

    /// Construye la entrada de historial de una transcripción.
    ///
    /// Extraída para que un test pueda cerrar el circuito hasta la ingesta: el test
    /// anterior probaba solo la condición y no su efecto.
    static func dictationItem(text: String) -> CapturedItem {
        CapturedItem(
            kind: .text,
            representations: [
                Representation(
                    uti: UTIs.plainText,
                    blobHash: nil,
                    inline: Data(text.utf8),
                    bytes: text.utf8.count
                )
            ],
            preview: text,
            searchableText: text,
            sourceBundle: Bundle.main.bundleIdentifier,
            sourceName: String(localized: "dictation.source_name", bundle: .localized),
            concealed: false,
            imageData: nil,
            // La huella incluye el texto para que dictar lo mismo dos veces
            // seguidas no cree dos entradas, igual que copiar lo mismo dos veces.
            // SHA y no `hashValue`: el hash de String está sembrado por proceso,
            // así que la deduplicación dejaba de funcionar tras reiniciar.
            fingerprint: "dictation:" + Self.stableFingerprint(of: text)
        )
    }

    /// Guarda una transcripción como entrada del historial.
    func recordDictation(_ text: String) {
        guard let ingestor else { return }
        _ = try? ingestor.ingest(Self.dictationItem(text: text))
    }

    func flagMissingPastePermission() {
        missingPermissionAttempts += 1
        // Puede que lo haya concedido con el panel abierto.
        refreshPermissionState()
    }

    // MARK: - Servicios

    let settings: Settings
    private(set) var store: Store?
    private var ingestor: Ingestor?
    private var monitor: ClipboardMonitor?
    private var ocrQueue: OCRQueue?
    private var refreshTask: Task<Void, Never>?
    private var permissionWatcher: Timer?
    private var retentionTimer: Timer?
    private var wakeObserver: NSObjectProtocol?

    /// Miniaturas ya decodificadas, cacheadas por hash: el contenido es
    /// inmutable por definición, así que un hash siempre da la misma imagen.
    ///
    /// `NSCache` y no un diccionario. Un diccionario crece sin techo mientras
    /// se recorre el historial —cada miniatura de 256 px ronda los 256 KB
    /// descomprimida, así que ver 500 imágenes retiene unos 128 MB hasta que la
    /// app se cierra— y además no reacciona a la presión de memoria del
    /// sistema. `NSCache` desaloja solo cuando hace falta.
    private let thumbnailCache: NSCache<NSString, NSImage> = {
        let cache = NSCache<NSString, NSImage>()
        cache.countLimit = 300
        // ~48 MB. El coste se declara en bytes estimados de cada imagen.
        cache.totalCostLimit = 48 * 1024 * 1024
        return cache
    }()

    /// De dónde sale el catálogo de modelos de voz.
    ///
    /// Inyectable para poder comprobar **qué se reserva y qué se suelta**: la reserva
    /// es una de las cinco ranuras de idioma de todo el sistema, y una fuga solo se ve
    /// mirando el inventario, que en un proceso de test no se puede tocar.
    var catalogProvider: @MainActor (DictationMode) -> any ModelCatalog = { mode in
        SpeechModelCatalog(mode: mode)
    }

    /// The user's dictation vocabulary. Lives beside the store, not inside it: it must
    /// survive a full history wipe, because it is something the user taught the app.
    let personalDictionary: PersonalDictionary

    init(settings: Settings = Settings()) {
        self.settings = settings
        self.personalDictionary = PersonalDictionary(
            directory: Self.applicationSupportDirectory()
        )
    }

    // MARK: - Ciclo de vida

    /// Engancha un monitor sin arrancar el sondeo. Solo para tests: es lo que permite
    /// comprobar que el modelo le pasa una pausa **derivada del reloj** y no una copia del
    /// valor, que es la diferencia entre reanudar al vencer y no reanudar nunca.
    func attachMonitorForTesting(_ monitor: ClipboardMonitor) {
        self.monitor = monitor
        syncSettingsToServices()
    }

    /// Monta el historial en un directorio dado. Solo para tests: es lo que permite
    /// ejercitar la entrega de un dictado **hasta la ingesta real** sin tocar el
    /// historial del usuario ni arrancar el monitor del portapapeles.
    func startForTesting(directory: URL) throws {
        let store = try Store(directory: directory)
        self.store = store
        self.ingestor = Ingestor(store: store)
        isReady = true
    }

    func start() {
        // Si el dictado quedó activado de la sesión anterior, hay que **volver a mirar** al
        // arrancar. `dictationOffer` nace `nil` —«todavía no comprobado»— y `dictationCanRun`
        // trata `nil` como no, con razón: el gesto es el camino que nadie pidió y ante la
        // duda no arma. Pero nadie poblaba la oferta fuera de Ajustes, así que quien activó
        // el dictado ayer mantenía el atajo hoy y **no ocurría nada, en silencio**, hasta
        // abrir Ajustes en ese proceso.
        //
        // El arreglo del bloqueante de la ronda 9 se pasó de frenada por no distinguir «no
        // se puede» de «no se ha mirado». La diferencia se arregla mirando.
        refreshOfferIfDictationEnabled()

        do {
            let directory = Self.applicationSupportDirectory()
            let store = try Store(directory: directory)
            self.store = store
            self.ingestor = Ingestor(store: store)
            self.ocrQueue = OCRQueue(store: store)

            let monitor = ClipboardMonitor()
            monitor.excludedBundleIDs = Set(settings.excludedBundleIDs)
            // Derivado del reloj en cada consulta: ver `ClipboardMonitor.isPausedNow`.
            monitor.isPausedNow = { [weak settings] in settings?.isPaused ?? false }
            monitor.onOutcome = { [weak self] outcome in
                self?.handle(outcome)
            }
            monitor.start { [weak self] captured in
                self?.handle(captured)
            }
            self.monitor = monitor

            isReady = true
            refresh()

            canAutoPaste = Paster.canPaste

            if settings.isOCREnabled {
                Task { [ocrQueue] in await ocrQueue?.resumePendingWork() }
            }

            // La purga no se hace en cada captura —es un barrido y no debe
            // competir con el camino caliente— pero tampoco puede hacerse solo
            // al arrancar: esta app vive en la barra de menús y su ciclo normal
            // se mide en semanas. Con un único disparo al inicio, la política
            // de «30 días / 2 GB» que anuncia la interfaz no se cumpliría nunca
            // mientras el equipo siga encendido.
            Task { await self.applyRetention() }
            scheduleRetention()
        } catch {
            lastError = String(
                localized: "error.store_open",
                defaultValue: "No se pudo abrir el historial: \(error.localizedDescription)",
                bundle: .localized
            )
        }
    }

    static func applicationSupportDirectory() -> URL {
        // Redirigible SOLO en debug: en producción, poder mover el historial
        // con una variable de entorno es superficie de ataque sin contrapartida.
        #if DEBUG
        if let override = ReviewHooks.dataDirectoryOverride {
            return URL(fileURLWithPath: override)
        }
        #endif
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appending(path: "Ambar", directoryHint: .isDirectory)
    }

    #if DEBUG
    /// Inserta entradas de ejemplo de cada tipo. Solo existe en debug: es
    /// contenido de mentira y no tiene por qué viajar en el binario que usa
    /// la gente.
    func seedDemoContent() {
        guard let ingestor else { return }
        let now = Date()

        func text(_ value: String, kind: ItemKind, app: String, secondsAgo: TimeInterval) {
            let captured = CapturedItem(
                kind: kind,
                representations: [
                    Representation(
                        uti: UTIs.plainText,
                        blobHash: nil,
                        inline: Data(value.utf8),
                        bytes: value.utf8.count
                    )
                ],
                preview: value,
                searchableText: value,
                sourceBundle: "com.demo.\(app.lowercased())",
                sourceName: app,
                concealed: false,
                imageData: nil,
                fingerprint: UUID().uuidString
            )
            _ = try? ingestor.ingest(captured, now: now.addingTimeInterval(-secondsAgo))
        }

        // Una imagen real con texto dentro, para poder comprobar de un vistazo
        // la miniatura, el reconocimiento y la búsqueda por contenido.
        if let png = Self.makeDemoImage() {
            let captured = CapturedItem(
                kind: .image,
                representations: [
                    Representation(uti: UTIs.png, blobHash: nil, inline: nil, bytes: png.count)
                ],
                preview: "",
                searchableText: nil,
                sourceBundle: "com.apple.screencapture",
                sourceName: "Capturas",
                concealed: false,
                imageData: png,
                fingerprint: UUID().uuidString
            )
            if let id = try? ingestor.ingest(captured, now: now.addingTimeInterval(-60)) {
                Task { [ocrQueue] in
                    await ocrQueue?.enqueue(itemID: id)
                    await MainActor.run { self.refresh() }
                }
            }
        }

        text("https://www.apple.com/es/macos/", kind: .url, app: "Safari", secondsAgo: 30)
        text("#FF9F0A", kind: .color, app: "Figma", secondsAgo: 180)
        text("informe-trimestral.pdf, notas.md", kind: .file, app: "Finder", secondsAgo: 900)
        text(
            "func aplicarRetencion(_ politica: RetentionPolicy) throws -> RetentionResult",
            kind: .text,
            app: "Xcode",
            secondsAgo: 3_600
        )
        text(
            "Nos vemos mañana a las 10:30 en la oficina para revisar el diseño de la campaña",
            kind: .text,
            app: "Mensajes",
            secondsAgo: 7_200
        )

        refresh()
    }

    private static func makeDemoImage() -> Data? {
        let size = NSSize(width: 900, height: 420)
        let image = NSImage(size: size)
        image.lockFocus()

        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()

        NSAttributedString(
            string: "FACTURA 2026\nImporte: 1.240,00 €",
            attributes: [
                .font: NSFont.systemFont(ofSize: 64, weight: .semibold),
                .foregroundColor: NSColor.black,
            ]
        ).draw(at: NSPoint(x: 48, y: 120))

        image.unlockFocus()

        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff)
        else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }
    #endif

    // MARK: - Captura

    /// Avisa cuando se descarta algo por tamaño.
    ///
    /// Los demás motivos son silenciosos a propósito: que no se guarde una
    /// contraseña o el eco de otro gestor es el comportamiento correcto y no
    /// merece interrumpir. Pero copiar un fichero enorme y que no aparezca
    /// nada, sin explicación, se lee como que la app está rota.
    private func handle(_ outcome: CaptureOutcome) {
        guard case .ignored(.tooLarge(let bytes, let limit)) = outcome else { return }

        // `defaultValue` exige un literal interpolado, no una concatenación:
        // necesita conocer la posición de cada argumento para casarla con la
        // traducción.
        let size = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        let cap = ByteCountFormatter.string(fromByteCount: Int64(limit), countStyle: .file)

        lastError = String(
            localized: "error.too_large",
            defaultValue: "Contenido demasiado grande para el historial: \(size) supera el límite de \(cap). Sigue en el portapapeles: pégalo con ⌘V.",
            bundle: .localized
        )
    }

    private func handle(_ captured: CapturedItem) {
        guard let ingestor else { return }
        do {
            let itemID = try ingestor.ingest(captured)
            if captured.kind == .image, settings.isOCREnabled {
                Task { [ocrQueue] in
                    await ocrQueue?.enqueue(itemID: itemID)
                    await MainActor.run { self.refresh() }
                }
            }
            refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Consulta

    /// Agrupa las pulsaciones: escribir "factura" son siete cambios de texto y
    /// una sola consulta útil.
    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(40))
            guard !Task.isCancelled else { return }
            self?.resetPagination()
            self?.refresh()
        }
    }

    /// Cuántas entradas se piden de una vez.
    ///
    /// La lista virtualiza, así que el coste no está en dibujar sino en
    /// materializar filas desde SQLite. Un lote de este tamaño llena de sobra
    /// cualquier pantalla y se carga en milisegundos.
    private static let pageSize = 150

    private var loadedLimit = pageSize
    /// `true` si la consulta devolvió justo el límite pedido: puede haber más.
    private(set) var mayHaveMore = false

    func refresh() {
        guard let store else { return }
        let query = SearchQuery.parse(searchText)
        do {
            items = try store.items(matching: query, limit: loadedLimit)
            mayHaveMore = items.count == loadedLimit
            if selectedIndex >= items.count { selectedIndex = max(0, items.count - 1) }
        } catch {
            lastError = error.localizedDescription
        }
    }

    /// Amplía el lote al acercarse al final de la lista.
    ///
    /// Antes había un tope fijo de 200 sin aviso: con un historial mayor, todo
    /// lo anterior quedaba fuera de alcance salvo buscándolo, y nada en la
    /// interfaz lo daba a entender.
    func loadMoreIfNeeded(currentIndex: Int) {
        guard mayHaveMore, currentIndex >= items.count - 20 else { return }
        loadedLimit += Self.pageSize
        refresh()
    }

    /// Vuelve al primer lote. Se llama al cambiar la búsqueda: mantener un
    /// límite crecido de la consulta anterior pediría cientos de filas para
    /// mostrar tres resultados.
    private func resetPagination() {
        loadedLimit = Self.pageSize
    }

    // MARK: - Navegación

    func moveSelection(by delta: Int) {
        guard !items.isEmpty else { return }
        selectedIndex = min(max(0, selectedIndex + delta), items.count - 1)
    }

    func selectFirst() { selectedIndex = 0 }
    func selectLast() { selectedIndex = max(0, items.count - 1) }

    // MARK: - Acciones

    /// Deja la entrada en el portapapeles, lista para pegar.
    ///
    /// Se separa del pegado a propósito: escribir al portapapeles es inmediato
    /// y no depende de quién tenga el foco, mientras que enviar el ⌘V exige que
    /// la app de destino ya esté activa. Haciéndolo en dos pasos, el contenido
    /// está puesto antes de empezar a devolver el foco y no hay ventana en la
    /// que el atajo llegue a un portapapeles todavía vacío.
    ///
    /// - Parameter plainText: fuerza texto sin formato (⌘↵).
    /// - Returns: `true` si había algo que copiar.
    @discardableResult
    func stage(item: ClipboardItem, plainText: Bool) -> Bool {
        guard writeToPasteboard(item: item, plainText: plainText) else { return false }
        promote(item: item)
        return true
    }

    /// Puts the entry on the pasteboard, and nothing else: the part of `stage` a paste
    /// has to wait for.
    func writeToPasteboard(
        item: ClipboardItem,
        plainText: Bool,
        to pasteboard: NSPasteboard = .general
    ) -> Bool {
        guard let store else { return false }

        do {
            let representations = try store.representations(for: item.id)
            let payloads = try buildPayloads(from: representations, plainText: plainText)
            guard !payloads.isEmpty else { return false }

            Paster.write(payloads, to: pasteboard)
            // El monitor debe saber que este cambio lo hicimos nosotros, o
            // volvería a capturar la misma entrada y la duplicaría arriba.
            monitor?.acknowledgeCurrentState()
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    /// Moves a used entry to the top of the history.
    ///
    /// Usarla la sube al primer puesto (`markUsed`), así que la lista se reordena
    /// bajo el cursor. La selección sigue a la entrada y no al hueco que ocupaba:
    /// sin esto, quedarse en el panel —el caso sin permiso de accesibilidad, donde
    /// solo se copia— dejaba el resaltado sobre la que hubiera bajado a su sitio.
    func promote(item: ClipboardItem) {
        guard let store else { return }
        do {
            try store.markUsed(itemID: item.id)
            refresh()
            if let promoted = items.firstIndex(where: { $0.id == item.id }) {
                selectedIndex = promoted
            }
        } catch {
            lastError = error.localizedDescription
        }
    }

    private func buildPayloads(
        from representations: [Representation],
        plainText: Bool
    ) throws -> [Paster.Payload] {
        guard let store else { return [] }

        func data(for representation: Representation) throws -> Data? {
            if let inline = representation.inline { return inline }
            if let hash = representation.blobHash { return try store.blobs.data(for: hash) }
            return nil
        }

        if plainText {
            // Se busca explícitamente la variante de texto plano en vez de
            // convertir la enriquecida: convertir RTF a texto aquí daría un
            // resultado distinto del que el usuario copió.
            guard let plain = representations.first(where: { $0.uti == UTIs.plainText }),
                  let payload = try data(for: plain)
            else { return [] }
            return [Paster.Payload(uti: UTIs.plainText, data: payload)]
        }

        return try representations.compactMap { representation in
            guard let payload = try data(for: representation) else { return nil }
            return Paster.Payload(uti: representation.uti, data: payload)
        }
    }

    func togglePin(item: ClipboardItem) {
        guard let store else { return }
        do {
            try store.setPinned(itemID: item.id, pinned: !item.pinned)
            refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func delete(item: ClipboardItem) {
        guard let store else { return }
        do {
            try store.delete(itemID: item.id)
            refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }

    func deleteAllUnpinned() {
        guard let store else { return }
        do {
            try store.deleteAllUnpinned()
            refresh()
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: - Recursos

    /// Miniatura de una entrada de imagen, si ya está generada.
    func thumbnail(for item: ClipboardItem) -> NSImage? {
        guard let hash = item.imageMeta?.thumbnailHash, let store else { return nil }

        let key = hash as NSString
        if let cached = thumbnailCache.object(forKey: key) { return cached }

        guard let data = try? store.blobs.data(for: hash),
              let image = NSImage(data: data)
        else { return nil }

        // El coste es el tamaño descomprimido aproximado (4 bytes por píxel),
        // no el del PNG: es lo que ocupa de verdad en memoria y lo que debe
        // gobernar el desalojo.
        let cost = Int(image.size.width * image.size.height * 4)
        thumbnailCache.setObject(image, forKey: key, cost: cost)
        return image
    }

    /// Imagen a tamaño completo para el panel de vista previa.
    func fullImage(for item: ClipboardItem) -> NSImage? {
        guard item.kind == .image, let store else { return nil }
        guard let representations = try? store.representations(for: item.id),
              let hash = representations.compactMap(\.blobHash).first,
              let data = try? store.blobs.data(for: hash)
        else { return nil }
        return NSImage(data: data)
    }

    /// Texto para el panel de vista previa, recortado a lo que se puede dibujar.
    ///
    /// El recorte es solo de presentación: al pegar se usa el contenido íntegro.
    /// Un `Text` de SwiftUI con varios millones de caracteres no se degrada
    /// poco a poco, se queda colgado, y el panel entero deja de responder.
    func fullText(for item: ClipboardItem) -> String? {
        guard let store, let representations = try? store.representations(for: item.id) else { return nil }
        guard let plain = representations.first(where: { $0.uti == UTIs.plainText }) else {
            return item.preview.isEmpty ? nil : item.preview
        }

        let full: String?
        if let inline = plain.inline {
            full = String(data: inline, encoding: .utf8)
        } else if let hash = plain.blobHash, let data = try? store.blobs.data(for: hash) {
            full = String(data: data, encoding: .utf8)
        } else {
            full = item.preview
        }

        guard let text = full else { return nil }
        let limit = CaptureLimits.standard.maximumPreviewCharacters
        guard text.count > limit else { return text }

        return String(text.prefix(limit)) + "\n\n" + String(
            localized: "preview.truncated",
            defaultValue: "… (mostrando los primeros \(limit) caracteres; al pegar se copia el texto completo)",
            bundle: .localized
        )
    }

    // MARK: - Mantenimiento

    /// Programa la purga periódica y la vinculada al despertar.
    ///
    /// Dos disparos porque cubren casos distintos: el temporizador diario
    /// atiende a un equipo que se queda encendido, y la notificación de
    /// despertar atiende al portátil que pasa la noche suspendido —donde el
    /// temporizador no corre y al abrir la tapa pueden haber pasado días.
    private func scheduleRetention() {
        retentionTimer?.invalidate()

        let timer = Timer(timeInterval: 24 * 60 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.applyRetention() }
            }
        }
        // Una hora de holgura sobre veinticuatro. Lo que hace este temporizador es borrar
        // lo caducado: que ocurra a las 3:00 o a las 4:00 da exactamente igual, y a cambio
        // el sistema puede agruparlo con cualquier otro despertar del día.
        timer.tolerance = 60 * 60
        RunLoop.main.add(timer, forMode: .common)
        retentionTimer = timer

        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.applyRetention() }
            }
        }
    }

    func applyRetention() async {
        guard let store else { return }
        let policy = settings.retentionPolicy
        // Fuera del hilo principal: recorre el árbol de blobs y puede tardar.
        let result = await Task.detached(priority: .utility) {
            try? store.applyRetention(policy: policy)
        }.value
        if let result, result.deletedItems > 0 { refresh() }
    }

    func syncSettingsToServices() {
        monitor?.excludedBundleIDs = Set(settings.excludedBundleIDs)
        monitor?.isPausedNow = { [weak settings] in settings?.isPaused ?? false }
        onCaptureStateChange?()
    }

    func refreshPermissionState() {
        #if DEBUG
        if let forced = Self.reviewPasteCapability {
            canAutoPaste = forced
            // Sin sondeo: el override existe para que un volcado dé el mismo resultado en
            // cualquier máquina, y un temporizador que lo sobrescribiera al segundo y medio
            // haría que el gate midiera una cosa distinta según lo que tardara en llegar.
            return
        }
        #endif
        canAutoPaste = Paster.canPaste
        updatePermissionWatcher()
    }

    #if DEBUG
    /// Fija lo que el modelo cree del permiso de Accesibilidad, para los volcados de
    /// revisión.
    ///
    /// **Por qué hace falta.** La vista del paso del permiso pinta el estado **en vivo**
    /// —tiene que hacerlo: concederlo ocurre fuera de la app y macOS no avisa—, así que lo
    /// que sale en pantalla depende de si esa máquina ya lo tiene concedido. Sin este
    /// override, el gate de accesibilidad encontraría el botón «Conceder el permiso» en el
    /// runner de CI y no en el Mac del autor, que es la definición de un gate que no se
    /// puede creer. Mismo patrón que `AccessibilityPreferences.overrideForReview`.
    static var reviewPasteCapability: Bool?
    #endif

    /// Mientras falte el permiso, se comprueba cada poco.
    ///
    /// Concederlo ocurre fuera de la app —en Ajustes del Sistema— y macOS no
    /// avisa de ello. Sin este sondeo, el usuario activa el interruptor, vuelve
    /// a Ámbar y la interfaz sigue diciendo que falta, que es exactamente el
    /// momento en que uno concluye que la app está rota. El temporizador se
    /// apaga solo en cuanto el permiso aparece.
    /// Apaga el sondeo del permiso. Lo llama el panel al cerrarse.
    ///
    /// Sin esto, para quien no concede Accesibilidad —un caso soportado y documentado: la
    /// app «copia pero no pega»— el temporizador de 1,5 s seguía despertando el proceso
    /// **40 veces por minuto durante toda la sesión**, con el panel cerrado y sin nadie
    /// mirando lo que refresca. Un sondeo creado para una ventana concreta no puede
    /// sobrevivir a la ventana.
    func stopPermissionWatcher() {
        permissionWatcher?.invalidate()
        permissionWatcher = nil
    }

    private func updatePermissionWatcher() {
        if canAutoPaste {
            permissionWatcher?.invalidate()
            permissionWatcher = nil
            return
        }

        guard permissionWatcher == nil else { return }

        let timer = Timer(timeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if Paster.canPaste {
                    self.canAutoPaste = true
                    // Concedido **con la app ya en marcha**. macOS empieza a decir que sí,
                    // pero el envío de eventos sintéticos puede seguir sin llegar a su
                    // destino hasta que el proceso se reinicie: el sistema no reevalúa lo
                    // que ya arrancó. Medido en esta máquina el mismo día: una instancia
                    // lanzada **después** de conceder pegó a la primera, y la que llevaba
                    // corriendo desde antes no pegaba nada — sin ningún error por el camino,
                    // porque el post del evento sí «funciona».
                    //
                    // No se afirma que haga falta siempre: se ofrece, que es lo único
                    // honesto cuando el sistema no lo dice.
                    self.grantedWhileRunning = true
                    self.permissionWatcher?.invalidate()
                    self.permissionWatcher = nil
                }
            }
        }
        // Mismo criterio que el vigilante del micrófono: 150 ms de holgura sobre 1,5 s.
        // Este además solo vive hasta que el permiso llega, así que su coste es acotado.
        timer.tolerance = 0.15
        RunLoop.main.add(timer, forMode: .common)
        permissionWatcher = timer
    }

    /// ¿Queda alguna imagen por reconocer?
    var hasPendingRecognition: Bool {
        guard let store else { return false }
        return !((try? store.pendingOCRItems(limit: 1)) ?? []).isEmpty
    }
}

/// Referencia débil a un `Timer`, para poder contar cuántos siguen vivos sin mantenerlos
/// vivos por el hecho de contarlos.
struct WeakTimer {
    weak var timer: Timer?
    init(_ timer: Timer) { self.timer = timer }
}
