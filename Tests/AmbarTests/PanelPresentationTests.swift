import AppKit
import Foundation
import Testing
import VoiceKit

@testable import Ambar

/// El ciclo abrir → cerrar → abrir del panel.
///
/// Existe por una regresión que **yo** introduje y que llegó a la máquina del usuario: al
/// dejar de sacar la ventana del orden —para no pagar 758 ms de material de cristal en cada
/// apertura— `NSWindow.isVisible` siguió respondiendo `true` con la ventana invisible,
/// porque no mira el alfa. Y `toggle()` decidía con eso: la segunda pulsación del atajo
/// ocultaba, y todas las siguientes volvían a ocultar. **El gestor de portapapeles dejaba de
/// existir tras el primer cierre.**
///
/// `PanelController` no tenía **un solo test** —es la capa donde han vivido todas las
/// regresiones de diez rondas—, así que esto es también el primer clavo ahí.
@Suite("Presentación del panel", .serialized)
@MainActor
struct PanelPresentationTests {

    static func make() throws -> (PanelController, AppModel, URL) {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ambar-panel-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let defaults = UserDefaults(suiteName: "ambar.tests.panel.\(UUID().uuidString)")!
        let model = AppModel(settings: Settings(defaults: defaults))
        try model.startForTesting(directory: root)
        return (PanelController(model: model), model, root)
    }

    @Test("el menú abre, cierra y vuelve a abrir")
    func menuTogglesAlternately() throws {
        let (controller, _, root) = try Self.make()
        defer { controller.hide(); try? FileManager.default.removeItem(at: root) }

        #expect(controller.presentation == .hidden, "nace visible")

        controller.toggle(.menu)
        #expect(controller.presentation == .shown, "no abrió")

        controller.toggle(.menu)
        #expect(controller.presentation == .hidden, "no cerró")

        // La tercera es la que fallaba cuando `isVisible` preguntaba a `NSWindow`: el panel
        // se quedaba cerrado para siempre y solo «Recolocar» lo rescataba.
        controller.toggle(.menu)
        #expect(controller.presentation == .shown, "no volvió a abrir: la opción queda muerta")

        controller.toggle(.menu)
        #expect(controller.presentation == .hidden)
    }

    @Test("con el dictado apagado, el atajo sigue cerrando")
    func hotKeyStillTogglesWithoutDictation() throws {
        let (controller, _, root) = try Self.make()
        defer { controller.hide(); try? FileManager.default.removeItem(at: root) }

        // El dictado nace apagado, que es la configuración de la mayoría. Si la segunda
        // pulsación no cerrara, el atajo principal de la app dejaría de hacer nada
        // observable — y ninguna app de esta categoría se comporta así.
        #expect(!controller.canRearmGesture, "cree que hay gesto que rearmar sin dictado")

        controller.toggle(.hotKey)
        #expect(controller.presentation == .shown, "no abrió")
        controller.toggle(.hotKey)
        #expect(controller.presentation == .hidden, "el atajo dejó de cerrar sin dictado")
    }

    @Test("hiding with the keyboard takes the panel out of the window order")
    func hidingWithTheKeyboardOrdersOut() throws {
        let (controller, _, root) = try Self.make()
        defer { controller.hide(); try? FileManager.default.removeItem(at: root) }

        controller.show()
        let window = try #require(controller.window)
        try #require(window.isKeyWindow, "the panel did not take the keyboard on show")

        controller.hide()
        // The keyboard has to leave with the window, synchronously: a paste waits on it,
        // and an invisible window that keeps it eats keystrokes with a beep.
        #expect(!window.isKeyWindow, "an invisible panel kept the keyboard")
        #expect(!window.isVisible, "the panel stayed in the window order")
        #expect(controller.presentation == .hidden)
    }

    @Test("hiding without the keyboard leaves the panel invisible, untouchable and empty")
    func hidingWithoutTheKeyboardStaysInPlace() throws {
        let (controller, _, root) = try Self.make()
        defer { controller.hide(); try? FileManager.default.removeItem(at: root) }

        controller.show()
        let window = try #require(controller.window)
        let content = try #require(controller.hostingView)
        #expect(window.alphaValue == 1)
        #expect(!content.isHidden, "the content was not mounted on show")

        // Another window takes the keyboard first, as when the user clicks into another
        // app; the panel then hides without it.
        let other = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        other.isReleasedWhenClosed = false
        defer { other.close() }
        other.makeKeyAndOrderFront(nil)
        try #require(!window.isKeyWindow, "the test window did not take the keyboard")

        controller.hide()
        // Still in the window order, so it must show nothing and catch nothing: alpha 0,
        // no mouse, out of captures and window pickers, and no history on its surface.
        #expect(window.alphaValue == 0, "left visible")
        #expect(window.ignoresMouseEvents, "an invisible window that intercepts clicks")
        #expect(window.sharingType == .none, "still offered to captures and pickers")
        #expect(content.isHidden, "the hidden window keeps the history on its surface")
        #expect(controller.presentation == .hidden)
    }

    @Test("⌘C copies the selected entry and closes, instead of beeping")
    func commandCCopiesTheSelectedEntry() throws {
        let (controller, model, root) = try Self.make()
        defer { controller.hide(); try? FileManager.default.removeItem(at: root) }
        // Never the general pasteboard: a test must leave the user's clipboard alone.
        let pasteboard = NSPasteboard(
            name: NSPasteboard.Name("dev.rrios.ambar.tests.\(UUID().uuidString)")
        )
        controller.pasteboard = { pasteboard }

        let store = try #require(model.store)
        _ = try store.insert(AppModel.dictationItem(text: "copied from the history"))
        controller.show()
        try #require(model.selectedItem != nil, "nothing selected to copy")

        let commandC = try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: .command,
            timestamp: 0,
            windowNumber: controller.window?.windowNumber ?? 0,
            context: nil,
            characters: "c",
            charactersIgnoringModifiers: "c",
            isARepeat: false,
            keyCode: 8
        ))

        // Handled here means it never reaches the empty search field, which is where
        // AppKit found nothing to copy and beeped.
        #expect(controller.handle(commandC), "⌘C fell through to the search field")
        #expect(pasteboard.string(forType: .string) == "copied from the history")
        #expect(controller.presentation == .hidden)
    }

    @Test("abrir dos veces seguidas no cierra por el camino")
    func showingTwiceStaysShown() throws {
        let (controller, _, root) = try Self.make()
        defer { controller.hide(); try? FileManager.default.removeItem(at: root) }

        controller.show()
        controller.show(.menu)
        #expect(controller.presentation == .shown)
        #expect(controller.window?.alphaValue == 1)
    }
}

/// El cableado del panel que llevaba diez rondas sin una sola aserción.
///
/// Todas estas mutaciones sobrevivían a la suite completa, medidas por auditoría, y todas
/// reintroducen un hallazgo ya cerrado en alguna ronda anterior. Ahora que el controlador se
/// puede instanciar en un test —cosa que nadie había intentado— dejan de ser invisibles.
@Suite("Cableado del panel", .serialized)
@MainActor
struct PanelWiringTests {

    static func make() throws -> (PanelController, AppModel, URL) {
        try PanelPresentationTests.make()
    }

    @Test("el panel recibe eventos de movimiento del ratón")
    func panelAcceptsMouseMoved() throws {
        let (controller, _, root) = try Self.make()
        defer { controller.hide(); try? FileManager.default.removeItem(at: root) }
        controller.show()

        // Sin esto AppKit no genera `mouseMoved` para esta ventana y **la mitigación
        // principal de §8.3** —mover el ratón aborta la cuenta del gesto— no recibe nada.
        // Ponerlo a `false` no rompía ningún test.
        #expect(controller.window?.acceptsMouseMovedEvents == true)
    }

    @Test("el panel flota sobre pantalla completa y en todos los escritorios")
    func panelBehavesLikeSpotlight() throws {
        let (controller, _, root) = try Self.make()
        defer { controller.hide(); try? FileManager.default.removeItem(at: root) }
        controller.show()
        let window = try #require(controller.window)

        // Sin `canJoinAllSpaces` + `fullScreenAuxiliary`, el atajo no hace nada mientras se
        // trabaja a pantalla completa, que es cuando más falta hace.
        #expect(window.collectionBehavior.contains(.canJoinAllSpaces))
        #expect(window.collectionBehavior.contains(.fullScreenAuxiliary))
        // Y sin `canJoinAllApplications`, abrir el panel con OTRA app a pantalla completa
        // sacaba al usuario de ella al escritorio — reportado, y el comportamiento
        // contrario al de Spotlight. Los otros dos no lo cubren: uno es para los
        // escritorios y el otro para la pantalla completa de la propia app. Ver el
        // comentario de `makePanel`.
        #expect(
            window.collectionBehavior.contains(.canJoinAllApplications),
            "el panel volvería a expulsar al usuario de una app a pantalla completa"
        )
        // Y `transient` es lo que lo mantiene fuera de Mission Control ahora que la ventana
        // ya no sale del orden al ocultarse.
        #expect(window.collectionBehavior.contains(.transient))
        #expect(window.level == .floating)
    }

    @Test("ocultar el panel avisa al dictado")
    func hidingNotifiesDictation() throws {
        let (controller, model, root) = try Self.make()
        defer { controller.hide(); try? FileManager.default.removeItem(at: root) }

        var dismissals = 0
        model.onPanelDismissedForTesting = { dismissals += 1 }

        controller.show()
        controller.hide()

        // Sin este aviso, una sesión viva se quedaba clavada en «escuchando» con el panel
        // cerrado: el bloqueante de la ronda 2. Quitar la llamada no rompía nada.
        #expect(dismissals == 1, "cerrar el panel no avisó al dictado")
    }

    @Test("ocultar el panel con una sesión viva la cierra de verdad, no solo avisa al test")
    func hidingActuallyClosesALiveSession() throws {
        // `hidingNotifiesDictation` solo comprueba el gancho de test
        // (`onPanelDismissedForTesting`). La auditoría independiente encontró que la
        // llamada REAL —`model.dictation?.panelDismissed()`, la que de verdad transiciona
        // el estado— se podía borrar sin que ese test ni ningún otro lo notara: el
        // bloqueante era exactamente el que el comentario de `panelDismissed()` describe,
        // «⎋ y pegar del historial llaman a `hide()` con la sesión viva», y sin la
        // llamada real el micrófono se queda «escuchando» para siempre con el panel
        // cerrado.
        let (controller, model, root) = try Self.make()
        defer { controller.hide(); try? FileManager.default.removeItem(at: root) }
        model.engineProvider = {
            DictationControllerTests.FakeEngine(session: DictationControllerTests.FakeSession())
        }
        model.settings.isDictationEnabled = true
        controller.show()
        let dictation = try #require(model.dictation)
        dictation.simulateStatePublish(.listening)
        #expect(dictation.state.isMicrophoneOpen, "caso mal montado: \(dictation.state)")

        controller.hide()

        #expect(
            !dictation.state.isMicrophoneOpen,
            "el micrófono se quedó abierto con el panel oculto: \(dictation.state)"
        )
    }

    @Test("solo el atajo arma la cuenta del gesto")
    func onlyTheHotKeyArms() {
        // Armar al abrir desde el menú creaba y abortaba una sesión del motor —con su
        // reserva de idioma— en cada apertura, y nadie mantiene ninguna tecla al elegir una
        // opción de menú. Es el G2 de la ronda 1, y volvía a estar sin red.
        #expect(PanelController.armsGesture(invocation: .hotKey, holdGestureEnabled: true, stickyKeysEnabled: false))
        #expect(!PanelController.armsGesture(invocation: .menu, holdGestureEnabled: true, stickyKeysEnabled: false))
        // Y con el disparo por gesto desactivado —lo que hace Teclas Especiales por
        // defecto— no arma ni el atajo.
        #expect(!PanelController.armsGesture(invocation: .hotKey, holdGestureEnabled: false, stickyKeysEnabled: false))
        #expect(!PanelController.armsGesture(invocation: .menu, holdGestureEnabled: false, stickyKeysEnabled: false))
    }

    @Test("Teclas Especiales desarma el gesto EN VIVO, no solo en el ajuste guardado")
    func stickyKeysDisarmsLive() {
        // El auditor lo describió como el fallo que más le costaría relacionar al
        // usuario con su causa: activar Teclas Especiales con Ámbar ya corriendo —el
        // atajo del sistema es pulsar ⇧ cinco veces, fácil sin querer— no cambia el
        // interruptor guardado de Ajustes hasta el siguiente reinicio. Sin esta
        // comprobación en vivo, el interruptor seguiría diciendo «sí» mientras el
        // sistema enclava los modificadores, y con ellos enclavados `stillHeld()` no
        // puede distinguir «lo sigo pulsando» de «lo enclavé y solté»: CUALQUIER
        // apertura del panel superaría el umbral y abriría el micrófono.
        #expect(
            !PanelController.armsGesture(
                invocation: .hotKey,
                holdGestureEnabled: true,
                stickyKeysEnabled: true
            ),
            "armó con los modificadores enclavados por el sistema"
        )
        // Y con Teclas Especiales apagado, el ajuste guardado vuelve a mandar.
        #expect(
            PanelController.armsGesture(
                invocation: .hotKey,
                holdGestureEnabled: true,
                stickyKeysEnabled: false
            )
        )
    }
}

/// Qué teclas cancelan la cuenta del gesto.
///
/// §8.3 promete que «pulsar una flecha» la aborta, y no lo hacía: la cancelación solo se
/// emitía para las teclas que el panel **no** consume, y las flechas sí las consume. Quien
/// recorría la lista con el teclado sin soltar el atajo abría el micrófono a los 550 ms. La
/// prueba de que la promesa estaba muerta: `.navigated` está declarado en tres enums y no lo
/// producía nadie.
@Suite("Qué teclas cancelan la cuenta")
struct KeyCancellationTests {

    @Test("las flechas y el paginado navegan, y navegar cancela")
    func navigationCancels() {
        for keyCode: UInt16 in [125, 126, 121, 116] {
            #expect(
                PanelController.cancellation(forKeyCode: keyCode, handled: true) == .navigated,
                "la tecla \(keyCode) no canceló la cuenta"
            )
        }
    }

    @Test("teclear en el buscador cancela, como siempre")
    func typingCancels() {
        // Una tecla que el panel no consume acaba en el campo de búsqueda: quien escribe
        // está buscando algo, no queriendo dictar.
        #expect(PanelController.cancellation(forKeyCode: 0, handled: false) == .typed)
    }

    @Test("los atajos de la propia función de dictado no cancelan")
    func dictationShortcutsDoNotCancel() {
        // ⌘D y ⌘, los consume el panel y **no** son «estar buscando otra cosa». Cancelar con
        // ellos hacía que ⌘D se cancelara a sí mismo y su rama de descartar fuera
        // inalcanzable.
        #expect(PanelController.cancellation(forKeyCode: 2, handled: true) == nil)   // D
        #expect(PanelController.cancellation(forKeyCode: 43, handled: true) == nil)  // ,
    }
}

/// Que los monitores de AppKit **lleguen** a cancelar el gesto.
///
/// `NSEvent.addLocalMonitorForEvents` solo entrega eventos reales a través del run loop
/// de AppKit — nada que `swift test` pueda disparar sin ventana ni sesión gráfica. Antes
/// de esta ronda, la lógica de cancelación vivía DENTRO del closure que se pasa a esa
/// función, y eso la volvía estructuralmente invisible a cualquier test: se podía borrar
/// la llamada a `interactionOccurred` entera y la suite seguía en verde. Ahora esa lógica
/// vive en `handleMonitoredKeyDown`/`handleMonitoredPointerEvent`, que el monitor llama
/// con una sola línea, y este suite invoca directamente — es el mismo código, no una
/// copia; lo único que no se prueba es que AppKit sepa entregarle eventos, que no depende
/// de esta app.
@Suite("Los monitores de teclado y ratón cancelan el gesto", .serialized)
@MainActor
struct KeyAndPointerCancellationTests {

    static func synthKeyDown(keyCode: UInt16, command: Bool = false) -> NSEvent {
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: command ? [.command] : [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: keyCode
        )!
    }

    static func synthMouseMoved() -> NSEvent {
        NSEvent.mouseEvent(
            with: .mouseMoved,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 0,
            clickCount: 0,
            pressure: 0
        )!
    }

    /// Arma el gesto de verdad —con un motor de mentira, ver `DictationControllerTests`—
    /// para poder comprobar que una interacción lo cancela.
    static func armed() throws -> (PanelController, AppModel, DictationController, URL) {
        let (controller, model, root) = try PanelPresentationTests.make()
        model.engineProvider = {
            DictationControllerTests.FakeEngine(session: DictationControllerTests.FakeSession())
        }
        model.markDictationAvailableForTesting()
        model.settings.isDictationEnabled = true
        controller.show()
        let dictation = try #require(model.dictation)
        dictation.overrideHeldProviderForTesting { true }
        dictation.shortcutPressed(locale: Locale(identifier: "es-ES"), mode: .live)
        #expect(dictation.state.isActive, "no armó: caso mal montado")
        return (controller, model, dictation, root)
    }

    @Test("una tecla que se sale del panel cancela el gesto en curso")
    func typingCancelsTheArmedGesture() throws {
        let (controller, _, dictation, root) = try Self.armed()
        defer { controller.hide(); try? FileManager.default.removeItem(at: root) }

        // Una tecla imprimible sin ⌘: no la consume el panel, así que cuenta como
        // «escribiendo», y eso cancela.
        _ = controller.handleMonitoredKeyDown(Self.synthKeyDown(keyCode: 0))

        #expect(dictation.state == .idle, "la tecla no canceló el gesto: \(dictation.state)")
    }

    @Test("mover el ratón cancela el gesto en curso")
    func movingThePointerCancelsTheArmedGesture() throws {
        let (controller, _, dictation, root) = try Self.armed()
        defer { controller.hide(); try? FileManager.default.removeItem(at: root) }

        controller.handleMonitoredPointerEvent(Self.synthMouseMoved())

        #expect(dictation.state == .idle, "mover el ratón no canceló el gesto: \(dictation.state)")
    }

    @Test("el scroll se distingue del resto de causas de cancelación")
    func scrollHasItsOwnCause() {
        #expect(PanelController.pointerCancellation(for: .scrollWheel) == .scrolled)
        #expect(PanelController.pointerCancellation(for: .mouseMoved) == .pointerMoved)
        #expect(PanelController.pointerCancellation(for: .leftMouseDown) == .pointerMoved)
    }

    /// `KeyCancellationTests.dictationShortcutsDoNotCancel` ya prueba el predicado puro
    /// —⌘D no genera causa de cancelación—, así que aquí no hace falta repetirlo. Lo que
    /// esta ronda añade es el resto del hilo: que `handle(_ event:)`, donde vive la
    /// acción real de ⌘D, respeta el estado.
    @Test("con el micrófono abierto, ⏎ para el dictado de verdad, no solo en teoría")
    func enterActuallyStopsALiveSession() throws {
        // Este es el hallazgo de la auditoría: `DictationKeyboardTests.enterStopsDictation`
        // solo afirma sobre el predicado puro `DictationEntryPoints.enterAction`. Nadie
        // comprobaba que `handle(_ event:)` —donde vive el ⏎ real— lo respetara.
        //
        // Se publica `.listening` por el camino real (`simulateStatePublish`, no una
        // simulación de gesto) porque llegar ahí de verdad exige permiso de micrófono
        // concedido, algo que el proceso de test no tiene — y no hace falta un motor
        // real para comprobar que el evento de teclado dispara la llamada correcta.
        let (controller, model, root) = try PanelPresentationTests.make()
        defer { controller.hide(); try? FileManager.default.removeItem(at: root) }
        model.engineProvider = {
            DictationControllerTests.FakeEngine(session: DictationControllerTests.FakeSession())
        }
        model.settings.isDictationEnabled = true
        controller.show()
        let dictation = try #require(model.dictation)
        dictation.simulateStatePublish(.listening)
        #expect(dictation.state.isMicrophoneOpen, "caso mal montado: \(dictation.state)")

        _ = controller.handleMonitoredKeyDown(Self.synthKeyDown(keyCode: 36))

        #expect(!dictation.state.isMicrophoneOpen, "⏎ no cerró el micrófono: \(dictation.state)")
    }

    /// Cinco segundos, no dos: bajo la suite entera —incluidos los tests de motor real,
    /// que bloquean hilos del fondo cooperativo con procesos externos— dos segundos
    /// perdían contra la contención una de cada varias pasadas, con la afirmación real ya
    /// cumplida un instante después. No es tapar el síntoma: el margen sigue siendo un
    /// techo, y una condición que de verdad no se cumple tarda lo mismo en fallar salvo
    /// por esos cinco segundos de más.
    static func waitUntil(
        timeout: Duration = .seconds(5),
        _ condition: @MainActor () -> Bool
    ) async {
        let deadline = ContinuousClock.now.advanced(by: timeout)
        while ContinuousClock.now < deadline {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

/// Las dos teclas que cambian con el nuevo modelo de interacción.
@Suite("El teclado con el dictado en marcha")
@MainActor
struct DictationKeyboardTests {

    @Test("con el micrófono abierto, ⏎ para el dictado en vez de pegar del historial")
    func enterStopsDictation() {
        // ⏎ pega la entrada seleccionada del historial. Con una sesión viva eso sería lo
        // último que nadie quiere: mata el dictado en silencio y pega lo que no era.
        #expect(DictationEntryPoints.enterAction(for: .listening) == .stopDictation)
        #expect(DictationEntryPoints.enterAction(for: .idle) == .pasteSelection)
        // Y en `.finalizing` el micrófono ya está cerrado: ⏎ vuelve a ser pegar.
        #expect(DictationEntryPoints.enterAction(for: .finalizing) == .pasteSelection)
    }

    @Test("el rearmado solo aplica cuando hay un gesto que rearmar")
    func rearmOnlyWhenThereIsAGesture() throws {
        let (controller, _, root) = try PanelPresentationTests.make()
        defer { controller.hide(); try? FileManager.default.removeItem(at: root) }

        // Sin dictado activado no hay nada que rearmar, así que el atajo tiene que seguir
        // comportándose como el atajo de siempre. Esta es la condición que separa «no
        // parpadea porque va a grabar» de «el atajo no hace nada», y la segunda la notaría
        // justo quien no usa el dictado: la mayoría.
        #expect(!controller.canRearmGesture)

        controller.show(.hotKey)
        controller.toggle(.hotKey)
        #expect(controller.presentation == .hidden, "sin dictado, el atajo debe cerrar")

        // Del menú siempre alterna, haya dictado o no.
        controller.toggle(.menu)
        #expect(controller.presentation == .shown)
        controller.toggle(.menu)
        #expect(controller.presentation == .hidden)
    }
}

/// Que el pie y las teclas digan lo mismo durante la escucha.
///
/// El pie anunciaba «↵ Pegar» y «⌘D Dictar» mientras las dos teclas **paraban el dictado**.
/// No es cosmético: es la interfaz mintiendo sobre la única salida que el usuario tiene a
/// mano, justo en el modelo donde soltar ya no vale.
@Suite("El pie no puede mentir sobre las teclas")
struct FooterConsistencyTests {

    @Test("con el micrófono abierto, ⏎ para y ⌘⌫ descarta")
    func keysDuringDictation() {
        #expect(DictationEntryPoints.enterAction(for: .listening) == .stopDictation)
        #expect(DictationEntryPoints.deleteAction(for: .listening) == .discardDictation)
    }

    @Test("sin dictado, las teclas de siempre")
    func keysWithoutDictation() {
        #expect(DictationEntryPoints.enterAction(for: .idle) == .pasteSelection)
        #expect(DictationEntryPoints.deleteAction(for: .idle) == .deleteSelection)
        // En `.finalizing` el micrófono ya está cerrado: no hay nada que descartar y borrar
        // una entrada del historial vuelve a ser lo esperable.
        #expect(DictationEntryPoints.deleteAction(for: .finalizing) == .deleteSelection)
    }

    @Test("descartar tiene ruta de teclado, y no es la misma que parar")
    func discardIsReachableAndDistinct() {
        // Parar **entrega y pega**. Sin una tecla para descartar, quien disparara el gesto
        // sin querer y buscara la salida obvia acababa pegando en su documento — y con el
        // modelo nuevo soltar tampoco aborta.
        #expect(
            DictationEntryPoints.enterAction(for: .listening) == .stopDictation
                && DictationEntryPoints.deleteAction(for: .listening) == .discardDictation
        )
    }
}

/// La salida que funciona cuando el foco está fuera del panel.
///
/// ⏎ y ⌘D los sirve un monitor **local**: solo ve los eventos entregados a esta app. Con el
/// panel delante pero el foco en otra —lo que ocurre en cuanto el usuario clica fuera, y la
/// política impide cerrarlo con el micrófono abierto— dejaba de haber cualquier tecla que
/// parara el dictado. Quedaba el ratón. Con el techo en treinta minutos, quince veces más
/// tiempo expuesto que antes.
@Suite("El atajo global para el dictado")
@MainActor
struct GlobalStopTests {

    @Test("con una sesión viva, repetir el atajo la para")
    func hotKeyStopsALiveSession() {
        // La decisión, como valor: el atajo global es lo único que llega siempre, así que
        // con el micrófono abierto tiene que significar «para», no «rearma» ni «cierra».
        #expect(PanelController.hotKeyAction(isVisible: true, isMicrophoneOpen: true) == .stopDictation)
    }

    @Test("sin sesión viva, el atajo hace lo de siempre")
    func hotKeyKeepsItsUsualMeaning() {
        #expect(PanelController.hotKeyAction(isVisible: false, isMicrophoneOpen: false) == .showPanel)
        #expect(PanelController.hotKeyAction(isVisible: true, isMicrophoneOpen: false) == .toggleOrRearm)
    }
}

/// Que la ventana oculta salga de capturas y selectores.
///
/// La ventana ya no se saca del orden —cuesta 758 ms volver a entrar por el material de
/// cristal— y el sistema la sigue enumerando como «en pantalla»: medido, aparece en
/// `CGWindowListCopyWindowInfo` con sus bounds aunque el contenido esté oculto. Ocultar la
/// vista deja la superficie en blanco, pero eso es una consecuencia, no una garantía.
/// `sharingType` es el mecanismo documentado y estaba sin usar.
@Suite("La ventana oculta sale de las capturas", .serialized)
@MainActor
struct WindowSharingTests {

    @Test("al ocultar, la ventana deja de compartirse")
    func hidingStopsSharing() throws {
        let (controller, _, root) = try PanelPresentationTests.make()
        defer { controller.hide(); try? FileManager.default.removeItem(at: root) }

        controller.show()
        let window = try #require(controller.window)
        #expect(window.sharingType == .readOnly, "visible pero no compartible")

        controller.hide()
        // Out of the window order nothing can capture it; in place, sharing must be off.
        #expect(
            !window.isVisible || window.sharingType == .none,
            "la ventana oculta se sigue ofreciendo a capturas y selectores"
        )
    }
}


/// Lo que pasa **detrás** del permiso de accesibilidad al pegar un dictado.
///
/// El proceso de test nunca lo tiene, así que todo lo que hay tras esa puerta era
/// inalcanzable: la confesión de recorte se podía borrar entera con la suite en verde. Y es
/// lo único que le dice al usuario que puede faltarle texto de lo que acaba de pegar.
@Suite("La confesión de recorte sobrevive al cierre del panel", .serialized)
@MainActor
struct TruncationConfessionTests {

    /// Portapapeles propio, no el del sistema. Mismo motivo que
    /// `ArchivingTests.scratchPasteboard`: un test no puede dejar la máquina distinta de
    /// como la encontró, y `pasteDictated` escribe de verdad.
    static func scratchPasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("dev.rrios.ambar.tests.panel.\(UUID().uuidString)"))
    }

    static func plan(truncated: Bool) -> DictationDelivery {
        DictationDelivery(
            text: "esto es lo que se dictó",
            archives: true,
            concealed: false,
            confessesTruncation: truncated
        )
    }

    @Test("un dictado recortado avisa, y el aviso vive fuera del panel")
    func truncatedDictationConfesses() async throws {
        let (controller, model, root) = try PanelPresentationTests.make()
        defer { controller.hide(); try? FileManager.default.removeItem(at: root) }
        controller.canPaste = { true }
        controller.pasteboard = { Self.scratchPasteboard() }
        // SIEMPRE en un test que llega hasta aquí: sin esto, `pasteDictated` envía un
        // ⌘V sintético de verdad a lo que esté en primer plano en la máquina, y escribe
        // el texto de prueba en el portapapeles real del sistema. Se midió ocurriendo:
        // pegaba «esto es lo que se dictó» en lo que el usuario tuviera delante cada
        // vez que la suite corría.
        var syntheticPasteCalled = false
        controller.performSyntheticPaste = { syntheticPasteCalled = true }
        controller.show()

        controller.pasteDictated(Self.plan(truncated: true))

        // Fuera del panel: la banda muere con el panel y el panel se cierra SIEMPRE antes
        // de postear el ⌘V. Si el aviso viviera dentro, nadie lo leería nunca.
        #expect(controller.presentation == .hidden, "el panel no se cerró antes de pegar")
        #expect(
            model.lastError == String(localized: "dictation.state.truncated", bundle: .localized),
            "pegó un texto posiblemente incompleto sin decirlo: \(model.lastError ?? "nada")"
        )
        // `performSyntheticPaste` se dispara desde una `Task` suelta dentro de
        // `pasteDictated`, así que no ha corrido todavía en la línea siguiente — se
        // espera por condición, no por un `Task.sleep` a ciegas.
        await KeyAndPointerCancellationTests.waitUntil { syntheticPasteCalled }
        #expect(syntheticPasteCalled, "el camino real ni siquiera llegó a intentar pegar: caso mal montado")
    }

    @Test("un dictado entero no inventa un aviso")
    func completeDictationStaysQuiet() throws {
        let (controller, model, root) = try PanelPresentationTests.make()
        defer { controller.hide(); try? FileManager.default.removeItem(at: root) }
        controller.canPaste = { true }
        controller.pasteboard = { Self.scratchPasteboard() }
        controller.performSyntheticPaste = {}
        controller.show()

        controller.pasteDictated(Self.plan(truncated: false))

        #expect(model.lastError == nil, "avisó de un recorte que no hubo: \(model.lastError ?? "")")
    }

    @Test("sin permiso de accesibilidad el panel NO se cierra: el aviso vive dentro")
    func withoutAccessibilityThePanelStaysOpen() throws {
        let (controller, _, root) = try PanelPresentationTests.make()
        defer { controller.hide(); try? FileManager.default.removeItem(at: root) }
        controller.canPaste = { false }
        controller.pasteboard = { Self.scratchPasteboard() }
        // El seguro va SIEMPRE que un test toque `pasteDictated`, aunque la rama esperada
        // no llegue a pegar. Sin él, este caso solo estaba a salvo mientras el guard de
        // `canPaste` siguiera correcto: romperlo convertía este test en el que manda un ⌘V
        // real a lo que el usuario tenga delante. Un test no puede depender de que el
        // código que prueba esté bien para no dañar la máquina.
        var syntheticPasteCalled = false
        controller.performSyntheticPaste = { syntheticPasteCalled = true }
        controller.show()

        controller.pasteDictated(Self.plan(truncated: false))

        // Cerrarlo dejaba al usuario sin texto pegado y sin ninguna explicación: el aviso
        // que enciende `flagMissingPastePermission` se pinta DENTRO del panel.
        #expect(controller.presentation == .shown, "se cerró llevándose la única explicación")
        // Y el seguro deja de ser solo un seguro: sin permiso de accesibilidad, NO se pega.
        #expect(!syntheticPasteCalled, "intentó pegar sin permiso de accesibilidad")
    }
}

/// Un fallo de hace un rato no puede reaparecer al abrir el panel.
///
/// El banner de fallo del dictado **no tiene botón de cerrar**: se va cuando el estado deja
/// de estar en fallo. Sin el saneo al abrir, el usuario abre el historial media hora después
/// y se encuentra un «No se oyó nada» rojo de una sesión que ya ni recuerda.
@Suite("Abrir el panel limpia lo ya resuelto", .serialized)
@MainActor
struct SettledStateResetTests {

    @Test("un fallo viejo no reaparece en la siguiente apertura")
    func staleFailureDoesNotComeBack() throws {
        let (controller, model, root) = try PanelPresentationTests.make()
        defer { controller.hide(); try? FileManager.default.removeItem(at: root) }
        model.engineProvider = {
            DictationControllerTests.FakeEngine(session: DictationControllerTests.FakeSession())
        }
        model.settings.isDictationEnabled = true
        controller.show()
        let dictation = try #require(model.dictation)

        dictation.simulateStatePublish(.failed(.noSpeechDetected))
        controller.hide()
        #expect(dictation.state == .failed(.noSpeechDetected), "caso mal montado")

        controller.show()
        #expect(
            dictation.state == .idle,
            "el fallo de la sesión anterior sigue en pantalla: \(dictation.state)"
        )
    }

    @Test("una entrega de hace un rato tampoco")
    func staleDeliveryDoesNotComeBack() throws {
        let (controller, model, root) = try PanelPresentationTests.make()
        defer { controller.hide(); try? FileManager.default.removeItem(at: root) }
        model.engineProvider = {
            DictationControllerTests.FakeEngine(session: DictationControllerTests.FakeSession())
        }
        model.settings.isDictationEnabled = true
        controller.show()
        let dictation = try #require(model.dictation)

        dictation.simulateStatePublish(.delivered(Transcript(text: "hola", mode: .live)))
        controller.hide()
        controller.show()
        #expect(dictation.state == .idle, "reapareció una entrega vieja: \(dictation.state)")
    }
}

/// Who the synthetic ⌘V is aimed at.
///
/// `paste(item:)` stages the text, hides the panel, activates `previousApplication` and
/// only then posts ⌘V — and the system delivers that ⌘V to whatever is frontmost **at
/// that instant**. So the whole feature hangs on one assignment in `show()`, and there
/// was no test on it.
///
/// The failure it protects against is the one the user reported: pressing ⏎ on a history
/// entry left the text on the clipboard and pasted nothing, so ⌘V by hand was still
/// needed. If the panel is opened while Ámbar is already in front — re-invoked with it
/// open, or right after a dictation delivered — `frontmostApplication` is Ámbar itself,
/// the activation step becomes a no-op, and the ⌘V lands on the panel we just hid.
@Suite("A quién vuelve el foco", .serialized)
@MainActor
struct PasteTargetTests {

    @Test("abrir con Ámbar delante no se apunta a sí mismo")
    func showingDoesNotRecordOurselves() throws {
        let (controller, _, _) = try PanelPresentationTests.make()
        controller.frontmostApplication = { .current }

        controller.show()

        #expect(
            controller.previousApplication == nil,
            "recording ourselves aims the synthetic ⌘V at the panel we are about to hide"
        )
    }

    @Test("abrir con otra app delante sí la recuerda")
    func showingRecordsWhoeverWasInFront() throws {
        let other = try #require(
            NSWorkspace.shared.runningApplications.first {
                $0.processIdentifier != ProcessInfo.processInfo.processIdentifier
            },
            "there is always another process running; without one this test proves nothing"
        )
        let (controller, _, _) = try PanelPresentationTests.make()
        controller.frontmostApplication = { other }

        controller.show()

        #expect(controller.previousApplication?.processIdentifier == other.processIdentifier)
    }
}
