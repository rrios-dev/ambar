import AppKit
import GlassUI
import SwiftUI
import VoiceKit

/// Banda que aparece en el panel cuando hay un dictado en marcha.
///
/// Es la representación del gesto y del estado, y **el único sitio donde vive el
/// texto mientras se refina**: nunca se escribe en la app de destino hasta que es
/// definitivo, porque el motor corrige palabras que ya había dado y reescribir en
/// territorio ajeno es la peor forma posible de hacer esto.
struct DictationBanner: View {
    let state: DictationSessionState
    let liveText: String
    /// El texto mostrado es todavía una hipótesis del motor.
    var liveTextIsVolatile: Bool = false
    /// How many characters at the end of `liveText` are still the engine's hypothesis.
    /// The expanded transcript draws the firm/volatile boundary with it.
    var volatileCharacters: Int = 0
    /// Whether the transcript shows in full instead of the three-line tail.
    var isExpanded: Bool = false
    /// Toggles between the tail and the full transcript. Absent = not expandable.
    var onToggleExpansion: (() -> Void)?
    /// Called with (original, corrected) when the user edits a word inline.
    var onEditWord: ((String, String) -> Void)?
    /// Reports whether an inline editor holds the keyboard.
    var onEditingChanged: ((Bool) -> Void)?
    /// The correction the dictionary just learned, while its feedback shows.
    var recentLearning: DictationController.LearnedCorrection?
    /// Reverts the learning the pill announces.
    var onUndoLearning: (() -> Void)?
    /// Tirar lo dictado sin entregarlo.
    var onDiscard: (() -> Void)?
    /// Causa del fallo, para poder decir cuál fue y ofrecer la acción que
    /// corresponde. Sin esto los cuatro fallos —permiso revocado, modelo ausente,
    /// cupo lleno, cambio de dispositivo— colapsaban en «No se pudo dictar».
    var failure: DictationFailure?
    /// Parar de escuchar. Es la salida visible que el gesto no da: soltar la tecla
    /// funciona, pero una tecla enclavada —Sticky Keys, un teclado que reporta ⌘
    /// hundido— dejaría el micrófono abierto sin ninguna forma de cerrarlo.
    var onStop: (() -> Void)?
    /// Abrir los ajustes de Ámbar, para los fallos que se resuelven ahí.
    var onOpenSettings: (() -> Void)?
    /// Cerrar el aviso de fallo. Sin esto se quedaba en pantalla hasta reabrir el
    /// panel, a diferencia del aviso general de error, que sí se puede descartar.
    var onDismissFailure: (() -> Void)?

    private var accessibility: AccessibilityPreferences { .shared }

    /// Lo que la banda dice en este estado. Todas las decisiones, en un valor afirmable.
    private var content: DictationBannerContent {
        DictationBannerContent.resolve(
            state: state,
            liveText: liveText,
            liveTextIsVolatile: liveTextIsVolatile,
            failure: failure,
            hasSystemSettingsURL: MicrophoneAuthorization.settingsURL != nil
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: content.symbol)
                    .foregroundStyle(Color.informationalStrong)
                    .accessibilityHidden(true)

                Text(content.title)
                    .font(.system(size: 12, weight: .medium))
                    // El token del sistema de la app, no una opacidad a mano: sube
                    // a 0,95 con «Aumentar contraste», que una constante no hace.
                    .foregroundStyle(Color.informationalStrong)

                Spacer()

                if case .arming(let progress, _) = state {
                    ArmingIndicator(progress: progress)
                }

                // Los controles, en el orden que decide `content`. La vista no elige
                // ninguno: si eligiera, volveríamos al caso en el que borrar el botón de
                // parar no rompe nada.
                ForEach(content.controls, id: \.self) { control in
                    controlView(for: control)
                }
            }

            if !liveText.isEmpty {
                if isExpanded {
                    ExpandedTranscript(
                        text: liveText,
                        volatileCharacters: volatileCharacters,
                        isVolatile: liveTextIsVolatile,
                        onEditWord: onEditWord,
                        onEditingChanged: onEditingChanged
                    )
                } else {
                    collapsedTranscript
                }
                if let onToggleExpansion {
                    expansionToggle(onToggleExpansion)
                }
            }

            if let recentLearning {
                learnedPill(recentLearning)
            }
        }
        .padding(.horizontal, Self.horizontalPadding)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        // La opacidad vive en `Color.Opacity` con el resto de las del sistema de diseño, y
        // no como literal aquí: el test de contraste la lee de ahí. Mientras fue literal,
        // el test replicaba los valores y no protegía nada.
        .background(
            Color(nsColor: .labelColor)
                .opacity(Color.Opacity.bannerLayer(increaseContrast: accessibility.increaseContrast))
        )
        // `.contain` y no `.combine`: con `.combine`, los botones de parar y de
        // abrir Ajustes se fusionaban en el elemento padre y desaparecían del orden
        // de lectura. Para quien llegó por el camino accesible, el botón de parar es
        // la única salida.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(content.accessibilityLabel)
        .accessibilityValue(content.accessibilityValue)
        .accessibilityAddTraits(.updatesFrequently)
        // Los anuncios los publica el CONTROLADOR, no esta vista: el banner no está
        // montado cuando la cuenta empieza, así que su `onChange` no corría para el
        // arranque — que es justo el momento en que hay que avisar.
    }

    // MARK: - Texto en vivo

    /// Acolchado lateral de la banda. Es constante, y no un literal repetido, porque de él
    /// sale el ancho con el que se mide el texto: si divergen, la ventana se calcula sobre
    /// una columna que no existe.
    static let horizontalPadding: CGFloat = 12

    /// Cuántas líneas de dictado se enseñan.
    static let liveTextLines = 3

    /// Ancho real de la columna de texto. La banda ocupa el panel entero —`ContentView` lo
    /// fija— menos su propio acolchado.
    static var liveTextWidth: CGFloat { Metrics.panelWidth - horizontalPadding * 2 }

    /// El trozo del dictado que se pinta: **las últimas líneas**, con `…` delante cuando
    /// queda texto por arriba.
    ///
    /// Lo que se recorta es lo que se VE, nunca lo que se entrega ni lo que se locuta: la
    /// etiqueta de accesibilidad sigue llevando el dictado entero, y quien pega recibe todo
    /// lo dictado. Aquí solo se decide dónde mira la ventana.
    private var visibleLiveText: String {
        LiveTranscriptWindow.tail(
            of: liveText,
            width: Self.liveTextWidth,
            font: Self.liveTextFont(isVolatile: liveTextIsVolatile),
            lines: Self.liveTextLines
        )
    }

    /// Is the three-line window actually hiding text?
    ///
    /// It no longer gates anything — it only picks the wording, so a short dictation
    /// is offered "Correct" instead of "Show all and correct". Gating the affordance
    /// on it was a real defect: correcting a word is useful at ANY length, and with a
    /// short dictation the banner offered no way in at all. Reported as "I click and
    /// nothing happens", which is exactly what it did.
    private var collapsedTextElides: Bool {
        visibleLiveText != liveText
    }

    /// The tail window, exactly as before — plus a click that opens the full view.
    private var collapsedTranscript: some View {
        Text(visibleLiveText)
            .font(.system(size: 13))
            // Mientras es volátil se muestra atenuado, y pasa a pleno cuando el
            // motor lo da por firme. Es la única señal de «esto ya no va a
            // cambiar», y `isVolatile` existía sin que nadie la leyera: se
            // pintaban diez hipótesis con el mismo aspecto que el texto final.
            //
            // El token, no una opacidad a mano: sube con «Aumentar contraste», así
            // que la distinción no se paga con legibilidad.
            .foregroundStyle(
                Color(nsColor: .labelColor).opacity(Self.transcriptStyle(
                    isVolatile: liveTextIsVolatile,
                    increaseContrast: AccessibilityPreferences.shared.increaseContrast
                ).opacity)
            )
            .italic(Self.transcriptStyle(
                isVolatile: liveTextIsVolatile,
                increaseContrast: AccessibilityPreferences.shared.increaseContrast
            ).italic)
            .lineLimit(Self.liveTextLines)
            // Los puntos suspensivos van al PRINCIPIO, no al final. En un dictado
            // en curso lo único que importa es la cola —lo que se acaba de decir—,
            // y con el truncado por defecto se veían las tres primeras líneas y se
            // perdía justo eso: a partir de ahí la banda dejaba de confirmar que el
            // motor estaba oyendo bien, que es para lo que está.
            .truncationMode(.head)
            .fixedSize(horizontal: false, vertical: true)
            // The whole tail is the click target for expanding. Text selection moved
            // WITH the full view: selecting three truncated lines was never useful,
            // and the two gestures fight over the same clicks.
            .contentShape(Rectangle())
            .onTapGesture { onToggleExpansion?() }
    }

    /// What the expand control says. Three cases, because "Show all" is a lie when
    /// everything is already visible — there the offer is simply to correct.
    private var expansionLabel: String {
        if isExpanded {
            return String(localized: "dictation.transcript.collapse", bundle: .localized)
        }
        return collapsedTextElides
            ? String(localized: "dictation.transcript.expand", bundle: .localized)
            : String(localized: "dictation.transcript.correct", bundle: .localized)
    }

    /// The row that opens or closes the full transcript.
    ///
    /// A real `Button`, not a decorated gesture: the panel exposes its controls to
    /// VoiceOver through the banner's `.contain`, and a tap-only affordance would
    /// leave the expanded view unreachable for exactly the users who cannot aim at
    /// a three-line strip of text.
    private func expansionToggle(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.up")
                    .font(.system(size: 9, weight: .semibold))
                Text(expansionLabel)
                .font(.system(size: 11))
            }
            .foregroundStyle(Color.informationalStrong)
            .frame(minHeight: 22)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// La fuente con la que se compone el texto en vivo, cursiva incluida.
    ///
    /// Tiene que ser la misma con la que se PINTA: medir en redonda lo que se dibuja en
    /// cursiva desplaza las roturas de línea y la cola sale corrida.
    static func liveTextFont(isVolatile: Bool) -> NSFont {
        let base = NSFont.systemFont(ofSize: 13)
        guard transcriptStyle(
            isVolatile: isVolatile,
            increaseContrast: AccessibilityPreferences.shared.increaseContrast
        ).italic else { return base }
        return NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask)
    }

    /// Cómo se dibuja el texto en curso: opacidad y cursiva.
    struct TranscriptStyle: Equatable {
        /// Factor sobre `labelColor`, que ya trae su propio alfa (0,847).
        let opacity: Double
        let italic: Bool
    }

    /// El estilo del texto según sea hipótesis o texto ya firme.
    ///
    /// Los **dos** canales salen de aquí, y por eso es una función y no dos condiciones
    /// sueltas en la vista. Con el color solo, la distinción se perdía con «Aumentar
    /// contraste»: ese ajuste sube el token de la hipótesis a opacidad plena —para eso
    /// está— y entonces hipótesis y texto firme se dibujaban EXACTAMENTE igual, 12,08:1
    /// los dos, medido. La única señal de «esto todavía puede cambiar» desaparecía justo
    /// para quien había pedido ver mejor. La cursiva no depende del contraste y no se
    /// puede subir hasta borrarla.
    static func transcriptStyle(isVolatile: Bool, increaseContrast: Bool) -> TranscriptStyle {
        guard isVolatile else { return TranscriptStyle(opacity: 1, italic: false) }
        return TranscriptStyle(
            opacity: increaseContrast
                ? Color.Opacity.informationalStrongHighContrast
                : Color.Opacity.informationalStrong,
            italic: true
        )
    }

    /// The transient "learned" feedback: what just entered the dictionary, with the
    /// one control that matters next to it.
    ///
    /// Undo reverts the LEARNING, not the edit — the text keeps the correction. The
    /// pill leaves on its own (the controller clears it), because a confirmation
    /// that demands a click would turn automatic learning back into a dialog.
    private func learnedPill(_ learning: DictationController.LearnedCorrection) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "character.book.closed")
                .font(.system(size: 11))
                .accessibilityHidden(true)
            Text(
                String(
                    format: String(localized: "dictation.learned", bundle: .localized),
                    learning.entry.written
                )
            )
            .font(.system(size: 11, weight: .medium))
            if let onUndoLearning {
                Button(
                    String(localized: "dictation.learned.undo", bundle: .localized),
                    action: onUndoLearning
                )
                .buttonStyle(.remedy)
                .font(.system(size: 11))
            }
        }
        .foregroundStyle(Color.informationalStrong)
    }

    /// Pinta un control del contenido resuelto.
    @ViewBuilder
    private func controlView(for control: DictationBannerContent.Control) -> some View {
        switch control {
        case .openSystemSettings:
            if let url = MicrophoneAuthorization.settingsURL {
                Button(String(localized: "dictation.open_settings", bundle: .localized)) {
                    NSWorkspace.shared.open(url)
                }
                .buttonStyle(.remedy)
                .font(.system(size: 11))
                // Quien de verdad dispara el atajo es el monitor de teclas del panel —el
                // `keyDown` no llega hasta aquí—, pero declararlo hace que SwiftUI lo
                // muestre en la ayuda y lo lea VoiceOver. Un atajo que funciona y que nadie
                // puede descubrir sigue siendo inalcanzable.
                .keyboardShortcut(",", modifiers: .command)
            }
        case .openAppSettings:
            if let onOpenSettings {
                Button(String(localized: "dictation.open_app_settings", bundle: .localized), action: onOpenSettings)
                    .buttonStyle(.remedy)
                    .font(.system(size: 11))
                    .keyboardShortcut(",", modifiers: .command)
            }
        case .dismissFailure:
            if let onDismissFailure {
                iconButton(
                    "xmark",
                    label: String(localized: "error.dismiss", bundle: .localized),
                    action: onDismissFailure
                )
            }
        case .discard:
            if let onDiscard {
                iconButton(
                    "xmark.circle",
                    label: String(localized: "dictation.discard", bundle: .localized),
                    action: onDiscard
                )
            }
        case .stop:
            if let onStop {
                // Named, and weighted, because this is the one that DELIVERS.
                //
                // Stop and discard used to be two circled glyphs of the same size and
                // colour, side by side — `stop.circle` and `xmark.circle`. Nothing said
                // which one hands the text over and which one throws it away, and no two
                // outcomes are further apart. Reported as "I could not tell which was
                // the finish button".
                //
                // The label reuses the existing key: it was already the accessibility
                // label, so it ships translated in every locale. Making it visible costs
                // no new string, and closes a gap where VoiceOver knew more than the
                // person looking at the screen.
                Button(String(localized: "dictation.stop", bundle: .localized), action: onStop)
                    .buttonStyle(.remedy)
                    .font(.system(size: 11, weight: .semibold))
                    // 28 pt of height, which is what the accessibility gate demands of the
                    // two banner buttons — they are the controls that RESOLVE the problem,
                    // and shrinking them makes them harder to hit than the problem itself.
                    // `.remedy` leaves 22: it is a link-like style, sized for an affordance
                    // inside a line of text. This is not that. Measured on CI, which caught
                    // it: 55x22 against the 28 the gate declares.
                    .frame(minHeight: 28)
                    // After the frame, so the whole target is clickable and not just the
                    // label — the style's own `contentShape` only covers the text.
                    .contentShape(Rectangle())
                    // The panel's key monitor is what actually fires this — the `keyDown`
                    // never reaches here — but declaring it puts ⏎ into the help and into
                    // what VoiceOver announces.
                    .keyboardShortcut(.return, modifiers: [])
            }
        }
    }

    /// Botón de icono con diana de 28 pt.
    ///
    /// Un glifo de 13 pt es hostil para quien tiene dificultad motora, que es justamente
    /// quien más depende de estos controles.
    private func iconButton(
        _ symbol: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }


}

/// Avance de la cuenta del gesto.
///
/// Tiene **dos representaciones deliberadamente distintas**. Con movimiento
/// permitido, una barra que crece. Con «Reducir movimiento», una escalera de
/// puntos que se rellenan: sigue informando del avance, sin animar nada.
///
/// Esto no es un adorno accesible: el umbral del gesto es un valor propio y la
/// animación solo lo representa. Si la única representación fuera animada, quien
/// tiene «Reducir movimiento» activado no vería venir el dictado — el gesto pasaría
/// de autoexplicativo a secreto justo para quien más necesita previsibilidad.
struct ArmingIndicator: View {
    let progress: Double

    private var accessibility: AccessibilityPreferences { .shared }
    static let steps = 5

    /// Qué representación usar. Extraída para que un test pueda afirmar sobre la
    /// elección misma: mientras vivía como el `if` de arriba, sustituir
    /// `accessibility.reduceMotion` por `false` no rompía nada — la escalera discreta,
    /// que existe para que quien pidió «Reducir movimiento» siga viendo venir el
    /// dictado sin ninguna animación, se podía perder en silencio.
    static func representation(reduceMotion: Bool) -> Representation {
        reduceMotion ? .steps : .bar
    }
    enum Representation: Equatable { case bar, steps }

    /// ¿Este punto de la escalera está relleno? Aparte del `ForEach` por el mismo
    /// motivo: la fórmula de relleno es donde vive el criterio, y un test puede
    /// preguntarle sin montar una vista.
    ///
    /// El margen de 0,001 no es cosmético: `progress` llega como `Double` acumulado
    /// tic a tic, y comparar `1.0/5 <= 0.2` con aritmética de coma flotante no siempre
    /// da `true` en el punto exacto — el último punto podía quedarse vacío en el
    /// instante en que el gesto se confirma.
    static func isStepFilled(_ index: Int, progress: Double, steps: Int = steps) -> Bool {
        Double(index + 1) / Double(steps) <= progress + 0.001
    }

    var body: some View {
        switch Self.representation(reduceMotion: accessibility.reduceMotion) {
        case .steps:
            HStack(spacing: 3) {
                ForEach(0..<Self.steps, id: \.self) { index in
                    let filled = Self.isStepFilled(index, progress: progress)
                    Circle()
                        .fill(filled ? Color.informationalStrong : Color.trackFill)
                        .frame(width: 5, height: 5)
                }
            }
            .accessibilityHidden(true)
        case .bar:
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.trackFill)
                Capsule()
                    .fill(Color.informationalStrong)
                    .frame(width: max(2, 44 * progress))
            }
            .frame(width: 44, height: 4)
            .accessibilityHidden(true)
        }
    }
}
