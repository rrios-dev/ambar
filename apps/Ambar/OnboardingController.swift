import AppCore
import AppKit
import GlassUI
import SwiftUI

/// Presenta la ventana de primer uso y decide cuándo hay que presentarla.
///
/// Es una ventana **titulada** y no una `NSPanel` sin borde como el historial, y esa
/// diferencia es intencionada por dos motivos que van juntos:
///
/// - Aquí hay que escribir: el grabador de atajos necesita ser vista clave para recibir las
///   teclas. El panel del historial es explícitamente *no activador* para poder pegar de
///   vuelta en la app anterior, que es lo contrario de lo que hace falta aquí.
/// - Una ventana de bienvenida sin forma visible de cerrarse es una trampa. El botón rojo
///   del sistema es la salida que todo el mundo ya conoce.
@MainActor
final class OnboardingController: NSObject, NSWindowDelegate {
    private let model: AppModel
    private var window: NSWindow?
    private var coordinator: OnboardingCoordinator?

    /// Qué hacer cuando la presentación termina: abrir el panel para que se vea el
    /// historial. Lo inyecta el delegado de la app, que es quien posee el panel.
    private let onCompleted: @MainActor () -> Void

    init(model: AppModel, onCompleted: @MainActor @escaping () -> Void) {
        self.model = model
        self.onCompleted = onCompleted
        super.init()
    }

    /// ¿Hay que presentarla en este arranque?
    ///
    /// Solo pregunta por la versión ya vista. Los modos de revisión y el aislamiento de
    /// preferencias los resuelve `AppDelegate`, que es quien conoce el entorno.
    static func shouldPresent(settings: Settings) -> Bool {
        OnboardingFlow.shouldPresent(completedVersion: settings.onboardingCompletedVersion)
    }

    /// La ventana viva, para el arnés que vuelca el árbol de accesibilidad real.
    var windowForReview: NSWindow? { window }

    /// El plan en curso, para poder afirmar en un test qué pasos se van a mostrar.
    var coordinatorForTesting: OnboardingCoordinator? { coordinator }

    /// - Parameter conditions: los hechos con los que planificar. En producción se pasa
    ///   `nil` y se leen de la máquina; el arnés de revisión los fija para que el volcado del
    ///   árbol de accesibilidad no dependa de si **esa** máquina ya tiene el permiso
    ///   concedido —lo que dejaría el gate midiendo un plan distinto en cada Mac—.
    func present(conditions fixed: OnboardingConditions? = nil) {
        if let window {
            window.makeKeyAndOrderFront(nil)
            NSApp.activate()
            return
        }

        // El estado real de la máquina, leído **una vez**: dónde está la app y si ya tiene
        // el permiso. Ver `OnboardingCoordinator.steps` para por qué el plan no se
        // recalcula después.
        let conditions = fixed ?? OnboardingConditions(
            relocation: AppRelocation.decide(bundleURL: Bundle.main.bundleURL),
            canAutoPaste: Paster.canPaste
        )

        let coordinator = OnboardingCoordinator(conditions: conditions) { [weak self] in
            self?.complete()
        }
        self.coordinator = coordinator

        let hosting = NSHostingView(rootView: OnboardingView(model: model, coordinator: coordinator))
        hosting.frame = NSRect(
            x: 0,
            y: 0,
            width: Metrics.onboardingWidth,
            height: Metrics.onboardingHeight
        )
        // Sin fondo propio: cualquier color aquí taparía el cristal que va debajo.
        hosting.wantsLayer = true
        hosting.layer?.backgroundColor = NSColor.clear.cgColor

        let window = NSWindow(
            contentRect: hosting.frame,
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.isOpaque = false
        window.backgroundColor = .clear
        // La ventana ya recorta a su propio radio, así que el material no debe imponer
        // otro: con un radio propio se ven dos cantos desalineados en cada esquina.
        window.contentView = Glass.makeWindowBackdrop(
            content: hosting,
            cornerRadius: 0,
            style: .regular
        )
        hosting.autoresizingMask = [.width, .height]
        // El título no se ve, pero es lo que VoiceOver anuncia al entrar en la ventana y lo
        // que aparece en el conmutador de ventanas.
        window.title = String(localized: "onboarding.title", bundle: .localized)
        window.isReleasedWhenClosed = false
        window.center()
        window.delegate = self
        self.window = window

        window.makeKeyAndOrderFront(nil)
        // Una app sin icono en el Dock no recibe la activación por el hecho de mostrar una
        // ventana, y sin ella la ventana sale detrás de lo que el usuario tenga delante:
        // una presentación que nadie ve.
        NSApp.activate()
    }

    /// Terminó: se anota la versión vista y se cierra.
    private func complete() {
        markSeen()
        window?.close()
        onCompleted()
    }

    /// Cerrar con el botón rojo **también** cuenta como vista.
    ///
    /// La alternativa —volver a presentarla en el siguiente arranque hasta que alguien
    /// llegue al último paso— convierte una bienvenida en una insistencia. Quien la cierre a
    /// medias la tiene entera en Ajustes, con el botón «ver la presentación de nuevo».
    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === window else { return }
        markSeen()
        // El sondeo del permiso de Accesibilidad —40 despertares por minuto— lo arranca el
        // paso que lo pide y no tiene forma de saber que la ventana se ha ido. En un agente
        // de barra de menús, un temporizador que sobrevive a su ventana vive semanas.
        model.stopPermissionWatcher()
        window = nil
        coordinator = nil
    }

    private func markSeen() {
        model.settings.onboardingCompletedVersion = OnboardingFlow.currentVersion
    }

    /// Vuelve a mostrarla a petición del usuario, desde Ajustes.
    func presentAgain() {
        // La versión se rebaja para que el plan se recalcule desde cero; `present()` la
        // volverá a marcar al cerrarse.
        model.settings.onboardingCompletedVersion = 0
        present()
    }
}
