import AppCore
import ClipboardKit
import AppKit
import GlassUI
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var statusItem: NSStatusItem?
    private var panelController: PanelController?
    private var onboarding: OnboardingController?
    private var settingsWindow: NSWindow?
    private var hotKeyID: UInt32?
    private let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        #if DEBUG
        ReviewHooks.applyAccessibilityOverrides()
        #endif

        model.start()

        // La preferencia de arranque, contra el registro real del sistema. Aquí y no en
        // el `didSet`: ese solo corre al cambiarla, y el registro se pierde al reinstalar
        // o mover la app — dejando la casilla marcada y Ámbar sin arrancar sola.
        model.settings.reconcileLaunchAtLogin()

        let controller = PanelController(model: model)
        panelController = controller

        installStatusItem()
        registerHotKey()
        // Sin esto no se podía pegar en el campo de búsqueda de un gestor de portapapeles.
        // AppKit reparte ⌘V/⌘C/⌘X/⌘A/⌘Z por el menú principal, y no había ninguno. Ver
        // `EditMenu` para la medición que lo confirma.
        NSApp.mainMenu = EditMenu.makeMainMenu()
        // El modelo pide el re-registro cuando cambia el ajuste; el delegado es
        // quien posee el registro Carbon y lo ejecuta.
        model.onHotKeyChange = { [weak self] in self?.registerHotKey() }

        // El presentador se monta ANTES de los modos de revisión: uno de ellos vuelca el
        // árbol de accesibilidad de esta ventana, y sin el presentador en pie no habría
        // ventana que volcar —el gate diría «sin nombre» de controles que sí lo tienen, que
        // es el modo de fallo que ese arnés existe para evitar—.
        installOnboarding()

        #if DEBUG
        // Los modos de revisión pueden terminar la app por su cuenta; si lo
        // hacen, no tiene sentido pedir permisos por el camino.
        if ReviewHooks.run(model: model, controller: controller, onboarding: onboarding) { return }
        #endif

        // Sin permiso de accesibilidad la app copia pero no pega.
        //
        // **Solo se pide a pelo cuando NO hay presentación**, y esa condición es el arreglo:
        // antes este diálogo era lo primero que veía quien abría Ámbar por primera vez —una
        // app que aún no se había presentado pidiendo el permiso más delicado que macOS
        // concede—, y decir «no» ahí dejaba media app sin explicación. Ahora el permiso lo
        // pide un paso que antes cuenta para qué sirve. Si el usuario ya vio la
        // presentación, este camino sigue siendo el correcto: la app arranca y, si el
        // permiso falta, lo pide una vez.
        if let onboarding, !suppressesPrompts, OnboardingController.shouldPresent(settings: model.settings) {
            onboarding.present()
        } else if !Paster.canPaste && !suppressesPrompts {
            Paster.requestAccessibilityPermission()
        }
    }

    /// Monta el presentador y deja que Ajustes pueda volver a llamarlo.
    private func installOnboarding() {
        let controller = OnboardingController(model: model) { [weak self] in
            // Primera impresión: al terminar se abre el historial. Con el panel delante, el
            // atajo que se acaba de explicar tiene algo que enseñar; sin esto la app
            // desaparece en la barra de menús justo después de presentarse.
            self?.panelController?.show(.menu)
        }
        onboarding = controller
        model.onReplayOnboarding = { [weak controller] in controller?.presentAgain() }
    }

    /// La ventana de la presentación, para el arnés que vuelca el árbol de accesibilidad.
    var onboardingWindowForReview: NSWindow? { onboarding?.windowForReview }

    /// Solo para tests y para el arnés: fuerza la presentación sin depender del estado
    /// guardado en la máquina que la ejecute.
    func presentOnboardingForReview() {
        if onboarding == nil { installOnboarding() }
        onboarding?.present()
    }

    /// Los diálogos modales bloquearían cualquier verificación automatizada.
    /// En producción no hay forma de suprimirlos.
    private var suppressesPrompts: Bool {
        #if DEBUG
        ReviewHooks.suppressesPrompts
        #else
        false
        #endif
    }

    func applicationWillTerminate(_ notification: Notification) {
        HotKeyCenter.shared.unregisterAll()
    }

    // MARK: - Barra de menús

    /// ¿Está el micrófono abierto? Lo recuerda el delegado porque el icono depende
    /// de **dos** fuentes que cambian por su cuenta, y pasarlo por parámetro hacía que
    /// cualquier refresco por la pausa apagara el indicador del micrófono.
    private var isDictating = false

    /// Despertar programado para cuando una pausa temporal vence.
    private var pauseWatcher: Timer?

    /// Lo último que se pintó. Sin esto, el icono se reconstruía **en cada tic de la
    /// cuenta del gesto** —25 veces por segundo—: un `NSImage` nuevo, un redibujo del
    /// `NSStatusItem`, una lectura de `UserDefaults` y, con una pausa temporal activa, un
    /// `Timer` invalidado y creado de nuevo. Todo en el hilo principal, en la ventana
    /// exacta en la que el producto se define por la latencia.
    private var shownPresence: MenuBarPresence?

    /// Refleja en la barra de menús lo que la app está haciendo.
    ///
    /// Ámbar es un agente sin icono en el Dock, así que la barra de menús es su
    /// única presencia permanente. Si el panel está cerrado o tapado, este símbolo
    /// es lo único que puede contestar «¿quién me está escuchando?» y «¿está
    /// guardando?».
    /// Cablea el aviso de «el micrófono se abrió/cerró» hacia el icono de la barra.
    ///
    /// Separado de `applicationDidFinishLaunching` para que un test pueda cablearlo sin
    /// pasar por `installStatusItem()`/`registerHotKey()` — que tocan recursos reales
    /// del sistema (la barra de estado, un atajo global Carbon) y no se pueden ejercitar
    /// en `swift test` sin arriesgar interferir con la instancia de verdad que pueda
    /// estar corriendo en la máquina.
    func wireDictationStateChange() {
        model.onDictationStateChange = { [weak self] listening in
            self?.applyDictationState(listening)
        }
    }

    /// Aplica el estado del micrófono al icono. Es el sitio real que
    /// `wireDictationStateChange` engancha — antes esa asignación vivía en línea dentro
    /// del closure, invisible a cualquier test: `isDictating = listening` se podía
    /// sustituir por `isDictating = false` sin que nada lo notara, y es la única
    /// presencia permanente de la app —la barra de menús— la que mentiría.
    func applyDictationState(_ listening: Bool) {
        isDictating = listening
        reflectMenuBarState()
    }

    /// Solo para tests: lo que el icono cree que está pasando ahora mismo.
    var isDictatingForTesting: Bool { isDictating }

    /// Solo para tests: dispara el aviso como haría el coordinador del dictado real.
    /// `model` es privado a propósito —nadie fuera del delegado debería tocarlo— así
    /// que esto es la única puerta.
    func callOnDictationStateChangeForTesting(_ listening: Bool) {
        model.onDictationStateChange?(listening)
    }

        func reflectMenuBarState() {
        // La pausa vencida se limpia antes de mirar: el estado se deriva del reloj y
        // esta es la única forma de que el icono no siga afirmando una protección que
        // ya expiró.
        model.settings.prunePauseIfExpired()
        let update = MenuBarPresence.update(
            isDictating: isDictating,
            pause: model.settings.pause,
            shown: shownPresence
        )
        let presence = update.presence
        // El despertar del vencimiento se programa SIEMPRE, aunque el icono no cambie:
        // salir antes por deduplicación dejaría una pausa temporal sin nadie que la
        // caduque, que es el fallo que este temporizador existe para evitar.
        defer { schedulePauseRefresh() }
        guard update.needsRedraw else { return }
        shownPresence = presence
        statusItem?.button?.image = Self.icon(for: presence)
    }

    /// La imagen de la barra para una presencia.
    ///
    /// `isTemplate` se pone aquí y no en quien la recibe: olvidarlo es el fallo
    /// clásico de un icono de estado —sale negro sobre la barra oscura y solo
    /// se ve al pasar el ratón— y con la marca dibujada a mano no hay nadie
    /// más que lo vaya a poner.
    private static func icon(for presence: MenuBarPresence) -> NSImage? {
        switch presence.glyph {
        case .mark:
            return MenuBarGlyph.image()
        case .system(let name):
            let image = NSImage(
                systemSymbolName: name,
                accessibilityDescription: presence.description
            )
            image?.isTemplate = true
            return image
        }
    }

    /// Programa el refresco del vencimiento, o lo cancela si no hay nada que esperar.
    ///
    /// Sin esto, una pausa de quince minutos dejaba el icono en «pausado» para siempre:
    /// nadie emite un evento cuando una fecha pasa, y afirmar una protección caducada
    /// es peor que no mostrarla.
    private func schedulePauseRefresh() {
        pauseWatcher?.invalidate()
        pauseWatcher = nil
        guard let delay = MenuBarPresence.refreshDelay(pause: model.settings.pause) else {
            return
        }
        // En modo `.common`: con `scheduledTimer` a secas, el modo por omisión **no dispara
        // con un menú abierto** — y este temporizador existe para que el icono deje de
        // afirmar una pausa caducada y para reconstruir el menú, o sea justo cuando es más
        // probable que el usuario lo esté mirando. El monitor del portapapeles y la
        // retención ya usaban `.common` con este mismo motivo escrito al lado; el arreglo no
        // había llegado a este canal.
        let timer = Timer(timeInterval: delay, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.statusItem?.menu = self?.buildMenu()
                self?.reflectMenuBarState()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pauseWatcher = timer
    }

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = Self.icon(for: .idle)
        item.menu = buildMenu()
        statusItem = item

        model.onOpenSettings = { [weak self] in self?.openSettings() }
        wireDictationStateChange()
        // Cualquier cambio de la pausa pasa por aquí —Ajustes, el panel y el menú
        // llaman todos a `syncSettingsToServices()`—, así que es el único sitio donde
        // hay que enganchar el icono. Colgarlo solo del menú era la razón de que pausar
        // desde Ajustes dejara el icono diciendo que se seguía guardando.
        model.onCaptureStateChange = { [weak self] in
            self?.statusItem?.menu = self?.buildMenu()
            self?.reflectMenuBarState()
        }
        reflectMenuBarState()
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()

        // Lo primero, si pasa: quien pulsa el atajo y no ve nada abre este menú, y hasta ahora
        // encontraba una app aparentemente sana. El aviso va arriba porque es la explicación
        // de por qué está mirando aquí.
        if model.isHotKeyUnavailable {
            let warning = NSMenuItem(
                title: String(localized: "hotkey.unavailable", bundle: .localized),
                action: nil,
                keyEquivalent: ""
            )
            warning.isEnabled = false
            menu.addItem(warning)
            menu.addItem(.separator())
        }

        let open = NSMenuItem(
            title: String(localized: "menu.open", bundle: .localized),
            action: #selector(togglePanel),
            keyEquivalent: ""
        )
        open.target = self
        menu.addItem(open)

        menu.addItem(.separator())

        let pause = NSMenuItem(
            title: String(localized: "menu.pause", bundle: .localized),
            action: #selector(togglePause),
            keyEquivalent: ""
        )
        pause.target = self
        pause.state = model.settings.isPaused ? .on : .off
        menu.addItem(pause)

        // La pausa con duración era inalcanzable: solo se llegaba a la indefinida,
        // que es justamente el modo de fallo que la duración existe para evitar
        // —olvidarse de que está puesta y perder semanas de historial.
        let pauseSubmenu = NSMenu()
        for duration in HistoryPause.Duration.allCases {
            let item = NSMenuItem(
                title: Self.pauseTitle(for: duration),
                action: #selector(pauseForDuration(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = duration.rawValue
            pauseSubmenu.addItem(item)
        }
        let pauseFor = NSMenuItem(
            title: String(localized: "menu.pause_for", bundle: .localized),
            action: nil,
            keyEquivalent: ""
        )
        pauseFor.submenu = pauseSubmenu
        menu.addItem(pauseFor)

        // Y si hay una pausa en marcha, cuánto queda. Creerse en pausa sin estarlo
        // —o al revés— es un problema real de privacidad, no un detalle.
        if let remaining = model.settings.remainingPause {
            let minutes = max(1, Int((remaining / 60).rounded()))
            let note = NSMenuItem(
                title: String(
                    format: String(localized: "menu.pause_remaining", bundle: .localized),
                    minutes
                ),
                action: nil,
                keyEquivalent: ""
            )
            note.isEnabled = false
            menu.addItem(note)
        }

        // Un panel que se puede arrastrar necesita vuelta atrás: si acaba en
        // una esquina incómoda o en un monitor que ya no está, esto lo trae
        // de vuelta sin tener que buscarlo.
        let recenter = NSMenuItem(
            title: String(localized: "menu.recenter", bundle: .localized),
            action: #selector(recenterPanel),
            keyEquivalent: ""
        )
        recenter.target = self
        menu.addItem(recenter)

        let clear = NSMenuItem(
            title: String(localized: "menu.clear", bundle: .localized),
            action: #selector(clearHistory),
            keyEquivalent: ""
        )
        clear.target = self
        menu.addItem(clear)

        menu.addItem(.separator())

        let settings = NSMenuItem(
            title: String(localized: "menu.settings", bundle: .localized),
            action: #selector(openSettings),
            keyEquivalent: ","
        )
        settings.target = self
        menu.addItem(settings)

        let about = NSMenuItem(
            title: String(localized: "menu.about", bundle: .localized),
            action: #selector(showAbout),
            keyEquivalent: ""
        )
        about.target = self
        menu.addItem(about)

        let quit = NSMenuItem(
            title: String(localized: "menu.quit", bundle: .localized),
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        menu.addItem(quit)

        return menu
    }

    // MARK: - Acciones

    /// Desde el menú: no hay tecla mantenida, así que no se arma el gesto. Armarlo
    /// aquí creaba y abortaba una sesión del motor en cada apertura.
    @objc private func togglePanel() {
        panelController?.toggle(.menu)
    }

    /// Desde el atajo global: **aquí sí** hay tecla mantenida, y es el único sitio
    /// desde el que el gesto de dictado tiene sentido.
    ///
    /// Estuvieron unidos, y separarlos mal desactivó el gesto por completo: al
    /// pasar `.menu` en el único llamador, `shortcutPressed` dejó de ejecutarse en
    /// toda la app y la cuenta, su cancelación y la vigilancia del soltado se
    /// volvieron código muerto sin que nada fallara.
    private func togglePanelFromHotKey() {
        panelController?.toggle(.hotKey)
    }

    private static func pauseTitle(for duration: HistoryPause.Duration) -> String {
        switch duration {
        case .fifteenMinutes: String(localized: "menu.pause_15m", bundle: .localized)
        case .oneHour: String(localized: "menu.pause_1h", bundle: .localized)
        case .untilResumed: String(localized: "menu.pause_until_resumed", bundle: .localized)
        }
    }

    @objc private func pauseForDuration(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let duration = HistoryPause.Duration(rawValue: raw) else { return }
        model.settings.pauseCapture(duration)
        model.syncSettingsToServices()
    }

    @objc private func togglePause() {
        model.settings.isPaused.toggle()
        model.syncSettingsToServices()
    }

    @objc private func recenterPanel() {
        panelController?.resetPosition()
        panelController?.show(.menu)
    }

    @objc private func clearHistory() {
        let alert = NSAlert()
        alert.messageText = String(localized: "alert.clear.title", bundle: .localized)
        alert.informativeText = String(localized: "alert.clear.body", bundle: .localized)
        alert.alertStyle = .warning
        alert.addButton(withTitle: String(localized: "alert.clear.confirm", bundle: .localized))
        alert.addButton(withTitle: String(localized: "alert.cancel", bundle: .localized))

        if alert.runModal() == .alertFirstButtonReturn {
            model.deleteAllUnpinned()
        }
    }

    /// Panel «Acerca de» del sistema.
    ///
    /// Una app sin forma de ver su versión deja al usuario sin saber qué está
    /// ejecutando cuando algo falla, y al autor sin saber sobre qué le están
    /// informando. El panel estándar ya compone nombre, versión, build e icono
    /// a partir del Info.plist.
    @objc private func showAbout() {
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(
            options: [
                .applicationName: "Ámbar",
                .credits: NSAttributedString(
                    string: String(localized: "about.tagline", bundle: .localized),
                    attributes: [
                        .font: NSFont.systemFont(ofSize: 11),
                        .foregroundColor: NSColor.secondaryLabelColor,
                    ]
                ),
            ]
        )
    }

    @objc func openSettings() {
        if let window = settingsWindow {
            // Se monta una vista NUEVA al reabrir. La ventana se reutiliza
            // (`isReleasedWhenClosed = false`) y SwiftUI **no** vuelve a disparar
            // `.onAppear` ni `.task` sobre la misma jerarquía —medido con un arnés que
            // replica esta estructura—, así que el peso del historial, el estado de
            // Accesibilidad y la oferta del dictado se quedaban congelados en lo que
            // fueran la **primera** vez que se abrió Ajustes en toda la vida del proceso.
            //
            // Recrear la jerarquía de una ventana de ajustes no cuesta nada medible y es
            // lo único que garantiza el ciclo de vida completo.
            window.contentViewController = NSHostingController(rootView: SettingsView(model: model))
            settingsWindowDidAppear()
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }

        let hosting = NSHostingController(rootView: SettingsView(model: model))
        let window = NSWindow(contentViewController: hosting)
        window.title = String(localized: "settings.title", bundle: .localized)
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.center()
        window.delegate = self
        settingsWindow = window

        settingsWindowDidAppear()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    /// Lo que hay que refrescar cada vez que Ajustes se abre.
    ///
    /// Vive aquí y no en `.onAppear` porque el ciclo de vida de una vista SwiftUI dentro de
    /// una `NSWindow` reutilizada **no** lo garantiza: medido, ni `onAppear` ni `task` se
    /// vuelven a disparar al reabrir, y `onDisappear` no se dispara al cerrar.
    private func settingsWindowDidAppear() {
        model.refreshPermissionState()
        model.startMicrophonePermissionWatcher()
    }

    /// Y lo que hay que apagar al cerrarla.
    ///
    /// `.onDisappear` no se ejecuta al cerrar la ventana, así que el sondeo del permiso de
    /// micrófono —40 despertares por minuto— se quedaba vivo el resto de la vida del
    /// proceso. En un agente de barra de menús eso son semanas.
    /// La ventana de Ajustes, alcanzable desde un test.
    ///
    /// `windowWillClose` compara contra ella antes de apagar nada, así que sin esta puerta
    /// el apagado del sondeo era inalcanzable: una auditoría independiente borró la línea
    /// y los 471 tests siguieron en verde, sobre un fallo que el comentario de aquí arriba
    /// describe como ya ocurrido.
    func setSettingsWindowForTesting(_ window: NSWindow) {
        settingsWindow = window
    }

    /// El modelo del delegado, para poder afirmar lo que el delegado le hace.
    var modelForTesting: AppModel { model }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === settingsWindow else { return }
        model.stopMicrophonePermissionWatcher()
        model.stopPermissionWatcher()
    }

    // MARK: - Atajo

    private func registerHotKey() {
        if let hotKeyID { HotKeyCenter.shared.unregister(hotKeyID) }
        hotKeyID = HotKeyCenter.shared.register(
            model.settings.hotKey,
            action: { [weak self] in self?.togglePanelFromHotKey() },
            onRelease: { [weak self] in self?.model.dictation?.interactionOccurred(.released) }
        )
        // El resultado se mira. Antes se descartaba, y con la combinación tomada por otro
        // proceso la app quedaba sin su única forma de invocarse **sin decir nada**: el atajo
        // no respondía y no había ni un mensaje que lo explicara. Ver
        // `AppModel.isHotKeyUnavailable`.
        model.applyHotKeyRegistration(succeeded: hotKeyID != nil)
    }

    func reloadHotKey() {
        registerHotKey()
    }
}
