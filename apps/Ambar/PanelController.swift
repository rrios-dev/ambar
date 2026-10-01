import AppCore
import AppKit
import Carbon.HIToolbox
import ClipboardKit
import GlassUI
import SwiftUI
import VoiceKit

/// Ventana flotante del historial.
///
/// Es una `NSPanel` no activadora: aparece encima de la app en uso sin
/// robarle la activación, igual que Spotlight. Esto no es un detalle estético
/// — es lo que permite pegar de vuelta en la app correcta, porque nunca dejó
/// de ser la app en primer plano a ojos del sistema.
@MainActor
final class PanelController {
    private var panel: AmbarPanel?

    /// La ventana del panel, para el arnés que vuelca el árbol de accesibilidad real.
    /// Ver `AccessibilityDump`: es lo único que puede ver lo que VoiceOver ve, porque en un
    /// proceso de test ese árbol está vacío.
    var panelWindowForReview: NSWindow? { panel }
    private var keyMonitor: Any?
    private var pointerMonitor: Any?
    private var moveObserver: NSObjectProtocol?
    private let model: AppModel

    /// App que estaba delante cuando se abrió el panel. Es a quien hay que
    /// devolver el foco para pegar.
    private(set) var previousApplication: NSRunningApplication?

    /// Who is in front when the panel opens.
    ///
    /// Injectable for the same reason as `canPaste` and `pasteboard` below: in a test
    /// the real answer is whichever app happens to be frontmost on the machine at that
    /// second, so a test written against it passes or fails by accident and proves
    /// nothing either way.
    var frontmostApplication: @MainActor () -> NSRunningApplication? = {
        NSWorkspace.shared.frontmostApplication
    }

    /// Si el panel puede cerrarse al perder el foco. Lo actualiza quien gobierna
    /// el dictado; por defecto es el comportamiento de siempre.
    var dismissalPolicy: PanelDismissalPolicy = .default

    /// ¿Está el panel delante del usuario?
    ///
    /// **No se pregunta a `NSWindow.isVisible`**, y esto es una cicatriz: desde que ocultar
    /// dejó de sacar la ventana del orden —para no pagar 758 ms de material de cristal en
    /// cada apertura—, `isVisible` responde `true` con la ventana invisible, porque no mira
    /// el alfa. Y como `toggle()` decide con esto, la segunda pulsación del atajo ocultaba y
    /// **todas las siguientes volvían a ocultar**: el gestor de portapapeles dejaba de
    /// existir para el usuario tras el primer cierre.
    ///
    /// El estado lo lleva el controlador, que es quien sabe lo que ha hecho.
    private(set) var isVisible = false

    /// La vista de contenido, para poder ocultarla sin sacar la ventana del orden.
    ///
    /// Expuesta para los tests: `contentView.subviews.first` **no** es esta vista sino la que
    /// interpone el material de cristal, así que un test que mire ahí afirma sobre otra cosa
    /// —lo comprobé escribiéndolo mal primero—.
    private(set) weak var hostingView: NSView?

    /// Ventana viva, si el panel ya se ha mostrado alguna vez.
    var window: NSWindow? { panel }

    init(model: AppModel) {
        self.model = model
    }

    // MARK: - Presentación

    /// Cómo se ha pedido abrir el panel. Importa: el gesto de mantener solo tiene
    /// sentido si hay una tecla mantenida, y armarlo al abrir desde el menú creaba
    /// y abortaba una sesión del motor —con su reserva de idioma— en cada apertura.
    enum Invocation {
        case hotKey
        case menu
    }

    func toggle(_ invocation: Invocation = .hotKey) {
        // El atajo **con el panel ya abierto no lo cierra**: vuelve a armar la cuenta del
        // gesto sin tocar la ventana.
        //
        // Cerrarlo y reabrirlo producía un parpadeo —y con el material de cristal, uno caro—
        // justo en el gesto que la gente repite cuando el dictado no arrancó a la primera.
        // Del menú sí se espera que la opción cierre lo que abrió.
        // **Con una sesión viva, el atajo global la para.**
        //
        // Es la única salida por teclado que funciona cuando el foco está fuera del panel:
        // ⏎ y ⌘D los sirve un monitor **local**, que solo ve los eventos entregados a esta
        // app. Si el usuario clica en otra app, el panel sigue delante —la política impide
        // cerrarlo con el micrófono abierto— pero deja de recibir teclas, y quedaba solo el
        // clic en el botón. Con el techo en treinta minutos, esa ventana es quince veces más
        // larga que antes.
        if invocation == .hotKey,
           Self.hotKeyAction(
               isVisible: isVisible,
               isMicrophoneOpen: model.dictation?.state.isMicrophoneOpen ?? false
           ) == .stopDictation {
            model.dictation?.stop()
            return
        }

        // Repetir el atajo solo evita cerrar **si hay un gesto que rearmar**. Con el dictado
        // apagado —el valor por defecto— la segunda pulsación tiene que seguir cerrando: si
        // no, el atajo principal de la app deja de hacer nada observable para la mayoría de
        // la gente, y ninguna app de esta categoría se comporta así.
        if isVisible, invocation == .hotKey, canRearmGesture {
            rearmGesture()
            return
        }
        isVisible ? hide() : show(invocation)
    }

    /// Qué significa el atajo global según lo que esté pasando.
    ///
    /// Se decide aquí, y no dentro de `toggle`, porque es la única tecla que llega cuando el
    /// foco está fuera del panel y por tanto la única salida garantizada de una sesión viva.
    nonisolated static func hotKeyAction(
        isVisible: Bool,
        isMicrophoneOpen: Bool
    ) -> HotKeyAction {
        if isMicrophoneOpen { return .stopDictation }
        return isVisible ? .toggleOrRearm : .showPanel
    }

    enum HotKeyAction: Equatable { case stopDictation, toggleOrRearm, showPanel }

    /// ¿Hay algo que rearmar al repetir el atajo con el panel delante?
    ///
    /// Solo cuando el dictado puede arrancar. Es lo que separa «no parpadea porque va a
    /// grabar» de «el atajo no hace nada», y la diferencia la nota justo quien no usa el
    /// dictado: la mayoría.
    var canRearmGesture: Bool {
        guard let dictation = model.dictation,
              Self.armsGesture(
                  invocation: .hotKey,
                  holdGestureEnabled: model.settings.isHoldGestureEnabled,
                  stickyKeysEnabled: StickyKeys.isEnabled
              )
        else { return false }
        // Con una sesión viva tampoco: el atajo no la reinicia, se para con ⏎ o con el botón.
        return !dictation.state.isActive
    }

    /// ¿⌘⌫ descarta el dictado en vez de borrar del historial?
    private var dictationDiscards: Bool {
        guard let dictation = model.dictation else { return false }
        return DictationEntryPoints.deleteAction(for: dictation.state) == .discardDictation
    }

    /// Vuelve a empezar la cuenta del gesto sobre un panel que ya está delante.
    private func rearmGesture() {
        guard let dictation = model.dictation else { return }
        dictation.resetIfSettled()
        dictation.shortcutPressed(
            locale: Locale.current,
            mode: model.settings.dictationMode
        )
    }

    /// Lo que el panel enseña ahora mismo, para poder afirmarlo sin AppKit.
    ///
    /// La capa donde vivió este fallo —y todas las regresiones de diez rondas— no tenía un
    /// solo test. Esto es lo mínimo para que el ciclo abrir/cerrar/abrir sea comprobable.
    enum Presentation: Equatable {
        case hidden
        case shown
    }

    var presentation: Presentation { isVisible ? .shown : .hidden }

    /// ¿Esta apertura arma la cuenta del gesto?
    ///
    /// Decisión aparte del sitio de uso, y no un gancho de test que observe una copia de la
    /// condición: escribir el doble replicando el `if` es el fallo de método que este
    /// proyecto lleva diez rondas cazando, y lo acabo de intentar otra vez.
    ///
    /// Solo el atajo arma. Abrir desde el menú creaba y abortaba una sesión del motor —con
    /// su reserva de idioma— en cada apertura, y nadie mantiene ninguna tecla al elegir una
    /// opción de menú.
    ///
    /// `stickyKeysEnabled` se comprueba EN VIVO aquí, no solo en el valor por defecto que
    /// `Settings.init` calcula una vez al arrancar el proceso. Ámbar vive semanas abierta
    /// como agente de barra de menús, y activar Teclas Especiales con la app ya corriendo
    /// —el atajo del sistema es pulsar ⇧ cinco veces, fácil de disparar sin querer— dejaba
    /// el interruptor guardado tal cual estuviera hasta el siguiente reinicio. Con los
    /// modificadores enclavados por el sistema, `HoldGesture.stillHeld` no puede distinguir
    /// «lo sigo pulsando» de «lo enclavé y solté», así que **cualquier** apertura del panel
    /// superaría el umbral y abriría el micrófono sin que nadie mantuviera nada — a quien
    /// menos va a relacionar «se me abre el micrófono» con un ajuste de accesibilidad.
    nonisolated static func armsGesture(
        invocation: Invocation,
        holdGestureEnabled: Bool,
        stickyKeysEnabled: Bool
    ) -> Bool {
        invocation == .hotKey && holdGestureEnabled && !stickyKeysEnabled
    }

    /// Teclas que el panel consume para navegar por la lista.
    nonisolated private static let navigationKeyCodes: Set<UInt16> = [
        125,  // ↓
        126,  // ↑
        121,  // avanzar página
        116,  // retroceder página
    ]

    /// ¿Qué cancelación emite esta tecla sobre la cuenta del gesto?
    ///
    /// §8.3 lista «pulsar una flecha» entre lo que aborta la cuenta, y no lo hacía: la
    /// cancelación solo se emitía para las teclas **no** consumidas por el panel, y las
    /// flechas sí las consume. Quien recorría la lista con el teclado sin soltar el atajo
    /// abría el micrófono a los 550 ms.
    ///
    /// Y por eso `HoldGestureCancellation.navigated` no tenía productor en ninguno de los
    /// tres enums donde está declarado: un caso muerto es la firma de una promesa sin
    /// cumplir.
    ///
    /// - Returns: `nil` cuando la tecla no cancela nada — los atajos de la propia función de
    ///   dictado (⌘D, ⌘,), que no son «estar buscando otra cosa».
    nonisolated static func cancellation(
        forKeyCode keyCode: UInt16,
        handled: Bool
    ) -> HoldGestureCancellation? {
        if navigationKeyCodes.contains(keyCode) { return .navigated }
        // Sin consumir = fue al campo de búsqueda: quien escribe está buscando algo.
        return handled ? nil : .typed
    }

    func show(_ invocation: Invocation = .hotKey) {
        let panel = panel ?? makePanel()
        self.panel = panel

        // Never record OURSELVES as the app to go back to.
        //
        // `returnFocusToPreviousApplication` activates whatever is stored here, and
        // `Paster.pasteToFrontmostApp()` then posts ⌘V to whatever is frontmost at
        // that instant. If the panel is shown while Ámbar is already frontmost —
        // re-invoked with it open, or right after a dictation delivered and left us
        // in front — this captured Ámbar, the activation step became a no-op, and
        // the synthetic ⌘V landed on the panel we had just hidden instead of the
        // user's document. The text was already on the clipboard, so the symptom is
        // exactly "nothing pasted, and ⌘V by hand works".
        //
        // Keeping the previous value is the honest answer, not a fallback: it is
        // still the app the text belongs in.
        if let frontmost = frontmostApplication(),
           frontmost.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            previousApplication = frontmost
        }

        #if DEBUG
        let stepClock = ShowStepClock()
        #endif
        model.searchText = ""
        model.selectFirst()
        #if DEBUG
        stepClock.mark("searchText+selectFirst")
        #endif
        model.refresh()
        #if DEBUG
        stepClock.mark("refresh")
        #endif
        model.refreshPermissionState()
        #if DEBUG
        stepClock.mark("refreshPermissionState")
        #endif

        position(panel)
        #if DEBUG
        stepClock.mark("position")
        #endif
        // Whatever `hide()` did, showing undoes it: a panel left in the window order was
        // made invisible (alpha 0, no mouse, no sharing, content hidden), and one ordered
        // out keeps its last values, so all of them are set back here.
        //
        // History of that split: `hide()` once never ordered the panel out, because
        // `orderOut` + `makeKeyAndOrderFront` with the glass material measured 758 ms per
        // opening against 0.42 ms in place. Measured again on macOS 26 on 2026-10-01,
        // reopening after `orderOut` takes ~16 ms, so `hide()` now orders out whenever it
        // holds the keyboard (see there) and only stays in place when it does not.
        panel.alphaValue = 1
        panel.ignoresMouseEvents = false
        panel.sharingType = .readOnly
        // El contenido vuelve a montarse. Ver la nota de `hide()`.
        hostingView?.isHidden = false
        panel.makeKeyAndOrderFront(nil)
        isVisible = true
        #if DEBUG
        stepClock.mark("orderFront")
        #endif
        installKeyMonitor()
        #if DEBUG
        stepClock.mark("keyMonitor")
        #endif

        // El dictado, si está activado, empieza a contar aquí mismo. Abrir el
        // panel no espera a nada: la cuenta corre en paralelo y no retrasa ni un
        // frame la aparición, que es la promesa central de la app.
        model.syncDictation(panel: self)
        // Un fallo o una entrega de hace un rato no puede reaparecer como si acabara
        // de ocurrir: el banner de fallo no tiene botón de cerrar.
        model.dictation?.resetIfSettled()
        if let dictation = model.dictation,
           Self.armsGesture(
               invocation: invocation,
               holdGestureEnabled: model.settings.isHoldGestureEnabled,
               stickyKeysEnabled: StickyKeys.isEnabled
           ) {
            dictation.shortcutPressed(
                locale: Locale.current,
                mode: model.settings.dictationMode
            )
        }
        #if DEBUG
        stepClock.mark("dictado")
        stepClock.report()
        #endif
    }

    #if DEBUG
    /// Cronómetro por tramos del camino de aparición. Solo en depuración: la latencia del
    /// panel es la promesa central del producto, y «va más lento» no se arregla adivinando
    /// qué tramo cuesta.
    final class ShowStepClock {
        private var last = ContinuousClock.now
        private var steps: [(String, Double)] = []

        func mark(_ name: String) {
            let now = ContinuousClock.now
            let elapsed = now - last
            last = now
            steps.append((
                name,
                Double(elapsed.components.seconds) * 1000
                    + Double(elapsed.components.attoseconds) / 1e15
            ))
        }

        func report() {
            guard ReviewHooks.measuresShowLatency != nil else { return }
            let total = steps.reduce(0) { $0 + $1.1 }
            let detail = steps
                .map { String(format: "%@ %.2f", $0.0, $0.1) }
                .joined(separator: " · ")
            print(String(format: "TRAMOS total=%.2f ms — %@", total, detail))
        }
    }
    #endif

    func hide() {
        // El sondeo del permiso solo tiene sentido con el panel delante: es lo que
        // refresca. Dejarlo vivo era el mayor coste energético de la app en reposo.
        model.stopPermissionWatcher()
        removeKeyMonitor()
        model.onPanelDismissedForTesting?()
        model.dictation?.panelDismissed()
        isVisible = false

        // With the keyboard: out of the window order, at once.
        //
        // This used to make the panel invisible in place (alpha 0) and hope that
        // activating the previous app would take the keyboard back, with a timer ordering
        // it out 120 ms later if not. The panel is non-activating, so the previous app
        // never stopped being active and that activation was a no-op: measured on
        // 2026-10-01, the panel stayed key until the timer fired, on every paste. That held
        // the ⌘V back ~155 ms, and any key pressed meanwhile (the ↵ auto-repeat, the next
        // word typed) went to a window nobody could see, which answers with the system beep.
        //
        // Staying in the order was meant to save the 758 ms the glass used to cost on
        // re-entry. Measured again on macOS 26 the same day: reopening after `orderOut`
        // takes ~16 ms, one frame. And going straight to `orderOut` skips the alpha,
        // sharing and content steps below, which cost ~15 ms of a paste for a window that
        // is about to leave the screen anyway.
        if panel?.isKeyWindow == true {
            panel?.orderOut(nil)
            returnKeyboardToPreviousApplication()
            return
        }

        // Without the keyboard (the user clicked into another app): invisible in place,
        // since nothing is waiting on it and there is no focus to hand back.
        panel?.alphaValue = 0
        panel?.ignoresMouseEvents = true
        // Y **fuera de capturas y selectores de ventana**, que es la garantía documentada y
        // determinista. Ocultar el contenido deja la superficie en blanco, pero medido: la
        // ventana sigue enumerada como «en pantalla» por `CGWindowListCopyWindowInfo`, así
        // que un selector de «compartir ventana» sigue mostrando una entrada de Ámbar.
        // `sharingType = .none` es el mecanismo directo, y estaba a mano sin usar.
        panel?.sharingType = .none
        // Y el CONTENIDO se oculta, no solo la ventana: con la superficie conservando el
        // último fotograma, lo que un selector de compartir ventana enumeraría es **el
        // historial**, las vistas previas de todo lo copiado.
        hostingView?.isHidden = true
    }

    /// Devuelve el teclado a la app que lo tenía antes de abrir el panel.
    ///
    /// Only needed when that app is not active any more; the panel is non-activating,
    /// so normally it still is, and activating it again would be wasted work.
    private func returnKeyboardToPreviousApplication() {
        guard let previous = previousApplication,
              !previous.isTerminated,
              !previous.isActive,
              previous.processIdentifier != ProcessInfo.processInfo.processIdentifier
        else { return }
        previous.activate()
    }

    /// Coloca el panel donde el usuario lo dejó, o centrado si aún no lo movió.
    private func position(_ panel: NSPanel) {
        let screens = NSScreen.screens.map(\.visibleFrame)

        if let saved = savedOrigin,
           PanelPlacement.isUsable(origin: saved, size: panel.frame.size, screens: screens) {
            panel.setFrameOrigin(saved)
            return
        }
        centerOnActiveScreen(panel)
    }

    /// Centra en la pantalla donde está el cursor.
    ///
    /// Con varios monitores, aparecer siempre en el principal obliga a cruzar
    /// el escritorio con la vista. La pantalla del cursor es la que el usuario
    /// está mirando.
    private func centerOnActiveScreen(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }

        panel.setFrameOrigin(
            PanelPlacement.centered(in: frame, size: panel.frame.size)
        )
    }

    // MARK: - Posición recordada

    private static let originKey = "panel.origin"

    private var savedOrigin: NSPoint? {
        guard let stored = UserDefaults.standard.string(forKey: Self.originKey) else { return nil }
        let point = NSPointFromString(stored)
        return point == .zero ? nil : point
    }

    private func observeMovement(of panel: NSPanel) {
        moveObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification,
            object: panel,
            queue: .main
        // No se captura la `Notification`: no es `Sendable` y cruzarla al actor
        // principal es una carrera potencial. El origen se lee del panel, que
        // ya vive en el actor.
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let origin = self?.panel?.frame.origin else { return }
                UserDefaults.standard.set(
                    NSStringFromPoint(origin),
                    forKey: Self.originKey
                )
            }
        }
    }

    /// Devuelve el panel al centro y olvida la posición guardada.
    func resetPosition() {
        UserDefaults.standard.removeObject(forKey: Self.originKey)
        if let panel { centerOnActiveScreen(panel) }
    }

    private func makePanel() -> AmbarPanel {
        let panel = AmbarPanel(
            contentRect: NSRect(x: 0, y: 0, width: Metrics.panelWidth, height: Metrics.panelHeight),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .utilityWindow
        // Arrastrable desde el fondo, como Spotlight. AppKit solo inicia el
        // arrastre cuando el clic cae en una zona sin control interactivo, así
        // que no interfiere con seleccionar filas ni con el campo de búsqueda.
        panel.isMovableByWindowBackground = true
        // Sin esto AppKit no genera eventos de movimiento del ratón para esta
        // ventana, y el monitor que cancela la cuenta del gesto al mover el ratón
        // —la mitigación principal contra dispararlo mientras se recorre la lista—
        // no recibía absolutamente nada.
        panel.acceptsMouseMovedEvents = true
        // Aparece sobre cualquier escritorio y encima de apps a pantalla
        // completa; sin esto el atajo no haría nada mientras se trabaja en
        // pantalla completa, que es cuando más falta hace.
        //
        // Los tres primeros no bastaban, y el síntoma era exacto: con otra app a pantalla
        // completa, abrir el panel **sacaba al usuario de ella** y lo dejaba en el
        // escritorio. `canJoinAllSpaces` cubre los escritorios (Espacio 1, Espacio 2…) y
        // `fullScreenAuxiliary` cubre la pantalla completa **de la propia app**; el
        // espacio de pantalla completa de OTRA app es un tercer caso, y el que lo cubre es
        // `canJoinAllApplications` — el header del SDK lo dice literalmente: «able to join
        // all applications, allowing it to join other apps' sets and full screen spaces…
        // commonly used for floating windows and system overlays» (`NSWindow.h:98`,
        // macOS 13+). Sin él, macOS no puede mostrar la ventana en ese espacio y resuelve
        // cambiando de espacio, que es justo lo que Spotlight no hace.
        //
        // No colisiona con `fullScreenAuxiliary`: el SDK declara dos grupos de
        // exclusividad distintos —`Primary`/`Auxiliary`/`CanJoinAllApplications` por un
        // lado (`NSWindow.h:94`), `FullScreenPrimary`/`FullScreenAuxiliary`/
        // `FullScreenNone` por otro (`NSWindow.h:115`)— y estos dos están en grupos
        // separados.
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .transient,
            .canJoinAllApplications,
        ]

        let root = ContentView(model: model, controller: self)
        let hosting = NSHostingView(rootView: root)
        hostingView = hosting
        hosting.frame = panel.contentLayoutRect

        // El contenido debe recortarse al MISMO radio que el cristal. El
        // `NSGlassEffectView` redondea su material, pero no impone forma a su
        // `contentView`: sin esto, el rectángulo de SwiftUI asoma por las
        // cuatro esquinas y se ven cuatro escuadras opacas sobre el cristal.
        hosting.wantsLayer = true
        hosting.layer?.cornerRadius = Metrics.panelCornerRadius
        // `.continuous` es la curva de los squircles del sistema. Con la
        // circular por defecto el canto no casa con el del material y se nota
        // un escalón de un píxel en la diagonal de cada esquina.
        hosting.layer?.cornerCurve = .continuous
        hosting.layer?.masksToBounds = true
        // Sin fondo propio: cualquier color aquí taparía el cristal.
        hosting.layer?.backgroundColor = NSColor.clear.cgColor

        // El material envuelve toda la jerarquía de SwiftUI y muestrea lo que
        // hay tras la ventana: es el efecto real del sistema, no una
        // transparencia simulada.
        let backdrop = Glass.makeWindowBackdrop(
            content: hosting,
            cornerRadius: Metrics.panelCornerRadius,
            style: .regular
        )
        panel.contentView = backdrop
        hosting.autoresizingMask = [.width, .height]

        // No siempre se puede cerrar al perder el foco: con una sesión de dictado
        // viva quedaría el micrófono abierto sin interfaz, y durante el diálogo de
        // permiso del sistema el panel desaparecería justo cuando el usuario acaba
        // de conceder. Ver `PanelDismissalPolicy`.
        panel.onCancel = { [weak self] in self?.hide() }
        panel.onUnhandledEvent = { [weak self] selector in
            // Only a key nobody took beeps; unhandled mouse moves are routine.
            guard selector == #selector(NSResponder.keyDown(with:)) else { return }
            self?.tracePaste("keyDown nobody handled → system beep")
        }
        panel.onResignKey = { [weak self] in
            // `hide()` itself orders the panel out, which resigns key and lands here:
            // without the visibility check every dismissal would run twice.
            guard let self, self.isVisible, self.dismissalPolicy.shouldHideOnResignKey
            else { return }
            self.hide()
        }
        observeMovement(of: panel)
        return panel
    }

    // MARK: - Teclado

    /// Intercepta las teclas de navegación antes de que lleguen al campo de
    /// búsqueda, que tiene el foco mientras el panel está abierto.
    private func installKeyMonitor() {
        removeKeyMonitor()
        // Los dos monitores son deliberadamente delgados: delegan en un método propio en
        // vez de llevar la lógica dentro del closure. `NSEvent.addLocalMonitorForEvents`
        // solo entrega eventos reales a través del run loop de AppKit — nada que un test
        // de `swift test` pueda disparar sin ventana ni sesión gráfica — así que un
        // closure que hiciera el trabajo aquí dentro quedaría **estructuralmente**
        // invisible a cualquier test: nada podría invocarlo, y borrar la línea que cancela
        // el gesto no rompería nada. Con el trabajo en un método, el método sí se puede
        // llamar directamente desde un test — ver `KeyAndPointerCancellationTests` — y ES
        // exactamente el código que el monitor ejecuta, no una copia.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            self?.handleMonitoredKeyDown(event) ?? event
        }
        pointerMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.mouseMoved, .scrollWheel, .leftMouseDown]
        ) { [weak self] event in
            self?.handleMonitoredPointerEvent(event)
            return event
        }
    }

    /// Lo que hace el monitor de teclado. Ver el comentario de `installKeyMonitor`: esto
    /// existe separado del closure para que un test pueda llamarlo directamente.
    ///
    /// - Returns: `nil` si el evento se consumió (no debe propagarse), el evento en caso
    ///   contrario — el mismo contrato que espera `NSEvent.addLocalMonitorForEvents`.
    @discardableResult
    func handleMonitoredKeyDown(_ event: NSEvent) -> NSEvent? {
        // An open word editor owns the keyboard. The monitor sees keyDown BEFORE the
        // focused view does, and it claims exactly the keys a text field needs: ⏎
        // stopped the dictation instead of committing the correction, ⎋ closed the
        // panel instead of cancelling the edit, and the arrows moved the history
        // selection under the cursor. Yielding here is what makes inline editing
        // possible at all — see `DictationController.isEditingWord`.
        if model.dictation?.isEditingWord == true { return event }
        // El orden importa, y estaba al revés: la cancelación por «teclear» se emitía
        // ANTES de mirar qué tecla era, así que ⌘D se cancelaba a sí mismo. La cuenta
        // ya estaba muerta cuando `commandDAction` leía el estado, y su rama de
        // descartar —la respuesta útil en `.preparing` y `.finalizing`— era inalcanzable
        // en producción, con un test afirmando una rama que la app no podía recorrer.
        //
        // Un atajo de la propia función de dictado no es «estar buscando algo».
        let handled = self.handle(event)
        if let cause = Self.cancellation(forKeyCode: event.keyCode, handled: handled) {
            self.model.dictation?.interactionOccurred(cause)
        }
        return handled ? nil : event
    }

    /// Lo que hace el monitor de ratón/scroll. Mismo motivo que `handleMonitoredKeyDown`:
    /// sin esto, el gesto se dispararía mientras el ojo recorre la lista, que es el flujo
    /// más común de la app — y era exactamente lo que ninguna suite podía comprobar.
    func handleMonitoredPointerEvent(_ event: NSEvent) {
        model.dictation?.interactionOccurred(Self.pointerCancellation(for: event.type))
    }

    /// El scroll cuenta aparte del resto: es la única causa de las tres que no implica
    /// mover el ratón, así que el anuncio que la acompaña puede ser más específico
    /// («al desplazar» en vez de «al mover el ratón»).
    nonisolated static func pointerCancellation(
        for eventType: NSEvent.EventType
    ) -> HoldGestureCancellation {
        eventType == .scrollWheel ? .scrolled : .pointerMoved
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if let pointerMonitor { NSEvent.removeMonitor(pointerMonitor) }
        pointerMonitor = nil
    }

    func handle(_ event: NSEvent) -> Bool {
        let command = event.modifierFlags.contains(.command)

        // ⌘D dicta, para o descarta según el estado, sin mantener nada. Es la vía por
        // teclado que §8.5 promete: el botón del micrófono solo sirve con ratón, y Acceso
        // Completo por Teclado —que es lo que permitiría tabular hasta él— viene desactivado
        // en macOS, así que sin atajo no hay camino.
        if command, event.keyCode == UInt16(kVK_ANSI_D), let dictation = model.dictation {
            switch DictationEntryPoints.commandDAction(for: dictation.state) {
            case .stop:
                dictation.stop()
            case .start:
                dictation.startWithoutGesture(
                    locale: Locale.current,
                    mode: model.settings.dictationMode
                )
            case .discard:
                dictation.discard()
            }
            return true
        }

        // ⌘, lleva al ajuste que resuelve lo que hay en pantalla. Es la única ruta por
        // teclado a los botones de remedio del banner: ver `settingsShortcutTarget`.
        if command, event.keyCode == UInt16(kVK_ANSI_Comma) {
            switch DictationEntryPoints.settingsShortcutTarget(
                state: model.dictation?.state,
                failure: model.dictation?.lastFailure
            ) {
            case .systemMicrophone:
                if let url = MicrophoneAuthorization.settingsURL {
                    NSWorkspace.shared.open(url)
                } else {
                    model.onOpenSettings?()
                }
            case .appSettings:
                model.onOpenSettings?()
            }
            return true
        }

        switch event.keyCode {
        case 53:  // esc
            hide()
            return true

        case 125:  // ↓
            model.moveSelection(by: 1)
            return true

        case 126:  // ↑
            model.moveSelection(by: -1)
            return true

        case 121:  // avanzar página
            model.moveSelection(by: 8)
            return true

        case 116:  // retroceder página
            model.moveSelection(by: -8)
            return true

        case 36, 76:  // ↵ / teclado numérico
            // Con el micrófono abierto, ⏎ **para el dictado**. Es la salida natural del
            // nuevo modelo de interacción —el gesto arranca y las manos quedan libres—, y
            // pegar otra entrada del historial a mitad de un dictado no es lo que nadie
            // quiere: mataría la sesión en silencio y pegaría lo que no era.
            if let dictation = model.dictation,
               DictationEntryPoints.enterAction(for: dictation.state) == .stopDictation {
                dictation.stop()
                return true
            }
            guard let item = model.selectedItem else { return true }
            paste(item: item, plainText: command, afterReleasing: CGKeyCode(event.keyCode))
            return true

        case 51 where command && dictationDiscards:  // ⌘⌫ con el micrófono abierto
            model.dictation?.discard()
            return true

        case 51 where command:  // ⌘⌫
            if let item = model.selectedItem { model.delete(item: item) }
            return true

        case 35 where command:  // ⌘P
            if let item = model.selectedItem { model.togglePin(item: item) }
            return true

        case 8 where command && !event.modifierFlags.contains(.shift):  // ⌘C
            // ⌘C copies the selected entry, the way anyone expects it to in a clipboard
            // history. Without this it fell through to the search field, which has nothing
            // selected to copy, and AppKit answered with the system beep: the "bip al
            // copiar" reported on 2026-10-01. Text selected in the search field still
            // copies as text.
            if searchFieldHasSelection { return false }
            if let item = model.selectedItem { copy(item: item) }
            return true

        default:
            return false
        }
    }

    /// Pastes once the key that asked for it is back up. See `Paster.waitForKeyRelease`.
    private func paste(item: ClipboardItem, plainText: Bool, afterReleasing keyCode: CGKeyCode) {
        // One paste per keystroke: a second ↵ while the first is still held would queue
        // a second paste of the same entry.
        guard !isAwaitingKeyRelease else { return }
        isAwaitingKeyRelease = true
        pasteStartedAt = .now
        tracePaste("↵ down")
        Task { @MainActor in
            await Paster.waitForKeyRelease(keyCode)
            self.isAwaitingKeyRelease = false
            self.tracePaste("↵ up")
            self.paste(item: item, plainText: plainText, startedAt: self.pasteStartedAt)
        }
    }

    /// Whether the search field has text selected, which ⌘C should copy as text.
    private var searchFieldHasSelection: Bool {
        guard let editor = panel?.firstResponder as? NSTextView else { return false }
        return editor.selectedRange().length > 0
    }

    /// Puts the entry on the clipboard and closes the panel, without pasting it anywhere.
    ///
    /// The same staging as a paste, minus the ⌘V: the write is all that has to happen
    /// before the panel goes, and moving the entry to the top happens after.
    func copy(item: ClipboardItem) {
        guard model.writeToPasteboard(item: item, plainText: false, to: pasteboard()) else {
            return
        }
        hide()
        model.promote(item: item)
    }

    // MARK: - Pegado

    /// Deja la entrada en el portapapeles, devuelve el foco a la app anterior y
    /// pega en ella.
    ///
    /// El orden es lo que hace que esto funcione. El sistema entrega el ⌘V
    /// sintético a lo que esté en primer plano **en ese instante**, así que hay
    /// que: dejar el contenido puesto, cerrar el panel, esperar a que la app de
    /// destino esté realmente activa —no un plazo fijo, que unas veces llega y
    /// otras no— y solo entonces enviar el atajo.
    func paste(item: ClipboardItem, plainText: Bool, startedAt: ContinuousClock.Instant? = nil) {
        // Sin permiso no se puede pegar. En vez de cerrar el panel y no hacer
        // nada —que se lee como que la app está rota—, el contenido se copia,
        // el panel se queda abierto y el aviso del pie llama la atención.
        guard model.canAutoPaste else {
            _ = model.stage(item: item, plainText: plainText)
            model.flagMissingPastePermission()
            return
        }

        pasteStartedAt = startedAt ?? .now
        tracePaste("paste requested")
        // Only the pasteboard write sits before the paste. Promoting the entry to the top
        // of the history re-queries and re-lays out the list, and nobody sees that list
        // until the next opening, so it runs after the ⌘V has left.
        guard model.writeToPasteboard(item: item, plainText: plainText, to: pasteboard()) else {
            return
        }
        tracePaste("staged")

        hide()
        tracePaste("hidden")

        Task { @MainActor in
            await performSyntheticPaste()
            model.promote(item: item)
            tracePaste("promoted")
        }
    }

    /// Pega un texto dictado en la app donde estaba el usuario.
    ///
    /// Reusa el mismo camino que pegar del historial —y sus dos esperas, que están
    /// ahí por buenas razones: la activación de la otra app es asíncrona, y enviar
    /// el ⌘V sintético con los modificadores del atajo todavía hundidos hace que la
    /// app de destino reciba otra combinación.
    ///
    /// Sin permiso de accesibilidad el texto no se pega pero **sí** queda en el
    /// portapapeles y en el historial, y se avisa en lugar de fallar en silencio.
    ///
    /// El parámetro se llamaba `keepPanelOpen` y el panel se cierra **siempre**: el
    /// nombre afirmaba lo contrario de lo que hace el código, tres líneas por encima de
    /// un comentario que lo explicaba bien.
    /// ¿Tenemos permiso de accesibilidad para pegar?
    ///
    /// Inyectable porque el proceso de test **nunca** lo tiene, y sin esto todo lo que hay
    /// detrás de esta puerta —la confesión de recorte incluida— era inalcanzable desde un
    /// test: se podía borrar entera con la suite en verde.
    var canPaste: @MainActor () -> Bool = { Paster.canPaste }

    /// La secuencia real que entrega el texto en la app de destino: activar la app
    /// anterior, esperar a que los modificadores del atajo se suelten, y postear el ⌘V
    /// sintético — un evento de teclado real, a nivel de sistema, con `CGEvent`.
    ///
    /// Inyectable, y no por simetría con `canPaste`: es la única defensa contra el fallo
    /// que de hecho ocurrió. Un test de esta ronda dejaba correr esta secuencia sin más,
    /// y `Paster.pasteToFrontmostApp()` envía el ⌘V a lo que sea que esté en primer
    /// plano en la máquina **en ese instante** — no en un sandbox del test, en el
    /// escritorio real. Cada `swift test` que ejercitara `pasteDictated`/`paste(item:)`
    /// pegaba de verdad el texto de prueba en lo que el usuario tuviera delante,
    /// repetidamente, cada vez que la suite corría — incluida cada pasada de las
    /// auditorías en segundo plano de esta misma sesión. En producción es la secuencia
    /// real; en cualquier test tiene que sustituirse por un no-op.
    /// A qué portapapeles escribe el panel. Inyectable, y por el mismo motivo que
    /// `performSyntheticPaste`: el incidente anterior cubrió el **pegado** —el ⌘V
    /// sintético— y dejó fuera la **escritura**, que sigue yendo a `NSPasteboard.general`
    /// por defecto. Medido por una auditoría independiente: tras correr la suite,
    /// `osascript -e 'the clipboard as text'` devolvía el texto de prueba. Cada
    /// `swift test` local le borraba al usuario lo que tuviera copiado, sin aviso.
    ///
    /// El patrón correcto ya existía a treinta líneas (`ArchivingTests.scratchPasteboard`,
    /// «para no dejar la máquina distinta de como la encontró»): el arreglo aterrizó en un
    /// camino y le faltaba al hermano.
    var pasteboard: @MainActor () -> NSPasteboard = { .general }

    /// Review-only timeline of the paste sequence: each step with the milliseconds since
    /// the paste began. Nil in normal use, so it costs one optional check per step.
    var pasteTrace: (@MainActor (String) -> Void)?
    private var pasteStartedAt: ContinuousClock.Instant?
    private var isAwaitingKeyRelease = false

    private func tracePaste(_ step: String) {
        guard let pasteTrace else { return }
        let elapsed = pasteStartedAt.map { ContinuousClock.now - $0 } ?? .zero
        let ms = Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000
        pasteTrace(String(format: "%7.1f ms  %@  key=%@", ms, step, panel?.isKeyWindow == true ? "panel" : "other"))
    }

    lazy var performSyntheticPaste: @MainActor () async -> Void = { [weak self] in
        guard let self else { return }
        // PRIMERO: que el panel deje de ser la ventana clave.
        //
        // Es la causa raíz del «no pega» intermitente. `hide()` oculta el panel bajando su
        // alfa —a propósito, para no recomponer el material de cristal en cada apertura— y eso
        // **no le quita la condición de ventana clave** al instante. Mientras la conserva, el
        // teclado de la sesión es suyo: es exactamente lo que permite escribir en su campo de
        // búsqueda sin activar la app, y lo que hace que un ⌘V sintético posteado demasiado
        // pronto se entregue a una ventana invisible sin campo enfocado, donde no hace nada.
        //
        // Medido: la misma prueba, con el mismo permiso y el mismo contenido en el
        // portapapeles, pegaba unas veces y otras no. Nada fallaba —ni el `stage`, ni el
        // permiso, ni el post— y el contenido quedaba en el portapapeles, así que el usuario
        // veía «no pega» sin ningún error.
        await self.waitUntilPanelResignsKey()
        self.tracePaste("panel resigned key")
        await self.returnFocusToPreviousApplication()
        self.tracePaste("previous app active")
        // Y se espera a que el **teclado** vuelva a la app de destino, que no es lo mismo que
        // esté activa: nunca dejó de estarlo, así que `isActive` no distinguía nada.
        if let pid = self.previousApplication?.processIdentifier {
            await Paster.waitForKeyboardFocus(pid: pid)
        }
        self.tracePaste("keyboard focus back")
        await Paster.waitForModifiersToClear()
        self.tracePaste("modifiers clear")
        // **El resultado se mira.** Se descartaba, y con él la única señal de que el pegado
        // no llegó a enviarse: el panel se cerraba, no pasaba nada, y desde fuera eso es
        // indistinguible de una app rota. El contenido sí está en el portapapeles —se escribe
        // antes—, así que lo que hay que decir es «pégalo tú», no callar.
        guard Paster.pasteToFrontmostApp() else {
            self.model.reportPasteFailure()
            // El aviso vive DENTRO del panel, así que hay que volver a mostrarlo: es el mismo
            // motivo por el que el camino del dictado no lo oculta cuando falta el permiso.
            self.show(.menu)
            return
        }
        self.tracePaste("⌘V posted")
    }

    func pasteDictated(_ plan: DictationDelivery) {
        let text = plan.text
        guard !text.isEmpty else { return }
        // Escribir y acusar el cambio, en una sola llamada. La entrada duplicada la impide
        // la marca de auto-generado; el acuse evita además que el vigilante llegue a leer
        // lo que acabamos de escribir (ver `writeDictatedToPasteboard`). Y el marcado de
        // sensible viene del plan, no se decide aquí: la misma condición del archivado,
        // negada.
        model.writeDictatedToPasteboard(plan, to: pasteboard())

        guard canPaste() else {
            // No se oculta el panel: el aviso que enciende `flagMissingPastePermission`
            // vive DENTRO del panel, así que cerrarlo dejaba al usuario sin texto
            // pegado y sin ninguna explicación. Es lo mismo que hace `paste(item:)`
            // treinta líneas más arriba, y por el mismo motivo.
            model.flagMissingPastePermission()
            return
        }

        // El panel se cierra SIEMPRE antes de postear el ⌘V sintético. Mantenerlo
        // abierto para que se leyera la confesión de recorte enviaba el pegado al
        // campo de búsqueda de Ámbar en lugar del documento: el orden
        // «poner contenido → cerrar → esperar activación → postear» es load-bearing.
        hide()
        // La confesión sobrevive al cierre como aviso del modelo, no dentro del panel.
        if plan.confessesTruncation {
            model.reportTruncatedDictation()
        }
        Task { @MainActor in
            await performSyntheticPaste()
        }
    }

    /// Devuelve el foco a la app en la que estaba el usuario y espera a que la
    /// activación se haya completado de verdad.
    /// Espera a que el panel ceda la condición de ventana clave.
    ///
    /// Con techo, y por el mismo motivo que las otras dos esperas de esta secuencia: si por lo
    /// que sea no la cede, es mejor postear el ⌘V —que quizá funcione— que quedarse colgado.
    private func waitUntilPanelResignsKey(timeout: Duration = .milliseconds(400)) async {
        guard let panel else { return }
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline, panel.isKeyWindow {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private func returnFocusToPreviousApplication() async {
        guard let application = previousApplication, !application.isTerminated else { return }

        if !application.isActive {
            application.activate()
        }

        // Hasta medio segundo, comprobando. Activar una app es asíncrono y su
        // duración depende de la carga del sistema: un `sleep` fijo funciona en
        // la máquina de quien lo escribe y falla en la del usuario.
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(500))
        while ContinuousClock.now < deadline, !application.isActive {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

/// `NSPanel` sin borde que puede ser ventana clave.
///
/// Una ventana `.borderless` devuelve `false` en `canBecomeKey` por defecto y
/// entonces el campo de búsqueda nunca recibiría lo que se teclea.
final class AmbarPanel: NSPanel {
    var onResignKey: (() -> Void)?
    /// Cierre explícito pedido por el usuario (⎋, ⌘W, ⌘.). No lo bloquea la política.
    var onCancel: (() -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }

    /// ⌘W y ⌘. cierran el panel, como cualquier ventana de utilidad de macOS.
    ///
    /// Van por `onCancel` y no por `onResignKey`: la política de cierre bloquea
    /// `onResignKey` mientras hay una sesión de dictado viva, así que estos dos
    /// atajos estándar se quedaban mudos justo en el estado en el que más falta hace
    /// poder salir.
    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    /// Review-only: an event no responder took, which AppKit answers with a beep.
    var onUnhandledEvent: ((Selector) -> Void)?

    override func noResponder(for eventSelector: Selector) {
        onUnhandledEvent?(eventSelector)
        super.noResponder(for: eventSelector)
    }
}
