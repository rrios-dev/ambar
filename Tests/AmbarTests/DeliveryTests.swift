import AppCore
import ClipboardKit
import Foundation
import Testing
import VoiceKit

@testable import Ambar

/// La entrega de lo dictado: historial, pausa y apps excluidas.
///
/// Existe porque una mutación del auditor revirtió tres arreglos a la vez —dictar
/// dentro de un gestor de contraseñas volvía a guardarse en el historial, la pausa
/// dejaba de respetarse y cada dictado dejaba dos entradas— y la suite siguió verde.
/// Ninguno de los tres estaba cubierto por nada.
@Suite("Entrega de lo dictado")
@MainActor
struct DeliveryTests {

    /// Ajustes sobre un dominio efímero: no toca las preferencias reales.
    static func makeSettings() -> Settings {
        let suite = "dev.rrios.ambar.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        return Settings(defaults: defaults)
    }

    @Test("la pausa impide archivar, pero no impide dictar")
    func pauseBlocksArchivingOnly() {
        let settings = Self.makeSettings()
        settings.pauseCapture(.fifteenMinutes)

        #expect(settings.isPaused, "la pausa no quedó activa")
        // La regla del producto: en pausa el dictado sigue funcionando —transcribe y
        // pega— pero no deja rastro. Lo que se comprueba aquí es la condición que
        // gobierna el archivado.
        #expect(!settings.pause!.isIndefinite)
        settings.resumeCapture()
        #expect(!settings.isPaused)
    }

    @Test("las apps excluidas de fábrica cubren los gestores de contraseñas")
    func passwordManagersAreExcludedByDefault() {
        let settings = Self.makeSettings()
        // Es la lista que decide si un dictado se archiva. Si alguien la vacía, el
        // texto dictado dentro de 1Password acaba en el historial.
        for bundle in ["com.1password.1password", "com.apple.keychainaccess"] {
            #expect(
                settings.excludedBundleIDs.contains(bundle),
                "\(bundle) debería venir excluido de fábrica"
            )
        }
    }

    @Test("el modo propuesto se aplica mientras el usuario no elija")
    func suggestedModeAppliesUntilUserChooses() {
        let settings = Self.makeSettings()
        // Sin medición se propone el diferido, que funciona en cualquier máquina.
        settings.applySuggestedDictationMode(.deferred)
        #expect(settings.dictationMode == .deferred)
        #expect(!settings.hasChosenDictationMode)

        // En cuanto el usuario elige, la recomendación deja de pisar su decisión.
        settings.dictationMode = .live
        #expect(settings.hasChosenDictationMode)
        settings.applySuggestedDictationMode(.deferred)
        #expect(settings.dictationMode == .live, "la recomendación pisó la elección del usuario")
    }

    /// El test que faltaba: la decisión real de archivar, no solo los ajustes.
    ///
    /// El auditor mutó `if !settings.isPaused, !excluded` a `if true` y los 20 tests
    /// siguieron verdes: la suite decía cubrir «historial, pausa y apps excluidas» y
    /// solo ejercitaba `Settings`. Esto llama a la condición real.
    @Test("la condición de archivado respeta la pausa y las apps excluidas")
    func archivingConditionHonoursPauseAndExclusions() {
        let settings = Self.makeSettings()

        // Caso normal: se archiva.
        #expect(AppModel.shouldArchive(settings: settings, targetBundleID: "com.apple.TextEdit"))

        // En pausa no se archiva, aunque el destino sea inocuo.
        settings.pauseCapture(.fifteenMinutes)
        #expect(!AppModel.shouldArchive(settings: settings, targetBundleID: "com.apple.TextEdit"))
        settings.resumeCapture()

        // Destino excluido: no se archiva ni con la captura activa.
        #expect(!AppModel.shouldArchive(settings: settings, targetBundleID: "com.1password.1password"))

        // Destino desconocido: se elige el lado que NO deja rastro.
        #expect(!AppModel.shouldArchive(settings: settings, targetBundleID: nil))
    }

    /// La mitigación de Teclas Especiales era código muerto: `object(forKey:)` nunca
    /// devuelve nil una vez registrado el valor por defecto, así que el `if` que la
    /// aplicaba no se cumplía jamás.
    @Test("con Teclas Especiales el disparo por gesto nace desactivado")
    func holdGestureIsOffWithStickyKeys() {
        let previous = StickyKeys.reader
        defer { StickyKeys.reader = previous }

        StickyKeys.reader = { true }
        let withSticky = Self.makeSettings()
        #expect(
            !withSticky.isHoldGestureEnabled,
            "con los modificadores enclavados el gesto abriría el micrófono en cada apertura del panel"
        )

        StickyKeys.reader = { false }
        let withoutSticky = Self.makeSettings()
        #expect(withoutSticky.isHoldGestureEnabled, "sin Teclas Especiales el gesto debe venir activo")
    }

    @Test("la huella de un dictado es estable entre arranques")
    func dictationFingerprintIsStable() {
        // Con `hashValue` la deduplicación dejaba de funcionar tras reiniciar, porque
        // el hash de String está sembrado por proceso. Se comprueba que la huella
        // depende solo del texto.
        let first = AppModel.stableFingerprint(of: "hola mundo")
        let second = AppModel.stableFingerprint(of: "hola mundo")
        let other = AppModel.stableFingerprint(of: "hola mundos")

        #expect(first == second)
        #expect(first != other)
        #expect(first.count == 64, "no parece un SHA-256 en hexadecimal: \(first)")
    }
}
