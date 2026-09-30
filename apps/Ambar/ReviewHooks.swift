#if DEBUG

import AppCore
import AppKit
import Darwin
import Security
import VoiceKit
import GlassUI
import SwiftUI

/// Puntos de entrada para revisar la app sin nadie delante.
///
/// **Todo este fichero se compila solo en DEBUG.** Un binario de producción no
/// debe traer modos ocultos activables por variable de entorno: amplían la
/// superficie de la app, permiten redirigir dónde se guarda el historial y
/// dejan al alcance de cualquiera con acceso al entorno un comportamiento que
/// el usuario no puede ver ni desactivar.
///
/// Para usar estas herramientas hay que compilar en debug:
///
///     ./Scripts/make-app.sh debug
///
enum ReviewHooks {
    static var isCapturing: Bool { environment("AMBAR_CAPTURE_TO") != nil }

    static func environment(_ key: String) -> String? {
        ProcessInfo.processInfo.environment[key]
    }

    static var suppressesPrompts: Bool { environment("AMBAR_SUPPRESS_PROMPTS") != nil }
    static var showsPanelOnLaunch: Bool { environment("AMBAR_SHOW_ON_LAUNCH") != nil }
    static var diagnoses: Bool { environment("AMBAR_DIAGNOSE") != nil }
    /// `AMBAR_PERMISSIONS=1` — imprime lo que el sistema le concede a ESTA app y sale.
    ///
    /// Cuando alguien dice «no me deja dar permiso al micrófono», la respuesta no puede ser
    /// una teoría sobre TCC: hay que preguntarle al sistema desde dentro de la app, que es
    /// el único sitio donde la pregunta significa algo.
    static var reportsPermissions: Bool { environment("AMBAR_PERMISSIONS") != nil }
    /// `AMBAR_REQUEST_MIC=1` — pide el permiso del micrófono, informa del resultado y sale.
    ///
    /// Existe porque «la app no aparece en Ajustes del Sistema → Micrófono» **no se arregla
    /// desde Ajustes del Sistema**: macOS solo enumera ahí las apps que han solicitado el
    /// permiso y no hay botón para añadir una a mano. La única forma de que Ámbar aparezca es
    /// que Ámbar lo pida, y esto lo hace sin pasar por la interfaz.
    ///
    /// **Hay que lanzarlo con `open`**, no ejecutando el binario: desde un terminal, TCC
    /// atribuye la solicitud al terminal y la app sigue sin registrarse — que es exactamente
    /// cómo se llegó a este estado.
    static var requestsMicrophone: Bool { environment("AMBAR_REQUEST_MIC") != nil }
    /// `AMBAR_TEST_PASTE=1` — ejerce el pegado automático de verdad y dice si funcionó.
    ///
    /// Escribe una marca en el portapapeles, activa TextEdit y postea el ⌘V sintético por el
    /// mismo camino que usa el panel. Existe porque no había forma de responder «¿el pegado
    /// automático funciona en esta máquina?» sin que una persona lo probara a mano: el panel
    /// es una ventana **no activadora**, así que un ⏎ sintético enviado desde fuera se lo
    /// queda la app de destino y no el panel, y la prueba de extremo a extremo no concluye
    /// nada. Esto se salta el panel y mide la mecánica.
    static var testsPaste: Bool { environment("AMBAR_TEST_PASTE") != nil }
    /// `AMBAR_TEST_PASTE=panel` — ejerce el camino **completo** del panel, paso a paso.
    ///
    /// La diferencia con el modo simple no es cosmética: ese postea el ⌘V a pelo y por tanto
    /// solo mide el último tramo. Este recorre lo que recorre `⏎`: leer las representaciones
    /// del almacén, escribir al portapapeles, ocultar el panel, devolver el foco y postear.
    /// Cuatro de esos cinco pasos podían fallar **devolviendo `false` en silencio**, que es
    /// exactamente lo que hay que poder ver.
    static var testsPasteThroughPanel: Bool { environment("AMBAR_TEST_PASTE") == "panel" }
    /// `AMBAR_MEASURE_SHOW=40` — abre y cierra el panel N veces y publica los tiempos.
    ///
    /// La latencia de aparición es la promesa central del producto, así que cuando alguien
    /// dice «va más lento» la respuesta no puede ser una opinión sobre el código. Mide el
    /// trabajo **síncrono** de `show()` en el hilo principal, que es lo que retrasa el
    /// primer frame; lo que ocurre después —los tics de la cuenta— se mide aparte.
    static var measuresShowLatency: Int? { environment("AMBAR_MEASURE_SHOW").flatMap(Int.init) }
    /// `AMBAR_DUMP_A11Y=1` — abre el panel, vuelca el árbol de accesibilidad real y sale.
    ///
    /// El único sitio desde donde se puede comprobar que los controles tienen nombre para
    /// VoiceOver: en `swift test` ese árbol está vacío, y por eso borrar
    /// `.accessibilityLabel` de los botones de la banda pasaba con 481 pruebas en verde.
    /// El valor elige el estado: `1` deja el panel en reposo, `listening` fuerza la banda
    /// de dictado, que es donde viven los botones de parar y descartar.
    static var dumpsAccessibility: String? { environment("AMBAR_DUMP_A11Y") }
    static var seedsDemoContent: Bool { environment("AMBAR_SEED_DEMO") != nil }
    /// `AMBAR_CAPTURE_ONBOARDING=welcome` + `AMBAR_CAPTURE_TO=…png` — rasteriza un paso de
    /// la presentación de primer uso y sale.
    ///
    /// La composición de esa ventana no se puede juzgar de otra forma sin nadie delante, y
    /// es la primera pantalla que ve cualquiera que instale la app.
    static var capturesOnboardingStep: OnboardingStep? {
        environment("AMBAR_CAPTURE_ONBOARDING").flatMap(OnboardingStep.init(rawValue:))
    }
    static var capturePath: String? { environment("AMBAR_CAPTURE_TO") }
    static var capturesInLightMode: Bool { environment("AMBAR_CAPTURE_LIGHT") != nil }
    static var captureIndex: Int? { environment("AMBAR_CAPTURE_INDEX").flatMap(Int.init) }

    /// Historial en otra carpeta, para no tocar los datos reales al probar.
    static var dataDirectoryOverride: String? { environment("AMBAR_DATA_DIR") }

    /// `AMBAR_REPORT_TO=/ruta.txt` — además de imprimirlo, deja el informe en un fichero.
    ///
    /// Hace falta porque la medición que **de verdad** describe a la app es la de un arranque
    /// hecho por el sistema (`open`), y ahí el stdout no vuelve al terminal: LaunchServices no
    /// hereda la salida de quien invoca. Sin esto, lo único medible desde una consola es el
    /// arranque a mano, que es justo el que atribuye los permisos al terminal y engaña.
    static var reportPath: String? { environment("AMBAR_REPORT_TO") }

    /// Acumula el informe de un modo de revisión.
    ///
    /// Por referencia y no un `var` local: los modos que **inyectan** un closure en la app
    /// —para ver si una secuencia llega a ejecutarse— necesitan escribir desde dentro de él, y
    /// un array capturado no vale. Con `open`, además, el `print` no vuelve a ninguna consola:
    /// el fichero es la única salida legible.
    @MainActor
    final class Recolector {
        private var lines: [String] = []

        func add(_ line: String) {
            print(line)
            lines.append(line)
        }

        func write(to path: String?) {
            guard let path else { return }
            try? lines.joined(separator: "\n").appending("\n")
                .write(toFile: path, atomically: true, encoding: .utf8)
        }
    }

    /// Nombre del proceso que lanzó esta app.
    ///
    /// Distingue «la abrió el sistema» de «la lanzó un terminal», y eso decide si lo que se
    /// lee del TCC describe a Ámbar o al proceso que la arrancó.
    private static func parentProcessName() -> String {
        var buffer = [UInt8](repeating: 0, count: 4096)
        let written = proc_pidpath(getppid(), &buffer, UInt32(buffer.count))
        guard written > 0 else { return "desconocido" }
        // `proc_pidpath` devuelve cuántos bytes escribió, así que se decodifica ese tramo y
        // no hace falta buscar el terminador — ni las API de C que lo hacen, que están
        // marcadas obsoletas y el gate de avisos rechaza.
        let path = String(decoding: buffer.prefix(Int(written)), as: UTF8.self)
        return (path as NSString).lastPathComponent
    }

    /// `AMBAR_FORCE_A11Y=reduce-transparency,increase-contrast,…`
    @MainActor
    static func applyAccessibilityOverrides() {
        guard let raw = environment("AMBAR_FORCE_A11Y") else { return }
        let flags = Set(raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })

        AccessibilityPreferences.shared.overrideForReview(
            reduceTransparency: flags.contains("reduce-transparency") ? true : nil,
            increaseContrast: flags.contains("increase-contrast") ? true : nil,
            reduceMotion: flags.contains("reduce-motion") ? true : nil,
            differentiateWithoutColor: flags.contains("no-color") ? true : nil
        )
    }

    /// Ejecuta los modos de revisión que correspondan y devuelve `true` si la
    /// app va a terminar por su cuenta.
    @MainActor
    static func run(
        model: AppModel,
        controller: PanelController,
        onboarding: OnboardingController? = nil
    ) -> Bool {
        if showsPanelOnLaunch { controller.show() }

        if reportsPermissions {
            Task { @MainActor in
                var lines: [String] = []
                // Acumula y escribe: la salida por pantalla sigue siendo la de siempre.
                func report(_ line: String) {
                    print(line)
                    lines.append(line)
                }
                report("PERMISOS micrófono=\(MicrophoneAuthorization.current.rawValue)")
                report("PERMISOS hay entrada de audio=\(MicrophoneAuthorization.hasInputDevice)")
                report("PERMISOS accesibilidad=\(Paster.canPaste)")
                // Y el estado del modelo de voz, que es la otra mitad de «no funciona».
                let catalog = SpeechModelCatalog(mode: model.settings.dictationMode)
                let locale = Locale.current
                let resolved = await catalog.supportedLocale(equivalentTo: locale)
                report("PERMISOS idioma=\(locale.identifier) resuelto=\(resolved?.identifier ?? "ninguno")")
                _ = try? await catalog.reserve(locale: locale)
                let availability = await catalog.availability(forLocale: locale)
                report("PERMISOS modelo=\(availability.rawValue)")
                report("PERMISOS dictado activado=\(model.settings.isDictationEnabled) gesto=\(model.settings.isHoldGestureEnabled) modo=\(model.settings.dictationMode.rawValue)")
                // Las ranuras de idioma, que es lo que se agotaba en silencio. `reservado`
                // cuenta lo que retiene ESTE proceso: son por proceso, así que medirlas
                // desde un binario suelto siempre da cero y no dice nada de la app viva.
                // Aquí sí, porque quien informa es la app.
                let (maximum, reserved) = await catalog.reservation()
                let ids = reserved.map(\.identifier).sorted().joined(separator: ",")
                report("PERMISOS ranuras de idioma=\(reserved.count)/\(maximum) [\(ids)]")
                report("PERMISOS arranque al iniciar sesión=\(LaunchAtLogin.state) preferencia=\(model.settings.launchAtLogin)")
                // Que el menú de edición esté puesto de verdad en la app viva, y no solo en
                // el test que construye la tabla: es lo único que hace que ⌘V pegue en el
                // campo de búsqueda, y estuvo ausente hasta ahora.
                let pastes = NSApp.mainMenu?.items.first?.submenu?.items
                    .contains { $0.keyEquivalent == "v" } ?? false
                report("PERMISOS menú de edición=\(NSApp.mainMenu != nil) pegar=\(pastes)")
                // **A quién atribuye el sistema estos permisos.**
                //
                // Ejecutar el binario a mano —`./.build/Ambar.app/Contents/MacOS/Ambar`— hace
                // que TCC trate el proceso como hijo del terminal, y entonces lo que se lee
                // aquí es lo que tenga concedido **el terminal**, no Ámbar. Es una trampa
                // seria: una medición así dio «micrófono=granted» mientras el usuario, con la
                // app abierta normalmente, no tenía el permiso ni aparecía en la lista de
                // Ajustes del Sistema. La conclusión fue «todo correcto» y era falsa.
                //
                // Con el padre a la vista, el arnés no puede volver a engañar al siguiente.
                let parent = parentProcessName()
                report("PERMISOS pid=\(getpid()) padre=\(getppid()) (\(parent))")
                // `launchd` como padre significa que la abrió el sistema —doble clic, `open`,
                // arranque al inicio de sesión—, que es el único caso en el que lo de arriba
                // describe a Ámbar. Cualquier otro padre es un proceso que la lanzó, y
                // entonces TCC puede atribuirle a **él** los permisos.
                if parent != "launchd" {
                    report("PERMISOS AVISO la ha lanzado «\(parent)», no el sistema: los")
                    report("PERMISOS AVISO permisos de micrófono y pantalla pueden atribuirse a")
                    report("PERMISOS AVISO ese proceso y no a Ámbar, así que lo de arriba puede")
                    report("PERMISOS AVISO no ser lo que ve el usuario. Mide con: open .build/Ambar.app")
                }
                await catalog.release(locale: locale)
                if let path = reportPath {
                    try? lines.joined(separator: "\n").appending("\n")
                        .write(toFile: path, atomically: true, encoding: .utf8)
                }
                NSApp.terminate(nil)
            }
            return true
        }

        if testsPaste {
            Task { @MainActor in
                var lines: [String] = []
                func report(_ line: String) {
                    print(line)
                    lines.append(line)
                }
                let marca = "ambar-pegado-\(Int(Date().timeIntervalSince1970))"
                report("PEGADO permiso=\(Paster.canPaste)")
                report("PEGADO marca=\(marca)")
                Paster.writePlainText(marca)

                // Un destino controlado. Sin esto, el ⌘V va a lo que hubiera delante, que en
                // una prueba automatizada es cualquier cosa —incluida esta misma app.
                let editor = URL(fileURLWithPath: "/System/Applications/TextEdit.app")
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                _ = try? await NSWorkspace.shared.openApplication(at: editor, configuration: configuration)
                try? await Task.sleep(for: .seconds(2))
                let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "ninguna"
                report("PEGADO destino=\(front)")

                if testsPasteThroughPanel {
                    // El camino real, con el historial de verdad: la marca que se acaba de
                    // copiar tiene que estar arriba, así que se pega **desde el almacén**.
                    try? await Task.sleep(for: .seconds(1))
                    model.refresh()
                    report("PANEL entradas=\(model.items.count)")
                    report("PANEL canAutoPaste=\(model.canAutoPaste)")
                    guard let item = model.items.first else {
                        report("PANEL ✗ el historial está vacío: no hay nada que pegar")
                        if let path = reportPath {
                            try? lines.joined(separator: "\n").appending("\n")
                                .write(toFile: path, atomically: true, encoding: .utf8)
                        }
                        NSApp.terminate(nil)
                        return
                    }
                    report("PANEL entrada=\(item.preview.prefix(40))")
                    // `stage` por separado, para saber si el fallo está en el almacén: es el
                    // paso que devolvía `false` sin decir nada.
                    let staged = model.stage(item: item, plainText: false)
                    report("PANEL stage=\(staged) error=\(model.lastError ?? "ninguno")")

                    // La secuencia de pegado es una propiedad **inyectable** —existe para que
                    // los tests no peguen en el escritorio real—, así que se envuelve para ver
                    // si de verdad llega a ejecutarse. Sin esto no se distingue «se ejecutó y
                    // el sistema descartó el evento» de «nunca se llamó porque un `guard`
                    // devolvió false en silencio», que son dos defectos opuestos.
                    let diario = Recolector()
                    let original = controller.performSyntheticPaste
                    controller.performSyntheticPaste = {
                        diario.add("PANEL >> secuencia de pegado EJECUTADA")
                        await original()
                        diario.add("PANEL >> secuencia de pegado TERMINADA")
                    }

                    func frontal() -> String {
                        NSWorkspace.shared.frontmostApplication?.localizedName ?? "ninguna"
                    }
                    report("PANEL frontal antes de abrir=\(frontal())")
                    controller.show(.menu)
                    try? await Task.sleep(for: .milliseconds(400))
                    report("PANEL frontal con el panel abierto=\(frontal())")
                    report("PANEL app anterior=\(controller.previousApplication?.localizedName ?? "ninguna")")
                    report("PANEL panel es clave=\(controller.window?.isKeyWindow ?? false)")
                    controller.paste(item: item, plainText: false)
                    try? await Task.sleep(for: .seconds(3))
                    report("PANEL frontal tras pegar=\(frontal())")
                    report("PANEL tras pegar error=\(model.lastError ?? "ninguno")")
                    // ¿Dónde acabó el ⌘V? Si el panel oculto sigue siendo la ventana clave, se
                    // lo come él y el texto aparece en su campo de búsqueda. Es la única
                    // hipótesis que explica «todo correcto y no pega».
                    report("PANEL búsqueda=[\(model.searchText)]")
                    let pegable = NSPasteboard.general.string(forType: .string) ?? "nada"
                    report("PANEL portapapeles=[\(pegable.prefix(40))]")
                    report("PANEL panel sigue siendo clave=\(controller.window?.isKeyWindow ?? false)")
                    diario.write(to: reportPath.map { $0 + ".secuencia" })
                    if let path = reportPath {
                        try? lines.joined(separator: "\n").appending("\n")
                            .write(toFile: path, atomically: true, encoding: .utf8)
                    }
                    NSApp.terminate(nil)
                    return
                }

                let ok = Paster.pasteToFrontmostApp()
                report("PEGADO enviado=\(ok)")
                if let path = reportPath {
                    try? lines.joined(separator: "\n").appending("\n")
                        .write(toFile: path, atomically: true, encoding: .utf8)
                }
                try? await Task.sleep(for: .seconds(1))
                NSApp.terminate(nil)
            }
            return true
        }

        if requestsMicrophone {
            Task { @MainActor in
                var lines: [String] = []
                func report(_ line: String) {
                    print(line)
                    lines.append(line)
                }
                report("MICRÓFONO antes=\(MicrophoneAuthorization.current.rawValue)")
                report("MICRÓFONO lanzado por=\(parentProcessName())")
                let result = await MicrophoneAuthorization.request()
                report("MICRÓFONO después=\(result.rawValue)")
                if parentProcessName() != "launchd" {
                    report("MICRÓFONO AVISO no lo ha lanzado el sistema: la solicitud puede")
                    report("MICRÓFONO AVISO haberse atribuido a ese proceso. Usa: open -n .build/Ambar.app")
                }
                if let path = reportPath {
                    try? lines.joined(separator: "\n").appending("\n")
                        .write(toFile: path, atomically: true, encoding: .utf8)
                }
                NSApp.terminate(nil)
            }
            return true
        }

        // `AMBAR_CAPTURE_ONBOARDING=<paso>` — rasteriza un paso de la presentación.
        if let step = capturesOnboardingStep, let path = capturePath {
            // Las mismas condiciones fijas que el volcado de accesibilidad, y por el mismo
            // motivo: una captura que cambia según lo que esa máquina tenga concedido no
            // sirve para comparar dos versiones del diseño.
            AppModel.reviewPasteCapability = false
            model.refreshPermissionState()
            let relocation = AppRelocation.Decision.offerMove(
                from: URL(fileURLWithPath: "/Users/x/Downloads/Ambar.app"),
                to: URL(fileURLWithPath: "/Applications/Ambar.app")
            )
            let coordinator = OnboardingCoordinator(
                conditions: OnboardingConditions(relocation: relocation, canAutoPaste: false),
                onFinish: {}
            )
            while coordinator.current != step, !coordinator.isLast { coordinator.advance() }

            let done = SelfCapture.captureOnboarding(
                model: model,
                step: step,
                relocation: relocation,
                coordinator: coordinator,
                to: path,
                colorScheme: capturesInLightMode ? ColorScheme.light : ColorScheme.dark
            )
            print(done ? "CAPTURA \(path)" : "CAPTURA falló")
            NSApp.terminate(nil)
            return true
        }

        // `AMBAR_DUMP_A11Y=settings` — la ventana de Ajustes.
        //
        // La tercera superficie de la app y la única que no medía nadie: aquí viven los dos
        // botones que conceden permisos, o sea todo lo que hay que
        // poder alcanzar cuando algo no funciona. Un control sin nombre en esta ventana deja a
        // quien usa VoiceOver sin forma de arreglar nada.
        if dumpsAccessibility == "settings" {
            Task { @MainActor in
                // Fijadas, como en los otros volcados: sin esto el gate mediría una ventana
                // distinta según lo que esa máquina tenga concedido.
                AppModel.reviewPasteCapability = false
                model.refreshPermissionState()
                model.onOpenSettings?()
                NSApp.activate(ignoringOtherApps: true)
                try? await Task.sleep(for: .milliseconds(900))

                // Se busca por título entre las ventanas vivas en lugar de pedírsela al
                // delegado: el arnés no debería obligar a abrir en canal una ventana privada
                // solo para poder mirarla.
                let title = String(localized: "settings.title", bundle: .localized)
                guard let window = NSApp.windows.first(where: { $0.title == title }) else {
                    print("A11Y ERROR la ventana de Ajustes no llegó a abrirse")
                    NSApp.terminate(nil)
                    return
                }
                AccessibilityDump.dump(panel: window)
                NSApp.terminate(nil)
            }
            return true
        }

        // `AMBAR_DUMP_A11Y=onboarding` — la presentación de primer uso.
        //
        // Va antes de la rama general porque necesita otra ventana y otro estado: aquí no
        // hay panel ni dictado, y las condiciones se **fijan** en lugar de leerse de la
        // máquina. Sin fijarlas, en un Mac que ya tuviera el permiso concedido el plan no
        // incluiría el paso de Accesibilidad y el gate acusaría de «sin nombre» a dos
        // botones que simplemente no estaban en pantalla.
        if dumpsAccessibility == "onboarding" {
            Task { @MainActor in
                guard let onboarding else {
                    print("A11Y ERROR el presentador no se montó: no hay ventana que volcar.")
                    NSApp.terminate(nil)
                    return
                }
                // El plan y la vista se fijan a la vez. El plan decide si el paso existe;
                // el override decide qué pinta ese paso, porque la vista lee el permiso en
                // vivo y no las condiciones. Fijar solo uno de los dos deja el gate midiendo
                // pantallas distintas según la máquina.
                AppModel.reviewPasteCapability = false
                model.refreshPermissionState()
                onboarding.present(
                    conditions: OnboardingConditions(
                        relocation: .offerMove(
                            from: URL(fileURLWithPath: "/Users/x/Downloads/Ambar.app"),
                            to: URL(fileURLWithPath: "/Applications/Ambar.app")
                        ),
                        canAutoPaste: false
                    )
                )
                // La app, al frente: `AXUIElementCopyAttributeValue(app, kAXWindows…)` no
                // devuelve las ventanas de una app que no está activa, y el volcado saldría
                // sin un solo control. Es la misma cicatriz que la rama del panel.
                NSApp.activate(ignoringOtherApps: true)

                guard let coordinator = onboarding.coordinatorForTesting,
                      let window = onboarding.windowForReview
                else {
                    print("A11Y ERROR la ventana de la presentación no llegó a crearse")
                    NSApp.terminate(nil)
                    return
                }

                // Se vuelcan los tres pasos con controles propios, y no solo el primero: el
                // botón de continuar existe en todos, pero «Mover a Aplicaciones» y
                // «Conceder el permiso» solo existen en su paso, que es exactamente donde
                // una etiqueta perdida no la vería nadie.
                // `extras` incluido: es el paso donde vive el interruptor del dictado, la
                // función que más veces se ha dado por «no disponible» sin poder decir por
                // qué. Que el control exista, tenga nombre y llegue al árbol es justo lo que
                // no se podía afirmar sin esto.
                for step in [OnboardingStep.welcome, .location, .accessibility, .extras] {
                    while coordinator.current != step, !coordinator.isLast {
                        coordinator.advance()
                    }
                    // El árbol se publica tras un turno de disposición: preguntarlo en el
                    // mismo ciclo en que cambia el paso devuelve la jerarquía anterior.
                    try? await Task.sleep(for: .milliseconds(600))
                    print("A11Y PASO \(step.rawValue)")
                    AccessibilityDump.dump(panel: window)
                }
                NSApp.terminate(nil)
            }
            return true
        }

        if let mode = dumpsAccessibility {
            Task { @MainActor in
                // El dictado, activado a propósito ANTES de abrir el panel, que es donde
                // `show()` llama a `syncDictation` y monta el controlador.
                //
                // Sin esta línea el gate no podía medir el dictado en NINGUNA máquina, y no
                // lo decía. `Settings` lee `dictation.enabled` de la suite que crea
                // `AMBAR_DATA_DIR` —una por ejecución, siempre virgen—, así que
                // `isDictationEnabled` nacía en `false`; `syncDictation` dejaba
                // `model.dictation` en `nil`; y ni el botón de micrófono —que `ContentView`
                // condiciona a `if let dictation`— ni la banda llegaban al árbol. El volcado
                // traía el panel entero MENOS los tres controles que este arnés existe para
                // vigilar, y el guion los declaraba «sin nombre para VoiceOver»: exactamente
                // el veredicto que daría si alguien hubiera borrado sus etiquetas. Cuatro
                // carreras seguidas de CI en rojo señalando un defecto que no existía.
                //
                // Escribirlo aquí no toca los ajustes de nadie: con `AMBAR_DATA_DIR` puesto
                // —y el guion lo pone— `Settings` trabaja contra una suite de revisión
                // efímera, no contra `.standard`.
                model.settings.isDictationEnabled = true
                controller.show()
                // La app, al frente. `AXUIElementCopyAttributeValue(app, kAXWindows…)` no
                // devolvió el panel en una sesión donde Ámbar no estaba activa —solo las
                // barras de menú—, así que el volcado salía sin un solo control y el gate
                // acusaba de «sin nombre» a controles que sí lo tienen. Medido: el mismo
                // guion, verde y rojo, con el único cambio de quién tenía el foco.
                NSApp.activate(ignoringOtherApps: true)
                // Con la banda en pantalla: sus botones —parar, descartar, cerrar— son los
                // que perdieron su nombre sin que nada se enterase, y en reposo no existen.
                //
                // Y si el controlador no está, se DICE. El `model.dictation?.…` que había
                // aquí era el punto ciego: con `nil` no publicaba el estado, no fallaba, y
                // dejaba seguir al volcado como si la banda estuviera en pantalla. Es el
                // mismo modo de fallo que la cabecera de `AccessibilityDump` dice venir a
                // evitar —un instrumento que da el mismo veredicto ante un defecto y ante su
                // propia ceguera— cometido un nivel más adentro.
                //
                // La comprobación cubre los DOS estados, no solo el de escucha: el botón de
                // micrófono que se mide en reposo cuelga del mismo `if let dictation`, así
                // que sin controlador también él falta, y el guion diría de «Dictar» lo
                // mismo que decía de «Detener».
                guard let dictation = model.dictation else {
                    print("A11Y ERROR el dictado no se montó: sin controlador no hay banda,")
                    print("A11Y ERROR y sin banda no hay «Dictar», «Detener» ni «Descartar» que medir.")
                    print("A11Y ERROR este volcado no puede afirmar nada sobre el dictado.")
                    NSApp.terminate(nil)
                    return
                }
                if mode == "listening" {
                    dictation.simulateStatePublish(.listening)
                }
                // El árbol se publica tras un turno de disposición: preguntarlo en el mismo
                // ciclo en que se abre devuelve la jerarquía a medio construir.
                try? await Task.sleep(for: .milliseconds(600))
                if let panel = controller.panelWindowForReview {
                    AccessibilityDump.dump(panel: panel)
                } else {
                    print("A11Y ERROR el panel no llegó a crearse")
                }
                NSApp.terminate(nil)
            }
            return true
        }

        if let rounds = measuresShowLatency {
            Task { @MainActor in
                // Una apertura de calentamiento: la primera crea el panel y carga fuentes,
                // y mezclarla con el resto daría una mediana que no representa nada.
                controller.show()
                controller.hide()
                try? await Task.sleep(for: .milliseconds(300))

                var samples: [Double] = []
                for _ in 0..<rounds {
                    let started = ContinuousClock.now
                    controller.show()
                    let elapsed = ContinuousClock.now - started
                    samples.append(
                        Double(elapsed.components.seconds) * 1000
                            + Double(elapsed.components.attoseconds) / 1e15
                    )
                    controller.hide()
                    try? await Task.sleep(for: .milliseconds(40))
                }
                // Comprobación obligatoria del truco de la alpha: si el panel se queda de
                // ventana clave estando invisible, las teclas del usuario van a una ventana
                // que no ve. Eso sería mucho peor que la lentitud que arregla.
                controller.hide()
                try? await Task.sleep(for: .milliseconds(200))
                print("TRAS OCULTAR: isKeyWindow=\(controller.window?.isKeyWindow ?? false) isVisible=\(controller.window?.isVisible ?? false) appKeyWindow=\(NSApp.keyWindow != nil)")

                let sorted = samples.sorted()
                let median = sorted[sorted.count / 2]
                print(String(
                    format: "MEDIDA show(): n=%d  mín=%.2f ms  mediana=%.2f ms  p90=%.2f ms  máx=%.2f ms",
                    samples.count,
                    sorted.first ?? 0,
                    median,
                    sorted[Int(Double(sorted.count) * 0.9)],
                    sorted.last ?? 0
                ))
                NSApp.terminate(nil)
            }
            return true
        }

        if diagnoses {
            controller.show()
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(400))
                if let window = controller.window {
                    print(SelfCapture.diagnose(window: window))
                }
                NSApp.terminate(nil)
            }
            return true
        }

        guard let path = capturePath else { return false }

        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            if seedsDemoContent {
                model.seedDemoContent()
                // Se espera al reconocimiento real en lugar de a un plazo fijo:
                // si no, la captura retrata el estado «reconociendo…».
                for _ in 0..<60 where model.hasPendingRecognition {
                    try? await Task.sleep(for: .milliseconds(200))
                }
            }
            model.refresh()
            if let index = captureIndex { model.selectedIndex = index }

            _ = SelfCapture.captureInterface(
                model: model,
                controller: controller,
                to: path,
                colorScheme: capturesInLightMode ? ColorScheme.light : ColorScheme.dark
            )
            NSApp.terminate(nil)
        }
        return true
    }
}

#endif
