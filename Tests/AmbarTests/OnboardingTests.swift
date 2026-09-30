import AppCore
import Foundation
import Testing

@testable import Ambar

/// La presentación de primer uso: qué pasos se muestran y por dónde va.
///
/// Todo esto se prueba sin montar una ventana, que es la razón de que el plan y la
/// navegación vivan fuera de la vista. Lo visual —que el cristal se compone, que el texto
/// alemán no desborda— solo se puede juzgar en pantalla, y está anotado como tal.
@Suite("Presentación de primer uso")
struct OnboardingTests {

    // MARK: - El plan

    @Test("con la app fuera de su sitio y sin permiso se muestran los seis pasos")
    func fullPlan() {
        let steps = OnboardingFlow.steps(
            for: OnboardingConditions(
                relocation: .offerMove(
                    from: URL(fileURLWithPath: "/Users/x/Downloads/Ambar.app"),
                    to: URL(fileURLWithPath: "/Applications/Ambar.app")
                ),
                canAutoPaste: false
            )
        )

        #expect(steps == [.welcome, .location, .accessibility, .invocation, .extras, .finish])
    }

    /// El orden es contrato, no estética: el traslado va **antes** del permiso porque el
    /// permiso se concede a una copia concreta y moverla después es la vía conocida de
    /// perderlo.
    @Test("la ubicación se pide antes que el permiso")
    func locationComesBeforeAccessibility() {
        let steps = OnboardingFlow.steps(
            for: OnboardingConditions(
                relocation: .offerCopy(
                    from: URL(fileURLWithPath: "/Volumes/Ámbar/Ambar.app"),
                    to: URL(fileURLWithPath: "/Applications/Ambar.app")
                ),
                canAutoPaste: false
            )
        )

        // Sin `#require`: el macro avisa de que es redundante sobre un `firstIndex` que él
        // ve como no opcional, y el gate de avisos de este repositorio no admite ninguno.
        let location = steps.firstIndex(of: .location)
        let accessibility = steps.firstIndex(of: .accessibility)
        #expect(location != nil, "no se ofreció el traslado: \(steps)")
        #expect(accessibility != nil, "no se pidió el permiso: \(steps)")
        if let location, let accessibility {
            #expect(location < accessibility, "el permiso se pide antes de mover la app")
        }
    }

    @Test("si ya está en Aplicaciones, ese paso no aparece")
    func skipsLocation() {
        let steps = OnboardingFlow.steps(
            for: OnboardingConditions(relocation: .alreadyInPlace, canAutoPaste: false)
        )

        #expect(steps.contains(.location) == false)
        #expect(steps.contains(.accessibility))
    }

    /// Pedirle a alguien un permiso que ya concedió le hace dudar de que la app sepa lo que
    /// está pasando.
    @Test("si el permiso ya está concedido, ese paso no aparece")
    func skipsAccessibility() {
        let steps = OnboardingFlow.steps(
            for: OnboardingConditions(relocation: .alreadyInPlace, canAutoPaste: true)
        )

        #expect(steps == [.welcome, .invocation, .extras, .finish])
    }

    @Test("en desarrollo no se ofrece mover la app")
    func skipsLocationInDevelopment() {
        let steps = OnboardingFlow.steps(
            for: OnboardingConditions(relocation: .development, canAutoPaste: false)
        )

        #expect(steps.contains(.location) == false)
    }

    // MARK: - Composición

    /// Qué pasos son portada y cuáles pantallas de trabajo. Gobierna la composición —una
    /// portada va al eje y ocupa el ancho entero; un paso con controles se limita al ancho de
    /// su tarjeta— y es lo único de lo visual que se puede afirmar sin mirar la pantalla.
    @Test("solo la bienvenida y el cierre son portadas")
    func coverSteps() {
        #expect(OnboardingStep.welcome.isCover)
        #expect(OnboardingStep.finish.isCover)
        for step in [OnboardingStep.location, .accessibility, .invocation, .extras] {
            #expect(step.isCover == false, "\(step.rawValue) no debería componerse como portada")
        }
    }

    /// El primero y el último paso de cualquier plan son portadas, y eso no es casualidad:
    /// son los dos que no piden nada. Si un día se añade un paso al final, este test obliga a
    /// decidir su composición en vez de heredarla por descuido.
    @Test("el plan empieza y acaba en una portada")
    func planStartsAndEndsWithCover() {
        for canAutoPaste in [true, false] {
            let steps = OnboardingFlow.steps(
                for: OnboardingConditions(relocation: .alreadyInPlace, canAutoPaste: canAutoPaste)
            )
            #expect(steps.first?.isCover == true)
            #expect(steps.last?.isCover == true)
        }
    }

    // MARK: - Cuándo se presenta

    @Test("se presenta mientras no se haya visto esta versión del guion")
    func presentsUntilSeen() {
        #expect(OnboardingFlow.shouldPresent(completedVersion: 0))
        #expect(OnboardingFlow.shouldPresent(completedVersion: OnboardingFlow.currentVersion) == false)
    }

    /// La versión guardada existe para poder enseñar **solo lo nuevo** el día que se añada un
    /// paso. Un booleano obligaría a elegir entre no enseñarlo nunca o repetirlo todo.
    @Test("una versión futura del guion volvería a presentarse")
    func futureVersionPresentsAgain() {
        #expect(OnboardingFlow.currentVersion >= 1)
        #expect(OnboardingFlow.shouldPresent(completedVersion: OnboardingFlow.currentVersion - 1))
    }

    // MARK: - Navegación

    @MainActor
    private func makeCoordinator(
        canAutoPaste: Bool = false,
        onFinish: @MainActor @escaping () -> Void = {}
    ) -> OnboardingCoordinator {
        OnboardingCoordinator(
            conditions: OnboardingConditions(
                relocation: .alreadyInPlace,
                canAutoPaste: canAutoPaste
            ),
            onFinish: onFinish
        )
    }

    @MainActor
    @Test("avanzar recorre los pasos en orden y volver deshace")
    func navigation() {
        let coordinator = makeCoordinator(canAutoPaste: true)

        #expect(coordinator.current == .welcome)
        #expect(coordinator.isFirst)
        #expect(coordinator.position == 1)
        #expect(coordinator.total == 4)

        coordinator.advance()
        #expect(coordinator.current == .invocation)
        #expect(coordinator.isFirst == false)

        coordinator.back()
        #expect(coordinator.current == .welcome)
    }

    @MainActor
    @Test("volver desde el primer paso no se sale de la lista")
    func backOnFirstIsHarmless() {
        let coordinator = makeCoordinator()
        coordinator.back()
        #expect(coordinator.index == 0)
        #expect(coordinator.current == .welcome)
    }

    @MainActor
    @Test("avanzar en el último paso termina la presentación")
    func advanceOnLastFinishes() {
        var finished = 0
        let coordinator = makeCoordinator(canAutoPaste: true) { finished += 1 }

        while !coordinator.isLast { coordinator.advance() }
        #expect(coordinator.current == .finish)
        #expect(finished == 0)

        coordinator.advance()
        #expect(finished == 1)
        // Y no se ha salido de la lista: el índice sigue siendo válido.
        #expect(coordinator.current == .finish)
    }

    /// El plan se fija al construirse. Si se recalculara, conceder Accesibilidad —lo que uno
    /// de los pasos pide— haría desaparecer ese paso bajo el cursor y movería el botón que el
    /// usuario iba a pulsar.
    @MainActor
    @Test("el plan no cambia mientras la presentación está abierta")
    func planIsFixed() {
        let coordinator = makeCoordinator(canAutoPaste: false)
        let planned = coordinator.steps

        coordinator.advance()
        coordinator.advance()

        #expect(coordinator.steps == planned)
        #expect(coordinator.steps.contains(.accessibility))
    }

    // MARK: - El atajo que otro proceso se queda

    /// El fallo que este estado arregla era **silencioso y total**: con la combinación tomada
    /// por otro proceso —otra app, o una segunda copia de Ámbar—, `RegisterEventHotKey`
    /// devuelve error, la app arrancaba igual y su única forma de invocarse no hacía nada.
    ///
    /// Se prueba el estado y no el registro real: registrar un atajo global desde la suite
    /// se lo quitaría a la instancia de Ámbar que pueda estar corriendo en la máquina, que es
    /// exactamente el daño que este arreglo existe para explicar.
    @MainActor
    @Test("un registro fallido del atajo deja constancia")
    func failedHotKeyRegistrationIsVisible() {
        let model = AppModel()
        #expect(model.isHotKeyUnavailable == false)

        model.applyHotKeyRegistration(succeeded: false)
        #expect(model.isHotKeyUnavailable)

        model.applyHotKeyRegistration(succeeded: true)
        #expect(model.isHotKeyUnavailable == false)
    }

    /// El menú de la barra es donde mira quien pulsa el atajo y no ve nada, así que el aviso
    /// tiene que llegar ahí: el modelo avisa del cambio para que se reconstruya.
    @MainActor
    @Test("el cambio de disponibilidad del atajo pide reconstruir el menú")
    func hotKeyChangeRefreshesMenu() {
        let model = AppModel()
        var refreshes = 0
        model.onCaptureStateChange = { refreshes += 1 }

        model.applyHotKeyRegistration(succeeded: false)
        #expect(refreshes == 1)

        // Y no avisa cuando nada cambió: el menú se reconstruye en cada registro del atajo
        // —también al cambiarlo en Ajustes—, y hacerlo dos veces por nada es trabajo en el
        // hilo principal de un agente que vive semanas.
        model.applyHotKeyRegistration(succeeded: false)
        #expect(refreshes == 1)

        model.applyHotKeyRegistration(succeeded: true)
        #expect(refreshes == 2)
    }
}
