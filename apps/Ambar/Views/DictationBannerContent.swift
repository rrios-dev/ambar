import Foundation
import VoiceKit

/// Todo lo que la banda del dictado **dice** en un estado dado.
///
/// El símbolo, el rótulo, qué controles se ofrecen, y lo que oye VoiceOver. Se decide aquí y
/// no en el cuerpo de la vista por una razón medida, no por gusto: una auditoría por mutación
/// encontró **poder de detección cero** en esta capa —borrar el botón de parar o cambiar el
/// gate que pinta la banda no rompía ningún test— y es donde vivieron las dos peores
/// regresiones del proyecto.
///
/// El intento anterior fue montar la vista en un `NSHostingView` e inspeccionar el árbol de
/// accesibilidad. **No funciona**: en un proceso de test ese árbol sale vacío —SwiftUI lo
/// construye cuando un cliente de accesibilidad lo pide—, así que las aserciones pasaban sin
/// mirar nada. Se descartó por eso, no por complejidad.
///
/// Lo que queda sin cubrir con este enfoque es solo la correspondencia uno a uno entre este
/// valor y los modificadores de SwiftUI. Todo lo demás —cada decisión— es afirmable.
@MainActor
struct DictationBannerContent: Equatable {
    /// Símbolo SF de la izquierda.
    let symbol: String
    /// Rótulo principal.
    let title: String
    /// Controles ofrecidos, en el orden en que se leen.
    let controls: [Control]
    /// Lo que VoiceOver anuncia como etiqueta del elemento.
    let accessibilityLabel: String
    /// Valor para VoiceOver: el avance de la cuenta, vacío si no aplica.
    let accessibilityValue: String
    /// El texto mostrado es todavía una hipótesis del motor.
    let liveTextIsVolatile: Bool

    enum Control: Equatable {
        /// Abre el panel del sistema donde se concede el micrófono.
        case openSystemSettings
        /// Abre los ajustes de Ámbar.
        case openAppSettings
        /// Cierra el aviso de fallo.
        case dismissFailure
        /// Tira lo dictado sin entregarlo.
        case discard
        /// Cierra el micrófono y entrega.
        case stop
    }

    static func resolve(
        state: DictationSessionState,
        liveText: String,
        liveTextIsVolatile: Bool,
        failure: DictationFailure?,
        hasSystemSettingsURL: Bool
    ) -> DictationBannerContent {
        let title = Self.title(for: state, failure: failure)
        return DictationBannerContent(
            symbol: Self.symbol(for: state),
            title: title,
            controls: Self.controls(
                for: state,
                failure: failure,
                hasSystemSettingsURL: hasSystemSettingsURL
            ),
            // El texto en vivo va en la etiqueta, no aparte: VoiceOver lee la etiqueta del
            // elemento, y un texto que solo está en un hijo no se locuta al recorrer.
            accessibilityLabel: liveText.isEmpty ? title : "\(title). \(liveText)",
            accessibilityValue: Self.progressValue(for: state),
            liveTextIsVolatile: liveTextIsVolatile
        )
    }

    static func symbol(for state: DictationSessionState) -> String {
        switch state {
        // `mic.slash` significa «micrófono silenciado» en el resto del sistema y se usa para
        // botones de silencio; aquí el estado es «todavía no abierto», así que se usa el
        // micrófono normal y lo que comunica el avance es el indicador de al lado.
        case .arming: "mic"
        case .preparing: "hourglass"
        case .listening: "mic.fill"
        case .finalizing: "ellipsis"
        case .idle, .delivered: "mic"
        case .failed: "exclamationmark.triangle"
        }
    }

    static func title(for state: DictationSessionState, failure: DictationFailure?) -> String {
        switch state {
        case .failed:
            // La causa, no el genérico. Se delega en el controlador para que la pantalla y
            // el anuncio de VoiceOver no puedan divergir: ya divergieron una vez.
            DictationController.message(for: failure ?? .engineFailed)
        case .arming:
            // **Siempre la instrucción**, aunque el modelo ya esté cargado. Con el modelo
            // caliente `prepare()` cuesta 4-5 ms, así que mostrar «Preparado para dictar»
            // era el caso NORMAL: sustituía lo único accionable —mantén— por una frase que
            // en español se lee como invitación a hablar, con el micrófono aún cerrado.
            String(localized: "dictation.state.arming", bundle: .localized)
        case .preparing:
            String(localized: "dictation.state.preparing", bundle: .localized)
        case .listening:
            String(localized: "dictation.state.listening", bundle: .localized)
        case .finalizing:
            String(localized: "dictation.state.finalizing", bundle: .localized)
        case .delivered(let transcript):
            // Una entrega recortada hay que confesarla también en pantalla, no solo a
            // VoiceOver: §7.2 dice «se pega lo que haya **y se dice**».
            transcript.wasTruncated
                ? String(localized: "dictation.state.truncated", bundle: .localized)
                : String(localized: "dictation.state.delivered", bundle: .localized)
        case .idle:
            ""
        }
    }

    static func controls(
        for state: DictationSessionState,
        failure: DictationFailure?,
        hasSystemSettingsURL: Bool
    ) -> [Control] {
        var controls: [Control] = []
        if case .failed = state {
            switch failure {
            case .permissionDenied where hasSystemSettingsURL:
                controls.append(.openSystemSettings)
            case .modelUnavailable:
                // Los fallos con arreglo tienen que ofrecerlo. El del cupo lleno **no**
                // está aquí a propósito: su remedio no vive en Ajustes de Ámbar —son los
                // cinco idiomas reservados de todo el sistema— y un botón que lleva a una
                // pantalla donde no se puede resolver es peor que ningún botón.
                controls.append(.openAppSettings)
            default:
                break
            }
            controls.append(.dismissFailure)
        }
        if state.isActive {
            controls.append(.discard)
        }
        if DictationEntryPoints.showsStopControl(for: state) {
            // La única salida visible cuando el gesto no puede terminar: una tecla
            // enclavada por Teclas Especiales, o un teclado que reporta un modificador
            // hundido.
            controls.append(.stop)
        }
        return controls
    }

    /// El avance de la cuenta, formateado. Vacío fuera de la cuenta.
    ///
    /// El indicador visual va `accessibilityHidden` en sus dos representaciones, así que sin
    /// esto el umbral simplemente no existe para quien no ve la pantalla: no hay forma de
    /// saber cuánto queda para que se abra el micrófono, ni por tanto de decidir soltar.
    static func progressValue(for state: DictationSessionState) -> String {
        guard case .arming(let progress, _) = state else { return "" }
        // Con `FormatStyle`, no a mano: el espacio antes del % es convención es/fr y en
        // inglés, japonés, chino o coreano se escribe pegado.
        return progress.formatted(.percent.precision(.fractionLength(0)))
    }
}
