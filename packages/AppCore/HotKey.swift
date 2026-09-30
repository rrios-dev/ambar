import AppKit
import Carbon.HIToolbox

/// Combinación de teclas global.
public struct KeyCombination: Sendable, Equatable, Codable {
    public var keyCode: UInt32
    public var modifiers: UInt32

    public init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// ⌘⇧V — el atajo de referencia entre gestores de portapapeles, y el que
    /// usa la herramienta que Ámbar sustituye.
    public static let commandShiftV = KeyCombination(
        keyCode: UInt32(kVK_ANSI_V),
        modifiers: UInt32(cmdKey | shiftKey)
    )

    /// Representación legible para la interfaz de ajustes.
    public var displayString: String {
        var result = ""
        if modifiers & UInt32(controlKey) != 0 { result += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { result += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { result += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { result += "⌘" }
        result += Self.keyName(for: keyCode)
        return result
    }

    /// Nombre visible de la tecla.
    ///
    /// Se cubren letras, dígitos, teclas de función y las especiales que la
    /// gente usa de verdad en atajos. Antes solo había letras, y cualquier otra
    /// combinación se mostraba como «?» — inservible en un campo donde el
    /// usuario tiene que reconocer lo que acaba de pulsar.
    private static func keyName(for keyCode: UInt32) -> String {
        let letters: [Int: String] = [
            kVK_ANSI_A: "A", kVK_ANSI_B: "B", kVK_ANSI_C: "C", kVK_ANSI_D: "D",
            kVK_ANSI_E: "E", kVK_ANSI_F: "F", kVK_ANSI_G: "G", kVK_ANSI_H: "H",
            kVK_ANSI_I: "I", kVK_ANSI_J: "J", kVK_ANSI_K: "K", kVK_ANSI_L: "L",
            kVK_ANSI_M: "M", kVK_ANSI_N: "N", kVK_ANSI_O: "O", kVK_ANSI_P: "P",
            kVK_ANSI_Q: "Q", kVK_ANSI_R: "R", kVK_ANSI_S: "S", kVK_ANSI_T: "T",
            kVK_ANSI_U: "U", kVK_ANSI_V: "V", kVK_ANSI_W: "W", kVK_ANSI_X: "X",
            kVK_ANSI_Y: "Y", kVK_ANSI_Z: "Z",
        ]
        let digits: [Int: String] = [
            kVK_ANSI_0: "0", kVK_ANSI_1: "1", kVK_ANSI_2: "2", kVK_ANSI_3: "3",
            kVK_ANSI_4: "4", kVK_ANSI_5: "5", kVK_ANSI_6: "6", kVK_ANSI_7: "7",
            kVK_ANSI_8: "8", kVK_ANSI_9: "9",
        ]
        // Símbolos de las flechas y teclas de edición tal y como los escribe
        // Apple en sus propios menús.
        let special: [Int: String] = [
            kVK_Space: "␣", kVK_Return: "↩", kVK_Tab: "⇥", kVK_Delete: "⌫",
            kVK_ForwardDelete: "⌦", kVK_Escape: "⎋", kVK_LeftArrow: "←",
            kVK_RightArrow: "→", kVK_UpArrow: "↑", kVK_DownArrow: "↓",
            kVK_Home: "↖", kVK_End: "↘", kVK_PageUp: "⇞", kVK_PageDown: "⇟",
            kVK_ANSI_Minus: "-", kVK_ANSI_Equal: "=", kVK_ANSI_Slash: "/",
            kVK_ANSI_Backslash: "\\", kVK_ANSI_Comma: ",", kVK_ANSI_Period: ".",
            kVK_ANSI_Semicolon: ";", kVK_ANSI_Quote: "'",
            kVK_ANSI_LeftBracket: "[", kVK_ANSI_RightBracket: "]",
        ]
        let functionKeys: [Int: String] = [
            kVK_F1: "F1", kVK_F2: "F2", kVK_F3: "F3", kVK_F4: "F4",
            kVK_F5: "F5", kVK_F6: "F6", kVK_F7: "F7", kVK_F8: "F8",
            kVK_F9: "F9", kVK_F10: "F10", kVK_F11: "F11", kVK_F12: "F12",
        ]

        let code = Int(keyCode)
        return letters[code] ?? digits[code] ?? special[code] ?? functionKeys[code]
            ?? "#\(code)"
    }
}

/// Registro de atajos globales mediante Carbon.
///
/// `RegisterEventHotKey` es API vieja pero es la correcta aquí: a diferencia de
/// `CGEventTap` o de los monitores globales de `NSEvent`, **no requiere permiso
/// de accesibilidad**. Que la app pueda invocarse desde el primer arranque, sin
/// mandar al usuario a Ajustes del Sistema, justifica de sobra usar Carbon.
@MainActor
public final class HotKeyCenter {
    public static let shared = HotKeyCenter()

    private var registrations:
        [UInt32: (ref: EventHotKeyRef?, action: () -> Void, onRelease: (() -> Void)?)] = [:]
    private var nextID: UInt32 = 1
    private var eventHandler: EventHandlerRef?

    private init() {}

    /// Registra la combinación y devuelve un identificador para darla de baja.
    ///
    /// - Parameter onRelease: se llama al **soltar** el atajo. Carbon lo entrega por el
    ///   mismo canal que la pulsación (`kEventHotKeyReleased`, «A registered hot key was
    ///   released»), así que no cuesta ningún permiso más de los que ya se tienen.
    ///
    ///   Existe porque el gesto de mantener vigila **solo los modificadores**
    ///   (`HoldGesture.watchedFlags`): con ⇧⌘V, soltar la V y quedarse con ⇧⌘ dejaba la
    ///   cuenta viva y abría el micrófono a los 550 ms sin que nadie estuviera manteniendo
    ///   el atajo. Vigilar la tecla por hardware (`CGEventSourceKeyState`) resolvería lo
    ///   mismo, pero con un riesgo peor: si a alguien le devolviera `false`, el dictado no
    ///   se dispararía **nunca**, en silencio. Esto es aditivo — si el evento no llega, el
    ///   comportamiento es el de antes.
    @discardableResult
    public func register(
        _ combination: KeyCombination,
        action: @escaping () -> Void,
        onRelease: (() -> Void)? = nil
    ) -> UInt32? {
        installHandlerIfNeeded()

        let identifier = nextID
        nextID += 1

        let hotKeyID = EventHotKeyID(signature: ambarHotKeySignature, id: identifier)
        var reference: EventHotKeyRef?

        let status = RegisterEventHotKey(
            combination.keyCode,
            combination.modifiers,
            hotKeyID,
            GetEventDispatcherTarget(),
            0,
            &reference
        )

        guard status == noErr else { return nil }

        registrations[identifier] = (reference, action, onRelease)
        return identifier
    }

    public func unregister(_ identifier: UInt32) {
        guard let registration = registrations.removeValue(forKey: identifier) else { return }
        if let reference = registration.ref {
            UnregisterEventHotKey(reference)
        }
    }

    public func unregisterAll() {
        for identifier in registrations.keys { unregister(identifier) }
    }

    fileprivate func handle(identifier: UInt32) {
        registrations[identifier]?.action()
    }

    fileprivate func handleRelease(identifier: UInt32) {
        registrations[identifier]?.onRelease?()
    }

    /// Invoca la baja del atajo como si Carbon la hubiera entregado.
    ///
    /// Los eventos de Carbon no se pueden sintetizar desde `swift test` —no hay sesión
    /// gráfica ni despachador—, así que sin esta puerta el reparto de «soltar» quedaría
    /// estructuralmente fuera del alcance de cualquier test: borrar `handleRelease` no
    /// rompería nada. Ejercita el mismo método que ejecuta el puente de Carbon, no una copia.
    public func simulateReleaseForTesting(identifier: UInt32) {
        handleRelease(identifier: identifier)
    }

    private func installHandlerIfNeeded() {
        guard eventHandler == nil else { return }

        // Los dos géneros por el mismo canal. `kEventHotKeyReleased` es el que permite
        // distinguir «sigue manteniendo el atajo» de «soltó la tecla y dejó puestos los
        // modificadores», que a ojos de `NSEvent.modifierFlags` son idénticos.
        var eventTypes = [
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyPressed)
            ),
            EventTypeSpec(
                eventClass: OSType(kEventClassKeyboard),
                eventKind: UInt32(kEventHotKeyReleased)
            ),
        ]

        InstallEventHandler(
            GetEventDispatcherTarget(),
            hotKeyEventHandler,
            eventTypes.count,
            &eventTypes,
            nil,
            &eventHandler
        )
    }

}

/// Firma de cuatro caracteres ('ambr') que identifica los atajos de esta app
/// frente a los de cualquier otra en el mismo despachador. Vive fuera de la
/// clase porque el puente de Carbon la lee desde un contexto no aislado.
private let ambarHotKeySignature: OSType = {
    Array("ambr".utf8).reduce(OSType(0)) { ($0 << 8) | OSType($1) }
}()

/// Puente C → Swift. Carbon exige un puntero a función sin contexto capturado,
/// así que el despacho pasa por el singleton.
private let hotKeyEventHandler: EventHandlerUPP = { _, event, _ -> OSStatus in
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )

    guard status == noErr, hotKeyID.signature == ambarHotKeySignature else {
        return OSStatus(eventNotHandledErr)
    }

    let identifier = hotKeyID.id
    let isRelease = GetEventKind(event) == UInt32(kEventHotKeyReleased)
    // El handler de Carbon ya llega en el hilo principal, pero el compilador no
    // puede saberlo: se afirma explícitamente en vez de saltar a otro turno del
    // run loop, que introduciría latencia justo en la pulsación del atajo.
    MainActor.assumeIsolated {
        if isRelease {
            HotKeyCenter.shared.handleRelease(identifier: identifier)
        } else {
            HotKeyCenter.shared.handle(identifier: identifier)
        }
    }
    return noErr
}
