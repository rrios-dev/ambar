import Foundation

/// Techos de tamaño para lo que entra en el historial.
///
/// Sin ellos, copiar un volcado de log de varios cientos de megas o una imagen
/// de cien megapíxeles obliga a la app a sostener todo eso en memoria, escribirlo
/// a disco y —lo peor— intentar dibujarlo en la vista previa. Un `Text` de
/// SwiftUI con cinco millones de caracteres no se degrada: se para.
///
/// Los valores son deliberadamente generosos. No están para racionar el
/// historial, sino para atajar el accidente: seleccionar un fichero enorme sin
/// querer y pulsar ⌘C.
public struct CaptureLimits: Sendable, Equatable {
    /// Texto plano. 5 MB son unos cinco millones de caracteres: del orden de
    /// mil quinientas páginas. Nadie copia eso a propósito para pegarlo.
    public var maximumTextBytes: Int

    /// Datos comprimidos de una imagen. Una captura de pantalla 6K en PNG
    /// ronda los 20 MB; 64 MB deja margen de sobra.
    public var maximumImageBytes: Int

    /// Píxeles totales de una imagen, que es lo que de verdad manda en la
    /// memoria: descomprimida ocupa cuatro bytes por píxel, así que 80
    /// megapíxeles son ya 320 MB en RAM. Un PNG muy comprimido puede pasar el
    /// límite de bytes y aun así reventar aquí.
    public var maximumImagePixels: Int

    /// Caracteres que la vista previa llega a dibujar.
    ///
    /// Independiente del almacenamiento: una entrada puede guardarse entera y
    /// mostrarse recortada. Pegar sigue dando el contenido completo.
    public var maximumPreviewCharacters: Int

    public init(
        maximumTextBytes: Int = 5 * 1024 * 1024,
        maximumImageBytes: Int = 64 * 1024 * 1024,
        maximumImagePixels: Int = 80_000_000,
        maximumPreviewCharacters: Int = 20_000
    ) {
        self.maximumTextBytes = maximumTextBytes
        self.maximumImageBytes = maximumImageBytes
        self.maximumImagePixels = maximumImagePixels
        self.maximumPreviewCharacters = maximumPreviewCharacters
    }

    public static let standard = CaptureLimits()
}

/// Resultado de mirar el portapapeles.
///
/// Se devuelve un motivo en lugar de un opcional porque la interfaz necesita
/// distinguir «no había nada» de «había algo y lo he descartado». Copiar un
/// fichero enorme y que no aparezca nada, sin explicación, se lee como que la
/// app está rota.
public enum CaptureOutcome: Sendable {
    case captured(CapturedItem)
    case ignored(IgnoreReason)

    public enum IgnoreReason: Sendable, Equatable {
        /// El portapapeles está vacío o solo tiene espacios.
        case empty
        /// El origen marcó el contenido como confidencial o transitorio.
        case markedPrivate
        /// La app que copió está en la lista de exclusiones.
        case excludedApp(String)
        /// Superó un techo de tamaño.
        ///
        /// **No se trunca a propósito.** Guardar la mitad de un texto y dejar
        /// que se pegue como si estuviera completo es un fallo de integridad
        /// peor que no guardarlo: el original sigue en el portapapeles del
        /// sistema y se puede pegar con ⌘V.
        case tooLarge(bytes: Int, limit: Int)
    }

    public var item: CapturedItem? {
        if case .captured(let item) = self { return item }
        return nil
    }
}
