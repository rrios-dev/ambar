import AppCore
import Foundation
import Observation

/// Los pasos de la presentación de primer uso.
///
/// El orden del `enum` **es** el orden en que se muestran, y no es arbitrario:
///
/// 1. `welcome` — qué es esto y que no sale nada del Mac. Antes de pedir nada.
/// 2. `location` — llevar la app a Aplicaciones. **Va antes de cualquier permiso**: los
///    permisos se conceden a una copia concreta, y moverla después es la vía conocida de
///    perderlos (ver `AppRelocation`).
/// 3. `accessibility` — el permiso que hace que `↵` pegue en la app donde estabas.
/// 4. `invocation` — con qué teclas se abre, y si arranca al iniciar sesión.
/// 5. `extras` — dictado y reconocimiento de texto. Ambos saltables; el dictado además
///    implica micrófono y descargar un modelo, y eso lo decide quien lo use.
/// 6. `finish` — cerrar, y recordar dónde se cambia todo después.
enum OnboardingStep: String, CaseIterable, Sendable {
    case welcome
    case location
    case accessibility
    case invocation
    case extras
    case finish

    /// ¿Es una portada —solo se lee— o una pantalla de trabajo con controles?
    ///
    /// Cambia la composición **horizontal**: una portada va al eje, centrada, como la
    /// bienvenida de cualquier app del sistema; una pantalla con controles se alinea al
    /// margen izquierdo, que es de donde arranca la lectura de una lista de ajustes.
    ///
    /// En vertical las dos se centran. Que un paso con controles pudiera centrarse sin que
    /// los botones saltaran de sitio al aparecer un aviso lo resuelve el suelo de altura de
    /// `StepCard`, no la alineación.
    var isCover: Bool {
        switch self {
        case .welcome, .finish: true
        case .location, .accessibility, .invocation, .extras: false
        }
    }
}

/// Los hechos del mundo que deciden qué pasos tienen sentido.
///
/// Se pasan como datos y no se consultan aquí dentro, para que el plan se pueda probar
/// sin una app instalada, sin permisos concedidos y sin tocar el disco.
struct OnboardingConditions: Sendable, Equatable {
    var relocation: AppRelocation.Decision
    /// ¿Está ya concedido el permiso de Accesibilidad?
    var canAutoPaste: Bool

    init(relocation: AppRelocation.Decision, canAutoPaste: Bool) {
        self.relocation = relocation
        self.canAutoPaste = canAutoPaste
    }
}

/// Qué se muestra la primera vez, y cuándo se vuelve a mostrar.
enum OnboardingFlow {
    /// Versión del guion de presentación que este binario trae.
    ///
    /// Se guarda un **número** y no un booleano de «ya la vio». Un booleano obliga a
    /// elegir entre dos cosas malas el día que se añada un paso nuevo: no enseñarlo nunca a
    /// quien ya usa la app, o repetir la presentación entera. Con la versión, un futuro
    /// `2` puede decidir enseñar solo lo que cambió.
    static let currentVersion = 1

    static func shouldPresent(completedVersion: Int) -> Bool {
        completedVersion < currentVersion
    }

    /// El plan: los pasos que este usuario, en esta máquina, va a ver.
    ///
    /// Los pasos ya resueltos se omiten. El caso que gobierna esta regla es
    /// `accessibility`: pedirle a alguien que conceda un permiso que ya concedió —porque
    /// reinstaló, o porque venía de una versión anterior— es hacerle dudar de que la app
    /// sepa lo que está pasando.
    static func steps(for conditions: OnboardingConditions) -> [OnboardingStep] {
        OnboardingStep.allCases.filter { step in
            switch step {
            case .welcome, .invocation, .extras, .finish:
                true
            case .location:
                conditions.relocation.isOffer
            case .accessibility:
                !conditions.canAutoPaste
            }
        }
    }
}

/// Por dónde va la presentación.
///
/// Vive separado de la vista para poder afirmar la navegación —avanzar, volver, terminar,
/// y que el plan no cambie bajo los pies del usuario— sin montar una ventana.
@Observable
@MainActor
final class OnboardingCoordinator {
    /// El plan, **fijado al construirse**.
    ///
    /// No se recalcula al avanzar, y es deliberado: las condiciones cambian mientras la
    /// presentación está abierta —conceder Accesibilidad es justamente lo que se pide en
    /// uno de los pasos— y recalcular haría que el paso que el usuario acaba de resolver
    /// desapareciera de debajo del cursor, moviendo el botón que iba a pulsar. El paso se
    /// queda, y muestra que ya está resuelto.
    let steps: [OnboardingStep]

    /// Los hechos con los que se planificó. La vista los necesita para saber **qué** ofrecer
    /// en el paso de ubicación: mover no es lo mismo que copiar desde la imagen de disco.
    let conditions: OnboardingConditions

    private(set) var index: Int = 0

    /// Qué hacer al terminar: persistir la versión vista y cerrar la ventana. Lo inyecta
    /// quien la presenta.
    private let onFinish: @MainActor () -> Void

    init(conditions: OnboardingConditions, onFinish: @MainActor @escaping () -> Void) {
        self.conditions = conditions
        let planned = OnboardingFlow.steps(for: conditions)
        // Nunca vacío: `welcome` y `finish` no son condicionales. La reserva existe para
        // que un futuro plan que sí pudiera quedar vacío no deje una ventana sin contenido
        // ni un índice fuera de rango.
        self.steps = planned.isEmpty ? [.finish] : planned
        self.onFinish = onFinish
    }

    var current: OnboardingStep { steps[min(index, steps.count - 1)] }
    var isFirst: Bool { index == 0 }
    var isLast: Bool { index >= steps.count - 1 }

    /// Progreso para el indicador: 1-based, como se cuenta en voz alta.
    var position: Int { index + 1 }
    var total: Int { steps.count }

    func advance() {
        guard !isLast else {
            finish()
            return
        }
        index += 1
    }

    func back() {
        guard !isFirst else { return }
        index -= 1
    }

    func finish() {
        onFinish()
    }
}
