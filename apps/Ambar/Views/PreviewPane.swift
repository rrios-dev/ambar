import ClipboardKit
import GlassUI
import SwiftUI

/// Vista previa de la entrada seleccionada.
struct PreviewPane: View {
    let model: AppModel
    /// Desactivable para rasterizar la vista fuera de una ventana: los
    /// `ScrollView` no se dibujan en ese contexto y saldrían en blanco.
    var scrollable: Bool = true

    private var accessibility: AccessibilityPreferences { .shared }

    var body: some View {
        Group {
            if let item = model.selectedItem {
                VStack(alignment: .leading, spacing: 0) {
                    content(for: item)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(Metrics.Inset.pane)

                    MetadataStrip(item: item)
                }
                .id(item.id)
            } else {
                Color.clear
            }
        }
    }

    @ViewBuilder
    private func content(for item: ClipboardItem) -> some View {
        switch item.kind {
        case .image: imagePreview(for: item)
        case .color: colorPreview(for: item)
        case .file: filePreview(for: item)
        default: textPreview(for: item)
        }
    }

    // MARK: - Imagen

    @ViewBuilder
    private func imagePreview(for item: ClipboardItem) -> some View {
        VStack(alignment: .leading, spacing: Metrics.Spacing.loose) {
            if let image = model.fullImage(for: item) {
                // El contenedor toma la proporción exacta de la imagen. Sin
                // esto, el recorte, el borde y la sombra se aplican al hueco
                // disponible y no a la imagen: queda un marco redondeado
                // flotando alrededor de un rectángulo con las esquinas vivas.
                Color.clear
                    .aspectRatio(aspectRatio(of: image), contentMode: .fit)
                    .overlay {
                        Image(nsImage: image)
                            .resizable()
                            .scaledToFit()
                    }
                    .clipShape(
                        RoundedRectangle(cornerRadius: Metrics.cardCornerRadius, style: .continuous)
                    )
                    .overlay {
                        RoundedRectangle(cornerRadius: Metrics.cardCornerRadius, style: .continuous)
                            .strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5)
                    }
                    // Una sombra corta separa la imagen del material sin
                    // convertirla en una tarjeta flotante.
                    .shadow(color: .black.opacity(0.22), radius: 10, y: 3)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .accessibilityLabel(
                        String(localized: "a11y.preview.image", bundle: .localized)
                    )
            } else {
                placeholder(symbol: "photo")
            }

            recognizedText(for: item)
        }
    }

    /// El texto que Vision leyó dentro de la imagen.
    ///
    /// Se muestra además de la imagen porque es lo que explica por qué esa
    /// captura aparece al buscar una palabra: sin verlo, el resultado parecería
    /// magia o error.
    @ViewBuilder
    private func recognizedText(for item: ClipboardItem) -> some View {
        if let ocr = item.imageMeta?.ocrText, !ocr.isEmpty {
            VStack(alignment: .leading, spacing: Metrics.Spacing.snug) {
                SectionLabel(
                    title: String(localized: "preview.recognized_text", bundle: .localized),
                    symbol: "text.viewfinder"
                )

                let recognized = Text(ocr)
                    .font(.system(size: Metrics.FontSize.caption))
                    .foregroundStyle(Color.informationalStrong)

                if scrollable {
                    ScrollView {
                        recognized
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .scrollIndicators(.never)
                    .frame(maxHeight: 84)
                } else {
                    recognized
                        .lineLimit(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        } else if item.imageMeta?.ocrState == .pending {
            SectionLabel(
                title: String(localized: "preview.recognizing", bundle: .localized),
                symbol: "clock"
            )
        }
    }

    // MARK: - Color

    private func colorPreview(for item: ClipboardItem) -> some View {
        VStack(alignment: .leading, spacing: Metrics.Spacing.loose) {
            RoundedRectangle(cornerRadius: Metrics.cardCornerRadius, style: .continuous)
                .fill(Color(hex: item.preview) ?? .gray)
                .frame(height: 150)
                .overlay {
                    RoundedRectangle(cornerRadius: Metrics.cardCornerRadius, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5)
                }
                .shadow(color: .black.opacity(0.14), radius: 6, y: 2)

            Text(item.preview)
                .font(.system(size: 17, weight: .medium, design: .monospaced))
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            String(
                localized: "a11y.preview.color",
                defaultValue: "Color \(item.preview)",
                bundle: .localized
            )
        )
    }

    // MARK: - Archivos

    private func filePreview(for item: ClipboardItem) -> some View {
        VStack(alignment: .leading, spacing: Metrics.Spacing.snug) {
            ForEach(item.preview.components(separatedBy: ", "), id: \.self) { name in
                HStack(spacing: Metrics.Spacing.snug) {
                    Image(systemName: "doc")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                    Text(name)
                        .font(.system(size: Metrics.FontSize.body))
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }

    // MARK: - Texto

    private func textPreview(for item: ClipboardItem) -> some View {
        let text = Text(model.fullText(for: item) ?? item.preview)
            .font(
                .system(
                    size: Metrics.FontSize.body,
                    design: item.kind == .url ? .monospaced : .default
                )
            )
            // Un interlineado algo mayor que el de la lista: aquí se lee, no se
            // escanea.
            .lineSpacing(3)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .topLeading)

        return Group {
            if scrollable {
                ScrollView { text }.scrollIndicators(.never)
            } else {
                text
            }
        }
    }

    /// Proporción de la imagen, con salvaguarda: una imagen de altura cero
    /// produciría una división inválida y un layout roto.
    private func aspectRatio(of image: NSImage) -> CGFloat {
        guard image.size.height > 0 else { return 1 }
        return image.size.width / image.size.height
    }

    private func placeholder(symbol: String) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 28, weight: .ultraLight))
            .foregroundStyle(Color.decorative)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Rótulo de sección: icono pequeño y texto en versalitas ópticas.
private struct SectionLabel: View {
    let title: String
    let symbol: String

    var body: some View {
        HStack(spacing: Metrics.Spacing.tight) {
            Image(systemName: symbol)
                .font(.system(size: 9))
            Text(title)
                .font(.system(size: Metrics.FontSize.micro, weight: .medium))
                .textCase(.uppercase)
                .tracking(0.4)
        }
        .foregroundStyle(Color.informational)
    }
}

/// Franja inferior con los datos de la entrada.
private struct MetadataStrip: View {
    let item: ClipboardItem

    var body: some View {
        HStack(spacing: Metrics.Spacing.regular) {
            Label(item.kind.localizedName, systemImage: item.kind.symbolName)
                .labelStyle(.titleAndIcon)

            if let meta = item.imageMeta, meta.width > 0 {
                Text(verbatim: "\(meta.width) × \(meta.height)")
                    .monospacedDigit()
            }

            if let source = item.sourceName {
                Text(source)
            }

            Spacer()

            Text(item.createdAt, format: .dateTime.day().month().hour().minute())
                .monospacedDigit()
        }
        .font(.system(size: Metrics.FontSize.micro))
        // Ni `.quaternary` ni `.tertiary`: ambos quedan por debajo del mínimo
        // AA medido. Ver GlassUI/TextStyles.swift.
        .foregroundStyle(Color.informational)
        .lineLimit(1)
        .padding(.horizontal, Metrics.Inset.pane)
        .frame(height: Metrics.metadataHeight)
        // Los mismos datos ya van en la etiqueta de la fila; repetirlos aquí
        // obligaría a VoiceOver a leerlos dos veces por entrada.
        .accessibilityHidden(true)
    }
}
