import AppKit
import Carbon.HIToolbox
import SwiftUI

/// Campo que captura una combinación de teclas.
///
/// Existe porque ⌘⇧V, el atajo por omisión, colisiona con «Pegar y ajustar al
/// estilo» en Pages, Keynote y Word. Sin forma de cambiarlo, un usuario de esas
/// apps se queda sin salida.
public struct ShortcutRecorder: View {
    @Binding var combination: KeyCombination
    @State private var isRecording = false
    @State private var rejected: String?

    public init(combination: Binding<KeyCombination>) {
        self._combination = combination
    }

    public var body: some View {
        HStack(spacing: 8) {
            Button {
                isRecording.toggle()
                rejected = nil
            } label: {
                Text(isRecording ? String(localized: "shortcut.recording", bundle: .localized)
                                 : combination.displayString)
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .frame(minWidth: 62)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .fill(isRecording ? Color.accentColor.opacity(0.22)
                                              : Color.primary.opacity(0.07))
                    )
                    .overlay {
                        if isRecording {
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .strokeBorder(Color.accentColor, lineWidth: 1.5)
                        }
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "a11y.shortcut.label", bundle: .localized))
            .accessibilityValue(combination.displayString)
            .accessibilityHint(String(localized: "a11y.shortcut.hint", bundle: .localized))

            if let rejected {
                // Dos arreglos en una línea, ambos de la auditoría de cierre.
                //
                // El naranja medía **1,86:1** contra el fondo de Ajustes. No llega al 4,5:1
                // que WCAG pide para texto, ni siquiera al 3:1 de los elementos no
                // textuales: el único aviso de que el atajo no vale era ilegible para
                // quien peor ve. El color del sistema para etiquetas cumple AA por
                // construcción, y es lo que se usa ahora.
                //
                // Y el aviso no puede ser **solo** color (WCAG 1.4.1): el símbolo lo dice
                // sin depender de verlo, que además es lo que lo hace legible en escala de
                // grises y para quien no distingue el naranja del gris.
                Label(rejected, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.primary)
                    // Sin esto VoiceOver leía el símbolo y el texto como dos elementos
                    // sueltos, y el usuario tenía que buscar el segundo para enterarse de
                    // por qué no se aceptó su atajo.
                    .accessibilityElement(children: .combine)
            }
        }
        .background(
            KeyCaptureView(isRecording: $isRecording) { captured in
                switch validate(captured) {
                case .accepted:
                    combination = captured
                    isRecording = false
                    rejected = nil
                case .rejected(let reason):
                    rejected = reason
                }
            }
        )
        // El rechazo aparecía en pantalla y en ningún otro sitio. Con VoiceOver, quien
        // acababa de pulsar una combinación se quedaba esperando una respuesta que nunca
        // llegaba: el foco sigue en el botón, y el texto nuevo aparece **debajo**, fuera
        // del recorrido. Anunciarlo es lo que convierte «no pasó nada» en «no vale, y por
        // esto». Prioridad alta porque es la respuesta directa a una acción del usuario.
        .onChange(of: rejected) { _, reason in
            guard let reason else { return }
            var announcement = AttributedString(reason)
            announcement.accessibilitySpeechAnnouncementPriority = .high
            AccessibilityNotification.Announcement(announcement).post()
        }
    }

    private enum Validation {
        case accepted
        case rejected(String)
    }

    /// Un atajo global sin modificadores secuestraría esa tecla en todo el
    /// sistema: pulsar «V» dejaría de escribir una uve en cualquier app.
    private func validate(_ candidate: KeyCombination) -> Validation {
        let hasModifier = candidate.modifiers & UInt32(cmdKey | controlKey | optionKey) != 0
        guard hasModifier else {
            return .rejected(String(localized: "shortcut.needs_modifier", bundle: .localized))
        }
        return .accepted
    }
}

/// Puente a AppKit para leer el siguiente `keyDown`.
///
/// SwiftUI no expone los códigos de tecla virtuales que Carbon necesita para
/// registrar el atajo, así que la captura se hace con un monitor local.
private struct KeyCaptureView: NSViewRepresentable {
    @Binding var isRecording: Bool
    let onCapture: (KeyCombination) -> Void

    func makeNSView(context: Context) -> NSView {
        context.coordinator.onCapture = onCapture
        return NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onCapture = onCapture
        context.coordinator.setRecording(isRecording)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    @MainActor
    final class Coordinator {
        var onCapture: ((KeyCombination) -> Void)?
        /// `nonisolated(unsafe)` para poder retirarlo desde `deinit`, que nunca
        /// es aislado al actor. Solo se toca desde el hilo principal: la clase
        /// entera es `@MainActor`.
        private nonisolated(unsafe) var monitor: Any?

        func setRecording(_ recording: Bool) {
            if recording, monitor == nil {
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                    // Escape cancela sin cambiar nada.
                    guard event.keyCode != 53 else {
                        self?.stop()
                        return nil
                    }
                    self?.onCapture?(KeyCombination(carbonFrom: event))
                    // Devolver nil impide que la pulsación llegue a la interfaz
                    // y active un botón mientras se está grabando.
                    return nil
                }
            } else if !recording {
                stop()
            }
        }

        private func stop() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }

        deinit {
            // `removeMonitor` es seguro desde cualquier hilo y el objeto ya no
            // se usa; sin esto quedaría un monitor global huérfano.
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}

extension KeyCombination {
    /// Traduce un evento de AppKit a los códigos que espera Carbon.
    ///
    /// Son dos vocabularios distintos: `NSEvent.ModifierFlags` es una máscara
    /// de bits propia y `RegisterEventHotKey` espera las constantes clásicas
    /// (`cmdKey`, `shiftKey`…). Sin esta conversión el atajo se registra con
    /// modificadores equivocados y nunca dispara.
    init(carbonFrom event: NSEvent) {
        var carbon: UInt32 = 0
        let flags = event.modifierFlags
        if flags.contains(.command) { carbon |= UInt32(cmdKey) }
        if flags.contains(.shift) { carbon |= UInt32(shiftKey) }
        if flags.contains(.option) { carbon |= UInt32(optionKey) }
        if flags.contains(.control) { carbon |= UInt32(controlKey) }

        self.init(keyCode: UInt32(event.keyCode), modifiers: carbon)
    }
}
