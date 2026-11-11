import AppKit
import Foundation

/// Observa el portapapeles del sistema.
///
/// macOS no notifica los cambios del portapapeles: no hay `NSNotification`, ni
/// KVO, ni callback. La única vía es consultar `changeCount`, un entero que el
/// sistema incrementa en cada escritura. Todos los gestores de portapapeles del
/// mundo hacen esto; no hay una alternativa más elegante escondida.
///
/// 500 ms es el intervalo de referencia: por debajo no se gana nada perceptible
/// —nadie copia y pega en menos— y por encima empieza a notarse el retraso
/// cuando se copia y se abre el panel de inmediato.
@MainActor
public final class ClipboardMonitor {
    public typealias Handler = (CapturedItem) -> Void

    private let pasteboard: NSPasteboard
    private let interval: TimeInterval
    /// `nonisolated(unsafe)` para poder invalidarlo desde `deinit`, que nunca
    /// es aislado al actor. Solo se toca desde el hilo principal: la clase
    /// entera es `@MainActor` y el timer se programa en el run loop principal.
    private nonisolated(unsafe) var timer: Timer?

    /// Holgura del temporizador de sondeo, para que un test pueda comprobar que sigue
    /// puesta. Sin esto, quitar `tolerance` no rompería nada: es una propiedad que no
    /// cambia ningún comportamiento observable, solo el consumo — justo el tipo de cosa
    /// que desaparece en una refactorización y nadie echa de menos hasta que a alguien se
    /// le acaba la batería antes de tiempo.
    public var pollToleranceForTesting: TimeInterval? { timer?.tolerance }
    private var lastChangeCount: Int
    private var handler: Handler?

    /// Bundle IDs the user excluded. Checked against the app that made the copy: the
    /// frontmost app when the change is detected, which most probably did, unless the item
    /// declares its source — see `attribution()` for which bundles decide then.
    public var excludedBundleIDs: Set<String> = []

    /// ¿Está la captura pausada **ahora**?
    ///
    /// Es un cierre y no un booleano copiado, y el motivo es un fallo medido: la pausa
    /// del historial se guarda como **fecha de vencimiento**, así que «pausado» caduca
    /// sola sin que nadie emita ningún evento. Con una copia, el vencimiento solo se
    /// reflejaba donde alguien se acordaba de volver a copiarla — y aquí nadie se
    /// acordaba: al vencer una pausa de quince minutos, el icono volvía a la normalidad,
    /// el panel dejaba de avisar y la casilla del menú se desmarcaba, mientras este
    /// monitor **seguía descartando cada copia el resto de la vida del proceso**.
    ///
    /// Es exactamente el fallo simétrico que la duración explícita existe para evitar,
    /// servido al revés: creerse capturando cuando no se captura. Con el estado derivado
    /// del reloj en el punto de uso, no hay ningún camino que se pueda olvidar de
    /// actualizarlo.
    public var isPausedNow: @MainActor () -> Bool = { false }

    /// Compatibilidad para quien solo necesita fijar una pausa indefinida.
    public var isPaused: Bool {
        get { isPausedNow() }
        set {
            let paused = newValue
            isPausedNow = { paused }
        }
    }

    /// Techos de tamaño de lo que entra al historial.
    /// Quién está en primer plano. Inyectable, y no por simetría: la exclusión de apps
    /// —«no archives nada copiado dentro de 1Password»— se decide con esto, y mientras
    /// leía `NSWorkspace` directamente **no había forma de probarla**: en un proceso de
    /// test, quien está en primer plano es lo que el usuario tenga abierto en ese
    /// instante. Medido por una auditoría independiente: desactivar la exclusión entera
    /// dejaba los 451 tests en verde.
    public var frontmostApplication: @MainActor () -> (bundleID: String?, name: String?) = {
        let app = NSWorkspace.shared.frontmostApplication
        return (app?.bundleIdentifier, app?.localizedName)
    }

    /// Name of an app from its bundle identifier, for items that declare their writer
    /// (`PasteboardSource`). Injectable for the same reason as `frontmostApplication`: what
    /// is installed on the machine running the tests must not decide them.
    public var applicationName: @MainActor (String) -> String? = PasteboardSource.installedApplicationName

    public var limits: CaptureLimits = .standard

    /// Se llama con el resultado de cada lectura, capture o no.
    ///
    /// Separado del handler principal porque la interfaz necesita reaccionar a
    /// los descartes —avisar de que algo era demasiado grande— sin que eso
    /// contamine el camino normal de ingesta.
    public var onOutcome: ((CaptureOutcome) -> Void)?

    public init(pasteboard: NSPasteboard = .general, interval: TimeInterval = 0.5) {
        self.pasteboard = pasteboard
        self.interval = interval
        self.lastChangeCount = pasteboard.changeCount
    }

    deinit { timer?.invalidate() }

    /// Arranca la observación.
    ///
    /// - Parameter captureExisting: si el portapapeles ya tiene contenido al
    ///   arrancar, lo registra. Merece la pena: sin esto, reiniciar la app
    ///   —o arrancarla al iniciar sesión— pierde lo último que se copió. No
    ///   crea duplicados porque la huella de contenido colapsa las repeticiones.
    public func start(captureExisting: Bool = true, handler: @escaping Handler) {
        self.handler = handler
        timer?.invalidate()

        if captureExisting {
            // Forzar la comparación: el contador ya está sincronizado desde el
            // init y sin esto la primera consulta no vería nada.
            lastChangeCount = pasteboard.changeCount - 1
        }

        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        // Un 10 % de holgura. Es el temporizador que más corre de la app —vive toda la
        // sesión— y a la vez el que menos nota el retraso: lo copiado sigue en el
        // portapapeles, así que capturarlo unas decenas de milisegundos más tarde no
        // cambia nada. Lo que sí cambia es que el sistema pueda agrupar el despertar.
        timer.tolerance = interval * 0.1
        // `.common` mantiene la captura viva mientras hay un menú abierto o el
        // usuario está arrastrando algo; con el modo por defecto el timer se
        // congela justo en los momentos en que más se copia.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer

        if captureExisting { poll() }
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    /// Marca el estado actual como ya visto. Se llama después de escribir en el
    /// portapapeles desde la propia app, para no volver a capturar lo que
    /// acabamos de pegar nosotros.
    public func acknowledgeCurrentState() {
        lastChangeCount = pasteboard.changeCount
    }

    private func poll() {
        guard !isPausedNow() else {
            // Aun en pausa hay que seguir el contador: al reanudar no debe
            // capturarse en bloque todo lo copiado mientras tanto.
            lastChangeCount = pasteboard.changeCount
            return
        }

        let current = pasteboard.changeCount
        guard current != lastChangeCount else { return }
        lastChangeCount = current

        let source = attribution()

        if let excluded = source.excludedBy.first(where: excludedBundleIDs.contains) {
            onOutcome?(.ignored(.excludedApp(excluded)))
            return
        }

        let outcome = PasteboardReader.inspect(
            pasteboard,
            sourceBundle: source.bundleID,
            sourceName: source.name,
            limits: limits
        )
        onOutcome?(outcome)

        guard case .captured(let captured) = outcome else { return }
        handler?(captured)
    }

    /// Who the entry names as its source, and which bundles decide whether it is excluded.
    ///
    /// The item's own declaration (`PasteboardSource`) comes before the frontmost app, which
    /// is only the app that most probably made the copy:
    ///
    /// - **A remote origin** names "<device> · <App>" with the writer's bundle (the syncing
    ///   app, so the entry shows its icon). Exclusion is decided by that writer alone: the
    ///   copy provably did not happen in the Mac's frontmost app, so excluding that app must
    ///   not drop it, and excluding the syncing app does.
    /// - **A declared writer alone** (`org.nspasteboard.source`) names that app. Exclusion
    ///   then checks the writer **and** the frontmost app: a local copy declaring its writer
    ///   was most probably made with an excluded app in front all the same, and between two
    ///   readings the one that leaves no trace wins (the rule dictation already follows,
    ///   `AppModel.shouldArchive`). Declaring a writer can only narrow what is kept, never
    ///   bypass an exclusion.
    ///
    /// Safe for the paste-back path: when Ámbar writes an entry back, `Paster` marks it
    /// `AutoGeneratedType`, which the reader drops before anything is kept, and it writes only
    /// the stored representations — `PasteboardReader` never stores either declaration — so a
    /// pasted entry cannot replay a remote origin or a foreign writer.
    private func attribution() -> (bundleID: String?, name: String?, excludedBy: [String]) {
        let declared = pasteboard.pasteboardItems?.first.flatMap(PasteboardSource.read)

        if let declared, let remoteName = declared.remoteDisplayName {
            let writer = declared.writerBundleID
            return (writer, remoteName, writer.map { [$0] } ?? [])
        }

        let frontmost = frontmostApplication()
        if let writer = declared?.writerBundleID {
            return (writer, applicationName(writer), [writer] + (frontmost.bundleID.map { [$0] } ?? []))
        }
        return (frontmost.bundleID, frontmost.name, frontmost.bundleID.map { [$0] } ?? [])
    }
}
