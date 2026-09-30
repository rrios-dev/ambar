import AppKit
import SwiftUI

/// Estilos de texto con contraste garantizado.
///
/// Los estilos jerárquicos de SwiftUI (`.secondary`, `.tertiary`) están
/// pensados para crear jerarquía visual, no para cumplir un mínimo de
/// contraste, y medidos contra el fondo del panel **no llegan** al 4,5:1 que
/// WCAG 2.1 exige para texto pequeño:
///
/// | estilo       | oscuro | claro | alto contraste |
/// |--------------|--------|-------|----------------|
/// | `.secondary` | 5,89   | 3,95  | 3,82           |
/// | `.tertiary`  | 2,26   | 1,88  | 1,80           |
///
/// Contraintuitivo pero medido: activar «Aumentar contraste» los *empeora*.
///
/// **Tres columnas, no cuatro.** La tabla tenía una cuarta —«osc+contraste»— con los mismos
/// números que la tercera, y no era una coincidencia: en macOS 26,
/// `AccessibilityHighContrastDarkAqua` resuelve a la **misma paleta** que su versión clara,
/// así que era la misma medición escrita dos veces. Presentarla como dos medidas
/// independientes daba una confianza que no existía; la combinación oscuro + alto contraste
/// hoy no se puede medir, y eso está afirmado en `AppearancePaletteTests`.
///
/// La alternativa es componer sobre `labelColor` —que sí es dinámico y sigue al sistema—
/// con la opacidad justa.
///
/// **Ojo con «la opacidad justa»**: `Color(nsColor:).opacity(_:)` **multiplica** por el alfa
/// que `labelColor` ya trae (0,847), así que la constante es un factor y no el alfa final.
/// La versión anterior de esta frase decía «con 0,60 el peor caso es 5,46:1» y estaba medida
/// con `withAlphaComponent`, que sustituye: lo que se dibujaba era 0,508 de alfa y **4,09:1
/// en apariencia clara**, por debajo de AA. Los factores de `Opacity` están ahora elegidos
/// para que el alfa **dibujado** sea el pretendido, y `RenderedAlphaTests` lo compara alfa
/// contra alfa.
extension Color {
    /// Texto informativo pequeño: subtítulos de fila, metadatos, pie.
    ///
    /// Cumple AA en las cuatro apariencias y mantiene la jerarquía frente al
    /// texto principal, que va a opacidad plena.
    /// Opacidades reales de los tokens de texto, expuestas para que los tests de
    /// contraste midan **esto** y no una copia.
    ///
    /// Los tests tenían sus propias constantes replicando estos valores, así que bajar
    /// el real a 0,25 no rompía nada: medían una réplica fiel de algo que ya no existía.
    /// Estas opacidades **se multiplican** por el alfa que ya trae `labelColor` (0,847
    /// medido), porque así es como compone `Color(nsColor:).opacity(_:)`. No son el alfa
    /// final: son el factor.
    ///
    /// Estuvieron puestas como si fueran el alfa final —0,60 «para un 60 %»— y el resultado
    /// dibujado era 0,508: **4,09:1 en apariencia clara**, por debajo de AA, mientras el test
    /// las medía con `withAlphaComponent`, que sustituye en vez de multiplicar, y salía
    /// 5,74:1. El test certificaba un color que la app no dibujaba jamás.
    ///
    /// Los valores de ahora están elegidos para que el **alfa dibujado** sea el que se
    /// pretendía, y hay un test que compara alfa contra alfa para que la trampa no vuelva
    /// en silencio.
    public enum Opacity {
        /// ×0,847 ≈ 0,60 dibujado.
        public static let informational = 0.71
        /// ×0,847 ≈ 0,75 dibujado.
        public static let informationalStrong = 0.885
        /// Con «Aumentar contraste» ambos suben: es la rama que nunca se medía.
        /// ×0,847 ≈ 0,80 dibujado.
        public static let informationalHighContrast = 0.95
        /// Opacidad plena del token: ×0,847 = 0,847 dibujado.
        public static let informationalStrongHighContrast = 1.0

        /// Carril de un indicador de progreso — WCAG 1.4.11, 3:1 no textual, no el 4,5:1
        /// de los de arriba. Peor caso medido: 3,43:1.
        public static let trackFill = 0.55
        /// Peor caso medido: 5,32:1.
        public static let trackFillHighContrast = 0.70

        /// Subtítulo de una fila **seleccionada**, sobre el fondo de selección del sistema.
        ///
        /// Estaba en 0,75 y medía 3,69:1 en claro, 4,21:1 en oscuro y **2,89:1 con
        /// «Aumentar contraste»** — los tres por debajo del 4,5:1 que este módulo se
        /// exige, en un elemento que está permanentemente en pantalla: siempre hay
        /// exactamente una fila seleccionada, y es la que el usuario va a pegar.
        ///
        /// 0,90 deja 4,64:1 en claro y 5,38:1 en oscuro. No se sube más porque atenuar
        /// **algo** es lo que distingue el subtítulo del título; el objetivo era quitar la
        /// degradación autoinfligida, no la jerarquía.
        public static let selectedSecondary = 0.90

        /// Con «Aumentar contraste», sin atenuar en absoluto.
        ///
        /// Y aquí hay un techo que no es nuestro: `alternateSelectedControlTextColor`
        /// sobre `selectedContentBackgroundColor` mide **4,02:1 a opacidad plena** en esa
        /// apariencia. Es el par de colores de selección del propio sistema, y no se puede
        /// mejorar sin sustituirlos —lo que haría que la selección dejara de parecerse a
        /// la del resto de macOS—. Lo que sí se puede es no empeorarlo, que es lo que
        /// hacía el 0,75.
        public static let selectedSecondaryHighContrast = 1.0

        /// Capa sobre la que se lee la banda de dictado.
        ///
        /// Escala con «Aumentar contraste»: con ese ajuste activo, una opacidad fija dejaba
        /// la banda casi indistinguible del panel, justo para quien pidió más bordes.
        ///
        /// Vive aquí, con sus hermanas, y no como literal dentro del `.background` de la
        /// banda, por un motivo medido: mientras fue un literal, el test de contraste
        /// replicaba los valores por su cuenta y no protegía nada — cambiar los de la
        /// banda a 0,55/0,60 dejaba las 480 pruebas en verde con el contraste real caído a
        /// **1,95:1** en modo oscuro. Es exactamente el fallo de método que la cabecera de
        /// este fichero documenta —medir una copia fiel de algo que ya no existe—, cometido
        /// dentro del test escrito para cazarlo.
        public static let bannerLayer = 0.06
        /// Peor caso medido con esta capa: 8,78:1.
        public static let bannerLayerHighContrast = 0.14

        /// La opacidad que la banda usa, según el ajuste. Un solo sitio donde decidirlo.
        public static func bannerLayer(increaseContrast: Bool) -> Double {
            increaseContrast ? bannerLayerHighContrast : bannerLayer
        }
    }

    @MainActor public static var informational: Color {
        Color(nsColor: .labelColor)
            .opacity(
                AccessibilityPreferences.shared.increaseContrast
                    ? Opacity.informationalHighContrast
                    : Opacity.informational
            )
    }

    /// Contenido secundario legible en bloque, como el texto reconocido de una
    /// imagen. Más contraste que `informational` porque se lee, no se ojea.
    @MainActor public static var informationalStrong: Color {
        Color(nsColor: .labelColor)
            .opacity(
                AccessibilityPreferences.shared.increaseContrast
                    ? Opacity.informationalStrongHighContrast
                    : Opacity.informationalStrong
            )
    }

    /// Elementos decorativos sin carga informativa: iconos de estado vacío,
    /// marcos, separadores. No les aplica el mínimo de contraste porque no
    /// transportan información que haya que leer.
    /// Carril de un indicador de progreso: tiene que verse **como fondo**, no como
    /// texto, pero sigue siendo un componente de interfaz —WCAG 2.1 §1.4.11, 3:1 mínimo
    /// contra el fondo, no el 4,5:1 de texto— y no un adorno puro.
    ///
    /// A 0,18 medía 1,41–1,63:1 en el peor caso (apariencia clara): por debajo del
    /// mínimo, y sin ningún test que lo protegiera. 0,55 da margen sobre 3:1 en las
    /// cuatro apariencias (peor caso medido: 3,43:1); 0,70 con «Aumentar contraste»
    /// mantiene la escalada — sigue siendo más visible que el estado normal, no solo
    /// «ya cumple» — sobre el mismo peor caso (5,32:1).
    @MainActor public static var trackFill: Color {
        Color(nsColor: .labelColor)
            .opacity(
                AccessibilityPreferences.shared.increaseContrast
                    ? Opacity.trackFillHighContrast
                    : Opacity.trackFill
            )
    }

    public static var decorative: Color {
        Color(nsColor: .labelColor).opacity(0.25)
    }
}
