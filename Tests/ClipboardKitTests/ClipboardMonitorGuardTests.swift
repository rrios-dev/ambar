import AppKit
import Testing

@testable import ClipboardKit

/// Las dos garantías de privacidad del producto, **en el sitio donde se aplican**.
///
/// Hallazgo grave de una auditoría independiente: desactivar la pausa del historial
/// (`guard !isPausedNow()` → `guard true`) o la exclusión de apps (`&& false`) dejaba los
/// 451 tests en verde. Los tests de pausa que existían ejercitaban el *getter*
/// `monitor.isPaused` —una propiedad calculada— y nunca `poll()`, que es la línea que de
/// verdad decide si una copia entra al historial.
///
/// Al usuario: una regresión ahí significa que lo copiado dentro de un gestor de
/// contraseñas acaba archivado, o que «pausar el historial» deja de pausar nada — y la
/// integración continua diría que todo está bien.
///
/// No hace falta esperar al temporizador: `start(captureExisting: true)` llama a `poll()`
/// de forma síncrona (`ClipboardMonitor.swift:95-99`), así que el ciclo real se ejercita
/// entero sin depender del reloj.
@Suite("El vigilante respeta la pausa y las apps excluidas", .serialized)
@MainActor
struct ClipboardMonitorGuardTests {

    /// Portapapeles propio: el general lo comparte todo el sistema, y un test no puede
    /// dejar la máquina distinta de como la encontró.
    static func scratch(_ text: String) -> NSPasteboard {
        let board = NSPasteboard(name: .init("dev.rrios.ambar.tests.monitor.\(UUID().uuidString)"))
        board.clearContents()
        board.setString(text, forType: .string)
        return board
    }

    static func monitor(_ board: NSPasteboard) -> ClipboardMonitor {
        let monitor = ClipboardMonitor(pasteboard: board, interval: 3600)
        // Primer plano determinista: sin esto, lo que decide el test es qué app tenga
        // delante quien lo ejecuta.
        monitor.frontmostApplication = { (bundleID: "com.example.editor", name: "Editor") }
        return monitor
    }

    @Test("con la captura pausada, lo copiado NO entra al historial")
    func pausedCaptureIngestsNothing() {
        let board = Self.scratch("algo copiado durante la pausa")
        let monitor = Self.monitor(board)
        monitor.isPausedNow = { true }

        var captured: [String] = []
        monitor.start(captureExisting: true) { captured.append($0.preview) }
        defer { monitor.stop() }

        #expect(captured.isEmpty, "la pausa no pausó nada: \(captured)")
    }

    @Test("sin pausa, lo copiado sí entra: el test anterior no pasa por estar muerto")
    func unpausedCaptureIngests() {
        // La mitad que impide el falso positivo. Sin esto, «no capturó nada» se cumpliría
        // igual con el vigilante roto, y el test de arriba no probaría la pausa sino la
        // ausencia de vigilante.
        let board = Self.scratch("algo copiado con la captura activa")
        let monitor = Self.monitor(board)
        monitor.isPausedNow = { false }

        var captured: [String] = []
        monitor.start(captureExisting: true) { captured.append($0.preview) }
        defer { monitor.stop() }

        #expect(
            captured == ["algo copiado con la captura activa"],
            "el vigilante no capturó con la captura activa: \(captured)"
        )
    }

    @Test("lo copiado desde una app excluida NO entra al historial")
    func excludedAppIngestsNothing() {
        let board = Self.scratch("una contraseña")
        let monitor = Self.monitor(board)
        monitor.frontmostApplication = { (bundleID: "com.1password.1password", name: "1Password") }
        monitor.excludedBundleIDs = ["com.1password.1password"]

        var captured: [String] = []
        var outcomes: [CaptureOutcome] = []
        monitor.onOutcome = { outcomes.append($0) }
        monitor.start(captureExisting: true) { captured.append($0.preview) }
        defer { monitor.stop() }

        #expect(captured.isEmpty, "archivó lo copiado desde un gestor de contraseñas: \(captured)")
        // Y lo dice, en vez de descartarlo en silencio: sin el motivo, un descarte
        // legítimo y un vigilante muerto se ven igual.
        #expect(
            outcomes.contains { if case .ignored(.excludedApp) = $0 { return true } else { return false } },
            "descartó sin decir por qué: \(outcomes)"
        )
    }

    @Test("desde una app NO excluida, lo mismo sí entra")
    func nonExcludedAppIngests() {
        let board = Self.scratch("texto normal")
        let monitor = Self.monitor(board)
        monitor.excludedBundleIDs = ["com.1password.1password"]

        var captured: [String] = []
        monitor.start(captureExisting: true) { captured.append($0.preview) }
        defer { monitor.stop() }

        #expect(captured == ["texto normal"], "la exclusión se comió una app que no lo está: \(captured)")
    }
}

/// El sondeo del portapapeles corre toda la sesión: es el temporizador más caro de la app.
///
/// `Timer.tolerance` es lo que le permite al sistema agrupar ese despertar con otros en
/// lugar de encender el procesador en el instante exacto. La auditoría de cierre encontró
/// que no había **ninguna** en toda la app, en cinco temporizadores repetidos.
///
/// Se prueba aquí y no en los otros cuatro porque este es el único que corre siempre; y se
/// prueba porque `tolerance` no cambia nada observable salvo el consumo, así que borrarla
/// no rompería ningún otro test.
@Suite("El sondeo deja al sistema agrupar sus despertares", .serialized)
@MainActor
struct ClipboardMonitorToleranceTests {

    @Test("el temporizador de sondeo lleva holgura")
    func pollTimerHasTolerance() {
        let board = ClipboardMonitorGuardTests.scratch("lo que sea")
        let monitor = ClipboardMonitor(pasteboard: board, interval: 2)
        monitor.frontmostApplication = { (bundleID: "com.example.editor", name: "Editor") }
        monitor.start(captureExisting: false) { _ in }
        defer { monitor.stop() }

        let tolerance = monitor.pollToleranceForTesting
        #expect(tolerance == 0.2, "holgura inesperada para un intervalo de 2 s: \(String(describing: tolerance))")
    }
}
