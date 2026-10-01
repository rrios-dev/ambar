import ClipboardKit
import GlassUI
import SwiftUI

/// Una fila del historial.
///
/// Alto fijo y jerarquía plana: la lista se recorre con las flechas a toda
/// velocidad, así que cada fila debe leerse de un vistazo y costar lo mínimo
/// posible en render.
struct HistoryRow: View {
    let item: ClipboardItem
    let thumbnail: NSImage?
    let isSelected: Bool
    var isHovered: Bool = false

    private var accessibility: AccessibilityPreferences { .shared }

    var body: some View {
        HStack(spacing: Metrics.Spacing.regular) {
            leading
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.system(size: Metrics.FontSize.title))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(primaryStyle)

                HStack(spacing: Metrics.Spacing.tight) {
                    if let source = item.sourceName {
                        Text(source)
                        Text(verbatim: "·")
                    }
                    let age = Self.age(of: item.createdAt)
                    Text(age.date, format: .relative(presentation: age.presentation))
                }
                .font(.system(size: Metrics.FontSize.caption))
                .lineLimit(1)
                .foregroundStyle(secondaryStyle)
            }

            Spacer(minLength: 0)

            if item.pinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(secondaryStyle)
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, Metrics.Spacing.snug)
        .frame(height: Metrics.rowHeight)
        .background(background)
        .contentShape(.rect)
        // VoiceOver lee la fila como una sola unidad con toda su información,
        // en vez de deletrear cada trozo suelto sin contexto.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isSelected ? [.isSelected, .isButton] : .isButton)
        .accessibilityHint(String(localized: "a11y.row.hint", bundle: .localized))
    }

    // MARK: - Fondo

    @ViewBuilder
    private var background: some View {
        if isSelected {
            ZStack(alignment: .leading) {
                // Los colores de selección del sistema, no un acento propio:
                // se adaptan al color elegido por el usuario, a claro/oscuro y
                // al modo de contraste aumentado, y garantizan el contraste del
                // texto encima. Es lo que usa cualquier lista de macOS.
                RoundedRectangle(cornerRadius: Metrics.rowCornerRadius, style: .continuous)
                    .fill(Color(nsColor: .selectedContentBackgroundColor))

                // Con «Diferenciar sin color» la selección no puede depender
                // solo del tono: se añade una marca de forma.
                if accessibility.differentiateWithoutColor {
                    Capsule()
                        .fill(Color(nsColor: .alternateSelectedControlTextColor))
                        .frame(width: 3, height: Metrics.rowHeight * 0.5)
                        .padding(.leading, 3)
                }
            }
        } else if isHovered {
            RoundedRectangle(cornerRadius: Metrics.rowCornerRadius, style: .continuous)
                .fill(Color.primary.opacity(0.06))
        }
    }

    private var primaryStyle: AnyShapeStyle {
        isSelected
            ? AnyShapeStyle(Color(nsColor: .alternateSelectedControlTextColor))
            : AnyShapeStyle(.primary)
    }

    private var secondaryStyle: AnyShapeStyle {
        guard isSelected else { return AnyShapeStyle(Color.informational) }
        // Ver `Color.Opacity.selectedSecondary`: el 0,75 que había aquí bajaba el
        // subtítulo de la fila seleccionada a 2,89:1 con «Aumentar contraste».
        let opacity = AccessibilityPreferences.shared.increaseContrast
            ? Color.Opacity.selectedSecondaryHighContrast
            : Color.Opacity.selectedSecondary
        return AnyShapeStyle(Color(nsColor: .alternateSelectedControlTextColor).opacity(opacity))
    }

    // MARK: - Elemento inicial

    @ViewBuilder
    private var leading: some View {
        if let thumbnail {
            Image(nsImage: thumbnail)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .frame(width: Metrics.IconSize.thumbnail, height: Metrics.IconSize.thumbnail)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay {
                    // Filo interior: separa la miniatura del fondo cuando la
                    // imagen es casi del mismo tono que el panel.
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                }
        } else if item.kind == .color, let color = Color(hex: item.preview) {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(color)
                .frame(width: Metrics.IconSize.thumbnail, height: Metrics.IconSize.thumbnail)
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.15), lineWidth: 0.5)
                }
        } else {
            Image(systemName: item.kind.symbolName)
                .font(.system(size: Metrics.IconSize.row, weight: .regular))
                .frame(width: Metrics.IconSize.thumbnail, height: Metrics.IconSize.thumbnail)
                .foregroundStyle(isSelected ? primaryStyle : AnyShapeStyle(.secondary))
        }
    }

    // MARK: - Texto

    private var title: String {
        if !item.preview.isEmpty { return item.preview }

        if item.kind == .image, let meta = item.imageMeta {
            return String(
                localized: "row.image_dimensions",
                defaultValue: "Imagen \(meta.width) × \(meta.height)",
                bundle: .localized
            )
        }

        return String(localized: "row.untitled", defaultValue: "Sin contenido", bundle: .localized)
    }

    /// The date and presentation that describe an entry's age.
    ///
    /// Anything younger than a minute reads as "now". The numeric presentation had two
    /// faults there: a seconds count that is stale the moment it renders, and, for an entry
    /// stamped a hair after the render read the clock (copied or promoted that same
    /// instant), "dentro de 0 segundos", an entry from the future. The date is also clamped
    /// to `now`, so no age is ever in the future.
    static func age(
        of date: Date,
        now: Date = .now
    ) -> (date: Date, presentation: Date.RelativeFormatStyle.Presentation) {
        now.timeIntervalSince(date) < 60 ? (now, .named) : (min(date, now), .numeric)
    }

    /// Frase completa para VoiceOver: tipo, contenido, origen y antigüedad.
    private var accessibilityLabel: String {
        var parts: [String] = [item.kind.localizedName, title]
        if let source = item.sourceName { parts.append(source) }
        parts.append(
            Self.age(of: item.createdAt).date.formatted(.relative(presentation: .named))
        )
        if item.pinned {
            parts.append(String(localized: "a11y.row.pinned", bundle: .localized))
        }
        return parts.joined(separator: ", ")
    }
}

extension ItemKind {
    var localizedName: String {
        switch self {
        case .text: String(localized: "kind.text", bundle: .localized)
        case .richText: String(localized: "kind.rich_text", bundle: .localized)
        case .image: String(localized: "kind.image", bundle: .localized)
        case .file: String(localized: "kind.file", bundle: .localized)
        case .color: String(localized: "kind.color", bundle: .localized)
        case .url: String(localized: "kind.url", bundle: .localized)
        }
    }
}

extension Color {
    /// Interpreta `#RRGGBB`. Devuelve `nil` si no lo es, para que la fila caiga
    /// al icono genérico en vez de pintar un color inventado.
    init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("#") else { return nil }
        text.removeFirst()
        guard text.count == 6, let value = UInt32(text, radix: 16) else { return nil }

        self.init(
            .sRGB,
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255
        )
    }
}
