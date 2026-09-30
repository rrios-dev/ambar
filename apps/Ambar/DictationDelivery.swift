import ClipboardKit
import Foundation
import VoiceKit

/// Qué se hace con un dictado terminado.
///
/// Las tres decisiones se toman **una vez y juntas**, y no en el sitio donde se ejecuta
/// cada una. El motivo es un fallo medido: `concealed` se calculaba en el punto de
/// pegado, y escribir ahí `false` a mano no rompía ningún test —el texto dictado hacia
/// una app excluida se quedaba en el portapapeles en claro, así que cualquier otro
/// gestor instalado lo archivaba y la exclusión no servía de nada—.
///
/// Con el plan como valor, esa contradicción **deja de ser expresable**: ocultar y
/// archivar son la misma condición negada, y eso se afirma aquí una sola vez.
@MainActor
struct DictationDelivery: Equatable {
    let text: String
    /// Entra al historial de Ámbar.
    let archives: Bool
    /// Se marca como sensible en el portapapeles, para que ningún otro gestor lo guarde.
    let concealed: Bool
    /// Puede faltar texto y hay que decirlo (§7.2).
    let confessesTruncation: Bool

    /// `nil` cuando no hay nada que entregar.
    static func plan(
        transcript: Transcript,
        settings: Settings,
        targetBundleID: String?
    ) -> DictationDelivery? {
        // `transcript.isEmpty` y no `text.isEmpty`: recorta. Un dictado que solo trajo
        // espacios es «no se oyó nada», y el coordinador ya lo traduce a fallo por esa
        // misma vía — usar aquí la comprobación sin recortar dejaba los dos criterios
        // divergiendo, con un plan de entrega para un texto en blanco.
        guard !transcript.isEmpty else { return nil }
        let text = transcript.text
        let archives = AppModel.shouldArchive(
            settings: settings,
            targetBundleID: targetBundleID
        )
        return DictationDelivery(
            text: text,
            archives: archives,
            // La misma condición, negada. No es una coincidencia que se pueda relajar:
            // si Ámbar decide no guardar algo, dejarlo legible para el gestor de al lado
            // anula la decisión.
            concealed: !archives,
            confessesTruncation: transcript.wasTruncated
        )
    }
}
