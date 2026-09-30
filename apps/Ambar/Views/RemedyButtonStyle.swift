import GlassUI
import SwiftUI

/// Estilo de los controles que **resuelven** un fallo: «Abrir Ajustes», «Instalar»,
/// «Reanudar».
///
/// No usan `.link` por una razón medida, no estética: `linkColor` da 3,90:1 sobre el
/// panel con «Aumentar contraste» activado, y `controlAccentColor` 2,98:1 — por
/// debajo del 4,5:1 que exige AA para texto pequeño. Es el mismo patrón que la
/// auditoría de 2026-08-09 midió para `.secondary`: los colores del sistema **empeoran**
/// con ese ajuste. Y caía justo sobre el único control que arregla el fallo, para quien
/// más lo necesita.
struct RemedyButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(Color.informationalStrong)
            .underline()
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

extension ButtonStyle where Self == RemedyButtonStyle {
    /// Ver `RemedyButtonStyle`: sustituye a `.link`, que no cumple contraste.
    static var remedy: RemedyButtonStyle { RemedyButtonStyle() }
}
