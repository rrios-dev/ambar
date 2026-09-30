import AppKit
import Foundation
import Testing
import VoiceKit

@testable import Ambar

/// El sondeo que vigila si el usuario concede el micrófono desde Ajustes del Sistema.
///
/// Existe porque conceder el permiso **fuera de la app no emite ningún evento**: sin
/// sondear, Ajustes de Ámbar se queda diciendo «falta el permiso» indefinidamente después
/// de que el usuario lo haya dado.
///
/// Y no tenía ni un test. Una auditoría independiente borró sus tres decisiones —el guard
/// de entrada, la holgura del temporizador y el apagado al cerrar la ventana— **una por
/// una, y las tres sobrevivieron** con los 471 tests en verde. La causa era estructural:
/// `MicrophoneAuthorization.current` lee el estado real de TCC y no se puede inyectar, así
/// que ninguna rama era alcanzable desde `swift test`. La costura `microphonePermission`
/// existe para eso.
///
/// Lo que está en juego no es cosmético: el comentario de `AppDelegate.windowWillClose`
/// describe el tercer fallo como **ya ocurrido** — «el sondeo se quedaba vivo el resto de
/// la vida del proceso… en un agente de barra de menús eso son semanas», a 40 despertares
/// por minuto.
@Suite("El sondeo del permiso de micrófono se enciende y se apaga cuando toca", .serialized)
@MainActor
struct MicrophoneWatcherTests {

    static func model(permission: MicrophonePermission) throws -> AppModel {
        let defaults = try #require(
            UserDefaults(suiteName: "dev.rrios.ambar.tests.mic.\(UUID().uuidString)"),
            "no se pudo crear un dominio de preferencias aislado"
        )
        let model = AppModel(settings: Settings(defaults: defaults))
        model.microphonePermission = { permission }
        return model
    }

    @Test("sin permiso, el sondeo arranca")
    func startsWhenPermissionIsMissing() throws {
        let model = try Self.model(permission: .denied)
        model.startMicrophonePermissionWatcher()
        defer { model.stopMicrophonePermissionWatcher() }

        // La mitad que impide el falso positivo del test siguiente: si el sondeo no
        // arrancara nunca, «no arranca con el permiso puesto» se cumpliría solo.
        #expect(
            model.isWatchingMicrophonePermissionForTesting,
            "sin permiso no arrancó a vigilar: Ajustes se quedaría diciendo que falta"
        )
    }

    @Test("con el permiso ya concedido, no se sondea nada")
    func doesNotStartWhenAlreadyGranted() throws {
        let model = try Self.model(permission: .granted)
        model.startMicrophonePermissionWatcher()
        defer { model.stopMicrophonePermissionWatcher() }

        #expect(
            !model.isWatchingMicrophonePermissionForTesting,
            "sondea 40 veces por minuto una respuesta que ya tiene"
        )
    }

    @Test("el sondeo lleva holgura, para no despertar el procesador en el instante exacto")
    func watcherHasTolerance() throws {
        let model = try Self.model(permission: .notDetermined)
        model.startMicrophonePermissionWatcher()
        defer { model.stopMicrophonePermissionWatcher() }

        #expect(
            model.microphoneWatcherToleranceForTesting == 0.15,
            "holgura inesperada: \(String(describing: model.microphoneWatcherToleranceForTesting))"
        )
    }

    @Test("pararlo lo para de verdad")
    func stopStops() throws {
        let model = try Self.model(permission: .denied)
        model.startMicrophonePermissionWatcher()
        #expect(model.isWatchingMicrophonePermissionForTesting, "caso mal montado: no arrancó")

        model.stopMicrophonePermissionWatcher()

        #expect(!model.isWatchingMicrophonePermissionForTesting, "el temporizador siguió vivo")
    }

    @Test("y arrancarlo dos veces no deja dos temporizadores sondeando")
    func startingTwiceLeavesOneWatcher() throws {
        let model = try Self.model(permission: .denied)
        model.startMicrophonePermissionWatcher()
        model.startMicrophonePermissionWatcher()

        // Se cuentan los que siguen VIVOS en el run loop, no lo que el modelo tenga
        // guardado. La versión anterior de este test afirmaba
        // `!isWatchingMicrophonePermissionForTesting` después de parar, y eso es cierto
        // pase lo que pase: `stop()` pone la propiedad a `nil` incondicionalmente. Una
        // auditoría independiente lo midió — borrar la línea que evita el huérfano
        // sobrevivía a las 481 pruebas, con un `Timer` quedándose en `RunLoop.main` a 40
        // despertares por minuto y sin nadie que pudiera invalidarlo.
        #expect(
            model.liveMicrophoneWatchersForTesting == 1,
            "arrancar dos veces dejó \(model.liveMicrophoneWatchersForTesting) temporizadores vivos"
        )

        model.stopMicrophonePermissionWatcher()

        #expect(
            model.liveMicrophoneWatchersForTesting == 0,
            "quedó un temporizador huérfano que ya nadie puede apagar"
        )
    }

    @Test("cerrar la ventana de Ajustes apaga el sondeo")
    func closingSettingsStopsTheWatcher() throws {
        let delegate = AppDelegate()
        let model = delegate.modelForTesting
        model.microphonePermission = { .denied }
        model.startMicrophonePermissionWatcher()
        #expect(model.isWatchingMicrophonePermissionForTesting, "caso mal montado: no arrancó")

        // `.onDisappear` no se ejecuta al cerrar una ventana de AppKit, así que este es el
        // único sitio donde el apagado puede ocurrir.
        let window = NSWindow(
            contentRect: .init(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.titled], backing: .buffered, defer: true
        )
        // Sin `close()`: llamarlo sobre una ventana que nunca se mostró revienta el
        // proceso de test entero con SIGSEGV (medido, aislado en una sonda). No hace
        // falta — al salir de alcance se libera igual.
        delegate.setSettingsWindowForTesting(window)

        delegate.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: window))

        #expect(
            !model.isWatchingMicrophonePermissionForTesting,
            "el sondeo sobrevivió al cierre de Ajustes: 40 despertares por minuto durante semanas"
        )
    }

    @Test("cerrar OTRA ventana no lo apaga")
    func closingAnotherWindowLeavesItAlone() throws {
        let delegate = AppDelegate()
        let model = delegate.modelForTesting
        model.microphonePermission = { .denied }
        model.startMicrophonePermissionWatcher()
        defer { model.stopMicrophonePermissionWatcher() }

        let settings = NSWindow(
            contentRect: .init(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.titled], backing: .buffered, defer: true
        )
        let other = NSWindow(
            contentRect: .init(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.titled], backing: .buffered, defer: true
        )
        delegate.setSettingsWindowForTesting(settings)

        delegate.windowWillClose(Notification(name: NSWindow.willCloseNotification, object: other))

        // Sin el guard por identidad, cerrar cualquier ventana de la app —el panel
        // incluido— dejaría a Ajustes sin enterarse nunca de que el permiso llegó.
        #expect(
            model.isWatchingMicrophonePermissionForTesting,
            "cerrar una ventana ajena apagó el sondeo de Ajustes"
        )
    }
}
