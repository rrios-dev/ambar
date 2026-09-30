import Foundation

/// Clase de contenido de una entrada del historial.
///
/// El tipo es una clasificación *para la interfaz* (qué icono, qué preview, qué
/// filtro), no una descripción exhaustiva de lo que se guardó: un mismo item
/// suele traer varias representaciones a la vez.
public enum ItemKind: String, Sendable, CaseIterable, Codable {
    case text
    case richText = "rich_text"
    case image
    case file
    case color
    case url

    public var symbolName: String {
        switch self {
        case .text: "text.alignleft"
        case .richText: "textformat"
        case .image: "photo"
        case .file: "doc"
        case .color: "paintpalette"
        case .url: "link"
        }
    }
}

/// Una de las formas en que el sistema ofreció el mismo contenido.
///
/// `NSPasteboardItem` expone varias UTIs simultáneas —copiar de una web da a la
/// vez HTML, RTF y texto plano— y cuál conviene depende de dónde se pegue.
/// Guardarlas todas es lo que permite que pegar en Pages conserve el formato y
/// pegar en la terminal no arrastre basura.
public struct Representation: Sendable, Hashable {
    public let uti: String
    public let blobHash: String?
    public let inline: Data?
    public let bytes: Int

    public init(uti: String, blobHash: String?, inline: Data?, bytes: Int) {
        self.uti = uti
        self.blobHash = blobHash
        self.inline = inline
        self.bytes = bytes
    }
}

/// Metadatos de una imagen, incluido el estado del reconocimiento de texto.
public struct ImageMeta: Sendable, Hashable {
    public enum OCRState: String, Sendable {
        case pending, done, failed, skipped
    }

    public let width: Int
    public let height: Int
    public let thumbnailHash: String?
    public let ocrText: String?
    public let ocrState: OCRState

    public init(
        width: Int,
        height: Int,
        thumbnailHash: String?,
        ocrText: String?,
        ocrState: OCRState
    ) {
        self.width = width
        self.height = height
        self.thumbnailHash = thumbnailHash
        self.ocrText = ocrText
        self.ocrState = ocrState
    }
}

/// Una entrada del historial tal y como se muestra y se persiste.
public struct ClipboardItem: Sendable, Identifiable, Hashable {
    public let id: Int64
    public let kind: ItemKind
    public let createdAt: Date
    public let lastUsedAt: Date?
    public let useCount: Int
    public let pinned: Bool
    public let sourceBundle: String?
    public let sourceName: String?
    public let preview: String
    public let concealed: Bool
    public let imageMeta: ImageMeta?

    public init(
        id: Int64,
        kind: ItemKind,
        createdAt: Date,
        lastUsedAt: Date?,
        useCount: Int,
        pinned: Bool,
        sourceBundle: String?,
        sourceName: String?,
        preview: String,
        concealed: Bool,
        imageMeta: ImageMeta?
    ) {
        self.id = id
        self.kind = kind
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
        self.useCount = useCount
        self.pinned = pinned
        self.sourceBundle = sourceBundle
        self.sourceName = sourceName
        self.preview = preview
        self.concealed = concealed
        self.imageMeta = imageMeta
    }
}

/// Lo que el lector extrae del portapapeles antes de persistirlo.
public struct CapturedItem: Sendable {
    public var kind: ItemKind
    public var representations: [Representation]
    public var preview: String
    /// Texto que alimenta el índice de búsqueda. En imágenes lo rellena el OCR.
    public var searchableText: String?
    public var sourceBundle: String?
    public var sourceName: String?
    public var concealed: Bool
    public var imageData: Data?
    /// Huella para detectar repeticiones: si coincide con la del último item,
    /// no se crea una entrada nueva.
    public var fingerprint: String

    public init(
        kind: ItemKind,
        representations: [Representation],
        preview: String,
        searchableText: String?,
        sourceBundle: String?,
        sourceName: String?,
        concealed: Bool,
        imageData: Data?,
        fingerprint: String
    ) {
        self.kind = kind
        self.representations = representations
        self.preview = preview
        self.searchableText = searchableText
        self.sourceBundle = sourceBundle
        self.sourceName = sourceName
        self.concealed = concealed
        self.imageData = imageData
        self.fingerprint = fingerprint
    }
}

/// UTIs con significado propio para la app.
public enum UTIs {
    public static let plainText = "public.utf8-plain-text"
    public static let rtf = "public.rtf"
    public static let html = "public.html"
    public static let png = "public.png"
    public static let tiff = "public.tiff"
    public static let fileURL = "public.file-url"
    public static let url = "public.url"
    public static let color = "com.apple.cocoa.pasteboard.color"

    /// Marca de nspasteboard.org que los gestores de contraseñas ponen para
    /// pedir que el contenido no se historifique. Respetarla evita que una
    /// contraseña acabe en la base de datos aunque la app no esté en la lista
    /// de exclusiones — la lista manual siempre va por detrás de la realidad.
    public static let concealed = "org.nspasteboard.ConcealedType"

    /// Convención complementaria para contenido transitorio (no persistible).
    public static let transient = "org.nspasteboard.TransientType"
    public static let autoGenerated = "org.nspasteboard.AutoGeneratedType"
}
