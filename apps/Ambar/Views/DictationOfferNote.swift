import GlassUI
import SwiftUI
import VoiceKit

/// Explica en Ajustes por qué el dictado no está listo, y qué hacer.
///
/// Existe porque la alternativa medida era peor: sin esto, quien no tuviera el
/// modelo de su idioma —el caso normal— activaba el dictado y obtenía un fallo
/// permanente, silencioso y sin ninguna forma de arreglarlo.
/// Qué nota corresponde a cada oferta.
///
/// Se decide fuera de la vista para poder afirmarlo en un test: la advertencia de
/// máquina justa estuvo calculada y propagada sin que ninguna vista la pintara, y un
/// `EmptyView` no se distingue de una decisión deliberada mirando el código de al
/// lado. Con esto, «la advertencia llega a la pantalla» es una aserción.
enum DictationNote: Equatable {
    /// No se afirma nada: todavía no se ha comprobado, o no hay nada que decir.
    case none
    case unavailable(UnavailableReason)
    /// Falta pedir el permiso del micrófono, y eso se resuelve con un botón.
    case needsPermission
    case needsModel
    case installing
    /// La máquina va justa: se ofrece, recomendando el modo diferido.
    case tight

    static func resolve(for offer: DictationOffer?) -> DictationNote {
        switch offer {
        case nil: .none
        case .some(.unavailable(let reason)): .unavailable(reason)
        case .some(.needsMicrophonePermission): .needsPermission
        case .some(.needsModel): .needsModel
        case .some(.installingModel): .installing
        case .some(.available(let tone, _)): tone == .warning ? .tight : .none
        }
    }
}

struct DictationOfferNote: View {
    let offer: DictationOffer?
    let model: AppModel

    @State private var progress: Double?

    var body: some View {
        switch DictationNote.resolve(for: offer) {
        case .none:
            // Aún no se ha comprobado, o no hay nada que decir.
            EmptyView()
        case .unavailable(let reason):
            HStack(spacing: 6) {
                Text(message(for: reason))
                if reason == .microphoneDenied, let url = MicrophoneAuthorization.settingsURL {
                    Button(String(localized: "dictation.open_settings", bundle: .localized)) {
                        NSWorkspace.shared.open(url)
                    }
                    .buttonStyle(.remedy)
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(Color.informational)

        case .needsPermission:
            HStack(spacing: 6) {
                Text(String(localized: "dictation.microphone_needed", bundle: .localized))
                Button(String(localized: "dictation.microphone.grant", bundle: .localized)) {
                    Task { await model.requestMicrophonePermission() }
                }
                .buttonStyle(.remedy)
                .disabled(model.isRequestingMicrophone)
            }
            .font(.system(size: 11))
            .foregroundStyle(Color.informational)

        case .needsModel:
            HStack(spacing: 6) {
                if let size = model.dictationModelSize {
                    Text(String(
                        format: String(localized: "dictation.model.needed_size", bundle: .localized),
                        size
                    ))
                } else {
                    Text(String(localized: "dictation.model.needed", bundle: .localized))
                }
                Button(String(localized: "dictation.model.install", bundle: .localized)) {
                    Task {
                        progress = 0
                        await model.installDictationModel { value in
                            Task { @MainActor in progress = value }
                        }
                        progress = nil
                    }
                }
                .buttonStyle(.remedy)
                if let progress {
                    ProgressView(value: progress).frame(width: 60)
                }
                if let error = model.dictationInstallError {
                    Text(error).foregroundStyle(Color.informationalStrong)
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(Color.informational)

        case .installing:
            Text(String(localized: "dictation.model.installing", bundle: .localized))
                .font(.system(size: 11))
                .foregroundStyle(Color.informational)

        case .tight:
            // El tono de advertencia era el único valor del tipo sin ningún consumidor:
            // se calculaba, se propagaba y no se pintaba. Y no es un adorno — es la
            // decisión de producto de §6.1: cuando la máquina va justa, el dictado se
            // ofrece **recomendando no usarlo en vivo**. Sin esto, esa recomendación no
            // llegaba a ninguna parte y la única diferencia entre una máquina holgada y
            // una justa era invisible.
            Text(String(localized: "dictation.tight", bundle: .localized))
                .font(.system(size: 11))
                .foregroundStyle(Color.informationalStrong)
        }
    }

    private func message(for reason: UnavailableReason) -> String {
        switch reason {
        case .localeUnsupported: String(localized: "dictation.unavailable.locale", bundle: .localized)
        case .noMicrophone: String(localized: "dictation.unavailable.no_mic", bundle: .localized)
        case .microphoneDenied: String(localized: "dictation.unavailable.denied", bundle: .localized)
        }
    }
}
