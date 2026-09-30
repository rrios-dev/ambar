import Testing

@testable import GlassUI

/// `animation(_:)` es lo que de verdad gatea la animación en el punto de uso real
/// (`ContentView.swift`, `.animation(AccessibilityPreferences.shared.animation(...), value:)`).
/// `DictationBannerTransition.kind(reduceMotion:)` prueba la ELECCIÓN de transición, pero
/// nadie probaba que el modificador de animación de SwiftUI en sí respetara la
/// preferencia: invertir el ternario de `animation(_:)` no rompía ningún test de los 438,
/// hallazgo de la auditoría de cierre (F6, pasada 1).
@Suite("La animación respeta Reducir Movimiento", .serialized)
@MainActor
struct AccessibilityPreferencesAnimationTests {

    @Test("con Reducir Movimiento activo, no hay animación")
    func reduceMotionSuppressesAnimation() {
        let preferences = AccessibilityPreferences.shared
        let before = preferences.reduceMotion
        defer { preferences.overrideForReview(reduceMotion: before) }

        preferences.overrideForReview(reduceMotion: true)
        #expect(
            preferences.animation(.easeInOut) == nil,
            "con Reducir Movimiento activo, animation(_:) devolvió una animación"
        )
    }

    @Test("sin Reducir Movimiento, la animación pasa tal cual")
    func normalMotionKeepsTheAnimation() {
        let preferences = AccessibilityPreferences.shared
        let before = preferences.reduceMotion
        defer { preferences.overrideForReview(reduceMotion: before) }

        preferences.overrideForReview(reduceMotion: false)
        #expect(
            preferences.animation(.easeInOut) != nil,
            "sin Reducir Movimiento, animation(_:) suprimió la animación"
        )
    }
}
