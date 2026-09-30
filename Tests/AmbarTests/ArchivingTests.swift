import AppKit
import ClipboardKit
import Foundation
import Testing
import VoiceKit

@testable import Ambar

/// El archivado de lo dictado, **llamando a `deliverDictation`**.
///
/// La versión anterior de este archivo decía existir para cerrar ese circuito y no lo
/// cerraba: reimplementaba la guarda dentro del propio test
/// (`if AppModel.shouldArchive(...) { try ingestor.ingest(...) }`), así que sustituir la
/// guarda **real** por `if true` dejaba la suite entera en verde. Lo midió una auditoría
/// por mutación, y era la cuarta repetición del mismo fallo de método — esta vez en el
/// test escrito para repararlo.
///
/// Lo que cambió para poder arreglarlo de verdad: `deliverDictation` recibe el destino y
/// el pegado por parámetro en lugar de un `PanelController`, así que se puede ejercitar
/// entero contra un `Store` temporal.
@Suite("Archivado de lo dictado")
@MainActor
struct ArchivingTests {

    /// Modelo con historial en un directorio temporal: no toca el real.
    static func makeModel() throws -> (AppModel, URL) {
        let root = FileManager.default.temporaryDirectory
            .appending(path: "ambar-archiving-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let suite = "dev.rrios.ambar.tests.\(UUID().uuidString)"
        let model = AppModel(settings: Settings(defaults: UserDefaults(suiteName: suite) ?? .standard))
        try model.startForTesting(directory: root)
        return (model, root)
    }

    static func transcript(_ text: String, truncated: Bool = false) -> Transcript {
        Transcript(text: text, mode: .live, wasTruncated: truncated)
    }

    @Test("un dictado normal se archiva y se pega")
    func normalDictationIsArchivedAndPasted() throws {
        let (model, root) = try Self.makeModel()
        defer { try? FileManager.default.removeItem(at: root) }

        var pasted: [DictationDelivery] = []
        model.deliverDictation(
            Self.transcript("hola mundo"),
            targetBundleID: "com.apple.TextEdit",
            paste: { pasted.append($0) }
        )

        #expect(model.historyCount() == 1, "no llegó al historial")
        #expect(pasted.count == 1, "no se pegó")
        #expect(pasted.first?.concealed == false, "lo marcó como sensible sin motivo")
    }

    @Test("hacia una app excluida no se archiva, y va marcado como sensible")
    func excludedTargetIsNotArchived() throws {
        let (model, root) = try Self.makeModel()
        defer { try? FileManager.default.removeItem(at: root) }

        var pasted: [DictationDelivery] = []
        model.deliverDictation(
            Self.transcript("una contraseña dictada"),
            targetBundleID: "com.1password.1password",
            paste: { pasted.append($0) }
        )

        #expect(model.historyCount() == 0, "dictar en un gestor de contraseñas entró al historial")
        // Y la otra mitad, que es la que nadie probaba: si Ámbar decide no guardarlo,
        // dejarlo legible en el portapapeles se lo entrega al gestor de al lado.
        #expect(pasted.first?.concealed == true, "quedó en claro para cualquier otro gestor")
    }

    @Test("en pausa no se archiva nada")
    func pausedDoesNotArchive() throws {
        let (model, root) = try Self.makeModel()
        defer { try? FileManager.default.removeItem(at: root) }
        model.settings.pauseCapture(.fifteenMinutes)

        model.deliverDictation(
            Self.transcript("mientras está en pausa"),
            targetBundleID: "com.apple.TextEdit",
            paste: { _ in }
        )

        // §10: «En pausa el dictado sigue funcionando: transcribe y pega, no guarda».
        #expect(model.historyCount() == 0, "se archivó estando en pausa")
    }

    @Test("con destino desconocido se elige el lado que no deja rastro")
    func unknownTargetIsTreatedAsSensitive() throws {
        let (model, root) = try Self.makeModel()
        defer { try? FileManager.default.removeItem(at: root) }

        var pasted: [DictationDelivery] = []
        model.deliverDictation(
            Self.transcript("hacia ninguna parte"),
            targetBundleID: nil,
            paste: { pasted.append($0) }
        )

        #expect(model.historyCount() == 0)
        #expect(pasted.first?.concealed == true)
    }

    @Test("un dictado vacío no entrega nada")
    func emptyDictationDeliversNothing() throws {
        let (model, root) = try Self.makeModel()
        defer { try? FileManager.default.removeItem(at: root) }

        var pasted: [DictationDelivery] = []
        model.deliverDictation(
            Self.transcript(""),
            targetBundleID: "com.apple.TextEdit",
            paste: { pasted.append($0) }
        )

        #expect(model.historyCount() == 0)
        #expect(pasted.isEmpty, "pegó una cadena vacía")
    }

    @Test("una entrega recortada lo confiesa")
    func truncatedDeliveryConfesses() throws {
        let (model, root) = try Self.makeModel()
        defer { try? FileManager.default.removeItem(at: root) }

        var pasted: [DictationDelivery] = []
        model.deliverDictation(
            Self.transcript("puede faltar el final", truncated: true),
            targetBundleID: "com.apple.TextEdit",
            paste: { pasted.append($0) }
        )

        // §7.2: «se pega lo que haya **y se dice**». Sin esta bandera el aviso no se
        // enciende y la pérdida es silenciosa.
        #expect(pasted.first?.confessesTruncation == true)
    }
}

/// El plan de entrega, como valor.
///
/// Ocultar y archivar son la **misma condición negada**, y mientras se decidían en dos
/// sitios distintos escribir `false` en uno de ellos no rompía nada.
@Suite("Plan de entrega del dictado")
@MainActor
struct DictationDeliveryPlanTests {

    static func settings(paused: Bool = false, excluded: [String] = []) -> Settings {
        let suite = "dev.rrios.ambar.tests.\(UUID().uuidString)"
        let settings = Settings(defaults: UserDefaults(suiteName: suite) ?? .standard)
        if paused { settings.pauseCapture(.untilResumed) }
        settings.excludedBundleIDs = excluded
        return settings
    }

    @Test("ocultar es exactamente lo contrario de archivar, en los cuatro casos")
    func concealIsAlwaysTheNegationOfArchive() {
        let cases: [(Settings, String?)] = [
            (Self.settings(), "com.apple.TextEdit"),
            (Self.settings(paused: true), "com.apple.TextEdit"),
            (Self.settings(excluded: ["com.1password.1password"]), "com.1password.1password"),
            (Self.settings(), nil),
        ]
        for (settings, target) in cases {
            let plan = DictationDelivery.plan(
                transcript: Transcript(text: "texto", mode: .live),
                settings: settings,
                targetBundleID: target
            )
            #expect(plan?.concealed == !(plan?.archives ?? true), "destino: \(target ?? "desconocido")")
        }
    }

    @Test("sin texto no hay plan")
    func noTextNoPlan() {
        #expect(
            DictationDelivery.plan(
                transcript: Transcript(text: "   ", mode: .live),
                settings: Self.settings(),
                targetBundleID: "com.apple.TextEdit"
            ) == nil
        )
    }
}

/// El último tramo: que el marcado de sensible **llegue al portapapeles**.
///
/// El plan como valor hizo la contradicción inexpresable en el plan, pero el tramo hasta
/// `NSPasteboard` se quedó sin guarda: `writeDictatedToPasteboard` no tenía ni un test, y
/// las dos llamadas a `writePlainText` de la suite no pasaban `concealed:`, así que la rama
/// que escribe la marca estaba sin ejercitar. Borrarla dejaba la suite verde — y eso es el
/// mismo defecto que la ronda anterior dio por cerrado, un eslabón más abajo.
@Suite("El marcado de sensible llega al portapapeles")
@MainActor
struct ConcealedPasteboardTests {

    static let concealedType = NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType")

    /// Portapapeles propio: usar el general dejaría la máquina distinta de como la
    /// encontró, y además otro test podría pisarlo.
    static func scratchPasteboard() -> NSPasteboard {
        NSPasteboard(name: NSPasteboard.Name("dev.rrios.ambar.tests.\(UUID().uuidString)"))
    }

    static func model() -> AppModel {
        AppModel(settings: Settings(defaults: UserDefaults(suiteName: "ambar.tests.pb.\(UUID().uuidString)")!))
    }

    @Test("un dictado hacia una app excluida se escribe marcado como sensible")
    func excludedTargetIsWrittenConcealed() {
        let pasteboard = Self.scratchPasteboard()
        let plan = DictationDelivery(
            text: "una contraseña dictada",
            archives: false,
            concealed: true,
            confessesTruncation: false
        )

        Self.model().writeDictatedToPasteboard(plan, to: pasteboard)

        #expect(pasteboard.string(forType: .string) == "una contraseña dictada")
        // La marca de nspasteboard.org: es lo único que impide que **otro** gestor de
        // portapapeles archive lo que Ámbar decidió no archivar.
        #expect(
            pasteboard.data(forType: Self.concealedType) != nil,
            "el texto quedó en claro: cualquier otro gestor lo archivaría"
        )
    }

    @Test("un dictado normal no se marca")
    func normalDictationIsNotConcealed() {
        let pasteboard = Self.scratchPasteboard()
        let plan = DictationDelivery(
            text: "hola mundo",
            archives: true,
            concealed: false,
            confessesTruncation: false
        )

        Self.model().writeDictatedToPasteboard(plan, to: pasteboard)

        // Marcar todo como sensible sería igual de malo por el otro lado: los demás
        // gestores dejarían de guardar lo que el usuario sí quiere que se guarde.
        #expect(pasteboard.data(forType: Self.concealedType) == nil)
    }

    @Test("lo escrito por la app se marca como autogenerado, siempre")
    func writesAreMarkedAutoGenerated() {
        let pasteboard = Self.scratchPasteboard()
        Self.model().writeDictatedToPasteboard(
            DictationDelivery(text: "x", archives: true, concealed: false, confessesTruncation: false),
            to: pasteboard
        )
        // Es lo que evita que el propio monitor de Ámbar recoja su escritura como si fuera
        // una copia del usuario.
        #expect(
            pasteboard.data(forType: NSPasteboard.PasteboardType("org.nspasteboard.AutoGeneratedType")) != nil
        )
    }
}


/// El acuse al monitor tras escribir lo dictado.
///
/// Sin él, el dictado deja **dos** entradas en el historial: la suya, y la que el vigilante
/// del portapapeles recoge medio segundo después, atribuida a la app de destino. El comentario
/// del código ya lo contaba; lo que no había era nada que lo impidiera volver — quitar el
/// acuse dejaba la suite entera en verde.
@Suite("El dictado no se cuela dos veces en el historial", .serialized)
@MainActor
struct DictationAcknowledgementTests {

    /// El vigilante entrega desde su propio contexto; una caja de clase evita capturar
    /// una variable local en un cierre que cruza el aislamiento.
    final class Box: @unchecked Sendable {
        var items: [String] = []
        var outcomes: [CaptureOutcome] = []
    }

    @Test("escribir lo dictado marca el portapapeles como ya visto")
    func writingAcknowledgesTheChange() async throws {
        // Portapapeles privado: el general lo comparte todo el sistema y el test se
        // volvería dependiente de lo que el usuario tenga copiado.
        let board = NSPasteboard(name: .init("ambar.tests.\(UUID().uuidString)"))
        let (model, root) = try ArchivingTests.makeModel()
        defer { try? FileManager.default.removeItem(at: root) }

        let monitor = ClipboardMonitor(pasteboard: board, interval: 0.05)
        let captured = Box()
        model.attachMonitorForTesting(monitor)
        monitor.onOutcome = { captured.outcomes.append($0) }
        monitor.start(captureExisting: false) { captured.items.append($0.preview) }
        defer { monitor.stop() }

        model.writeDictatedToPasteboard(
            DictationDelivery(
                text: "lo que acabo de dictar",
                archives: true,
                concealed: false,
                confessesTruncation: false
            ),
            // **Al mismo portapapeles que vigila el monitor.** Escribir en el general
            // dejaba al vigilante mirando otro sitio: el test pasaba con el acuse
            // quitado, que es exactamente el fallo que venía a impedir.
            to: board
        )

        // Cinco intervalos: si el acuse no ocurrió, al vigilante le sobra tiempo.
        try await Task.sleep(for: .milliseconds(250))
        #expect(
            captured.items.isEmpty,
            "el vigilante recogió lo que acabábamos de escribir: segunda entrada en el historial (\(captured.items))"
        )
        // Y **ni siquiera lo mira**. Esto es lo que aporta el acuse, y hace falta decirlo
        // aparte: medido, quitándolo el vigilante sí lee el portapapeles y lo descarta por
        // la marca de auto-generado (`ignored(.markedPrivate)`), así que la primera
        // aserción sola se cumple igual sin acuse. Son dos defensas distintas y el
        // comentario del código atribuía a esta el mérito de la otra.
        #expect(
            captured.outcomes.isEmpty,
            "leyó un portapapeles que acabábamos de escribir nosotros: \(captured.outcomes)"
        )

        // Y que el vigilante siga vivo: un test que pase porque el monitor está muerto no
        // prueba nada. Una copia ajena sí tiene que verse.
        //
        // Con espera acotada y no dormida fija: el sondeo corre en el hilo principal, que
        // aquí lo comparten todas las suites de la app, y 250 ms bastaban en solitario pero
        // no con la suite entera en marcha. Un test que depende de la carga de la máquina
        // acaba enseñando a ignorar los rojos.
        board.clearContents()
        board.setString("esto lo copió otro", forType: .string)
        await DictationControllerTests.waitUntil { !captured.items.isEmpty }
        #expect(captured.items == ["esto lo copió otro"], "el vigilante estaba muerto: \(captured.items)")
    }
}
