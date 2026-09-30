import AppKit
import Observation
import SwiftUI

/// Ajustes de accesibilidad del sistema, observados en vivo.
///
/// Estos tres interruptores no son opcionales de atender. «Reducir
/// transparencia» lo activa gente para la que el texto sobre material
/// translúcido es ilegible; «Aumentar contraste», quien necesita bordes
/// definidos; «Reducir movimiento», quien sufre mareo con las animaciones. Una
/// app que ignora cualquiera de los tres deja fuera a usuarios reales, y no por
/// una limitación técnica sino por descuido.
///
/// Se observan en vivo porque se pueden cambiar con la app abierta.
@Observable
@MainActor
public final class AccessibilityPreferences {
    public static let shared = AccessibilityPreferences()

    public private(set) var reduceTransparency: Bool
    public private(set) var increaseContrast: Bool
    public private(set) var reduceMotion: Bool
    public private(set) var differentiateWithoutColor: Bool

    private var observer: NSObjectProtocol?

    private init() {
        let workspace = NSWorkspace.shared
        reduceTransparency = workspace.accessibilityDisplayShouldReduceTransparency
        increaseContrast = workspace.accessibilityDisplayShouldIncreaseContrast
        reduceMotion = workspace.accessibilityDisplayShouldReduceMotion
        differentiateWithoutColor = workspace.accessibilityDisplayShouldDifferentiateWithoutColor

        observer = NotificationCenter.default.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reload() }
        }
    }

    // Sin `deinit`: es un singleton que vive lo que vive el proceso, así que
    // nunca se destruye y dar de baja el observador sería código muerto que
    // además obligaría a saltarse el aislamiento del actor.

    private func reload() {
        let workspace = NSWorkspace.shared
        reduceTransparency = workspace.accessibilityDisplayShouldReduceTransparency
        increaseContrast = workspace.accessibilityDisplayShouldIncreaseContrast
        reduceMotion = workspace.accessibilityDisplayShouldReduceMotion
        differentiateWithoutColor = workspace.accessibilityDisplayShouldDifferentiateWithoutColor
    }

    /// Animación que respeta la preferencia del sistema.
    public func animation(_ base: Animation) -> Animation? {
        reduceMotion ? nil : base
    }

    /// Fuerza un estado para poder revisar la interfaz en los modos accesibles
    /// sin tocar los ajustes del sistema.
    ///
    /// Solo para revisión: en un arranque normal nadie llama a esto y los
    /// valores vienen siempre de `NSWorkspace`. Sin este resquicio, los modos
    /// de accesibilidad serían justo la parte del diseño que nunca se mira.
    public func overrideForReview(
        reduceTransparency: Bool? = nil,
        increaseContrast: Bool? = nil,
        reduceMotion: Bool? = nil,
        differentiateWithoutColor: Bool? = nil
    ) {
        if let reduceTransparency { self.reduceTransparency = reduceTransparency }
        if let increaseContrast { self.increaseContrast = increaseContrast }
        if let reduceMotion { self.reduceMotion = reduceMotion }
        if let differentiateWithoutColor {
            self.differentiateWithoutColor = differentiateWithoutColor
        }
    }
}
