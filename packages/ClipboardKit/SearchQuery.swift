import Foundation

/// Consulta del panel, ya interpretada.
///
/// La sintaxis es de prefijos (`img:`, `file:`, `app:safari`) porque mantiene
/// la interfaz limpia —un solo campo de texto— sin renunciar a acotar. Escribir
/// `img: factura` es más rápido que alcanzar un filtro con el ratón, y quien no
/// conozca los prefijos simplemente escribe y todo sigue funcionando.
public struct SearchQuery: Sendable, Equatable {
    public var terms: [String]
    public var kinds: Set<ItemKind>
    public var app: String?
    public var pinnedOnly: Bool

    public init(
        terms: [String] = [],
        kinds: Set<ItemKind> = [],
        app: String? = nil,
        pinnedOnly: Bool = false
    ) {
        self.terms = terms
        self.kinds = kinds
        self.app = app
        self.pinnedOnly = pinnedOnly
    }

    public static let empty = SearchQuery()

    public var isEmpty: Bool {
        terms.isEmpty && kinds.isEmpty && app == nil && !pinnedOnly
    }

    /// Expresión lista para `MATCH`, o `nil` si no hay texto libre que buscar.
    ///
    /// Cada término se entrecomilla —así los signos de puntuación no se
    /// interpretan como operadores de FTS5 y una búsqueda de `C++` no explota—
    /// y se le añade `*` para que la lista filtre mientras se teclea.
    public var ftsExpression: String? {
        guard !terms.isEmpty else { return nil }
        return terms
            .map { term in
                let escaped = term.replacingOccurrences(of: "\"", with: "\"\"")
                return "\"\(escaped)\"*"
            }
            .joined(separator: " ")
    }

    // MARK: - Análisis

    private static let kindPrefixes: [String: ItemKind] = [
        "img": .image,
        "image": .image,
        "imagen": .image,
        "file": .file,
        "archivo": .file,
        "text": .text,
        "texto": .text,
        "color": .color,
        "url": .url,
        "link": .url,
        "enlace": .url,
        "rich": .richText,
    ]

    private static let pinnedTokens: Set<String> = ["pin", "pinned", "fijado", "fijados"]
    private static let appTokens: Set<String> = ["app", "from", "de"]

    public static func parse(_ input: String) -> SearchQuery {
        var query = SearchQuery()

        for rawToken in input.split(separator: " ", omittingEmptySubsequences: true) {
            let token = String(rawToken)

            guard let separator = token.firstIndex(of: ":") else {
                query.terms.append(token)
                continue
            }

            let prefix = String(token[token.startIndex..<separator]).lowercased()
            let value = String(token[token.index(after: separator)...])

            if let kind = kindPrefixes[prefix] {
                query.kinds.insert(kind)
                // `img:factura` acota y busca en el mismo gesto.
                if !value.isEmpty { query.terms.append(value) }
            } else if appTokens.contains(prefix), !value.isEmpty {
                query.app = value
            } else if pinnedTokens.contains(prefix) {
                query.pinnedOnly = true
                if !value.isEmpty { query.terms.append(value) }
            } else {
                // No es un prefijo conocido: una URL pegada en el buscador debe
                // buscarse tal cual, no perderse por contener dos puntos.
                query.terms.append(token)
            }
        }

        return query
    }
}
