import SwiftUI

/// Medidas del sistema visual nativo.
///
/// Deliberadamente **no** hay tokens de color: los colores los pone el sistema
/// (`Color.primary`, `.secondary`, `.accentColor`, los materiales). Una paleta
/// propia rompería el modo claro/oscuro automático, ignoraría el color de
/// acento que el usuario eligió y haría que la app se sintiera ajena a macOS,
/// que es justo lo contrario de lo que se busca.
public enum Metrics {
    // MARK: - Ventana

    /// Radio del panel. Coincide con el de las ventanas flotantes del sistema.
    public static let panelCornerRadius: CGFloat = 20
    public static let panelWidth: CGFloat = 780
    public static let panelHeight: CGFloat = 480

    /// Ventana de la presentación de primer uso.
    ///
    /// Más estrecha y más baja que el panel a propósito: aquí se lee un texto y se pulsa
    /// un botón, y una medida de línea larga en una ventana ancha es exactamente lo que
    /// hace que nadie lea la explicación del permiso.
    public static let onboardingWidth: CGFloat = 580
    public static let onboardingHeight: CGFloat = 480

    /// Ancho de la columna del historial. Ni tan estrecha que trunque toda
    /// línea, ni tan ancha que ahogue la vista previa.
    public static let listWidth: CGFloat = 336

    // MARK: - Piezas

    public static let rowCornerRadius: CGFloat = 9
    public static let cardCornerRadius: CGFloat = 12
    public static let chipCornerRadius: CGFloat = 5

    /// Alto de fila fijo: permite virtualizar sin medir cada celda, que es lo
    /// que mantiene el scroll estable con miles de entradas.
    public static let rowHeight: CGFloat = 48
    public static let searchHeight: CGFloat = 56
    public static let footerHeight: CGFloat = 32
    public static let metadataHeight: CGFloat = 28

    // MARK: - Ritmo

    /// Escala de espaciado en múltiplos de 2, la retícula de macOS.
    public enum Spacing {
        public static let hairline: CGFloat = 2
        public static let tight: CGFloat = 4
        public static let snug: CGFloat = 8
        public static let regular: CGFloat = 12
        public static let loose: CGFloat = 16
        public static let section: CGFloat = 24
    }

    /// Márgenes internos del panel. El contenido tiene que respirar dentro del
    /// cristal: pegado al canto, el material pierde su lectura de profundidad.
    public enum Inset {
        public static let panel: CGFloat = 18
        public static let list: CGFloat = 10
        public static let pane: CGFloat = 20
    }

    public enum IconSize {
        public static let row: CGFloat = 15
        public static let thumbnail: CGFloat = 30
        public static let search: CGFloat = 16
        public static let empty: CGFloat = 32
    }

    // MARK: - Tipografía

    /// Una escala corta y con saltos claros. Cuatro tamaños bastan para toda la
    /// app; más produce jerarquías que nadie percibe.
    public enum FontSize {
        public static let search: CGFloat = 19
        public static let title: CGFloat = 13
        public static let body: CGFloat = 13
        public static let caption: CGFloat = 11
        public static let micro: CGFloat = 10
    }
}

extension Animation {
    /// Transición corta y sin rebote. En una herramienta que se invoca cien
    /// veces al día, cualquier animación expresiva se convierte en espera.
    public static let ambarQuick = Animation.easeOut(duration: 0.12)
    public static let ambarSelection = Animation.easeOut(duration: 0.09)
}

extension ShapeStyle where Self == Color {
    /// Línea divisoria apenas perceptible. Los separadores fuertes trocean el
    /// panel; el trabajo de separar lo hacen el espacio y el material.
    public static var hairline: Color { Color.primary.opacity(0.08) }
}
