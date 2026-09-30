import AppCore
import ClipboardKit
import GlassUI
import SwiftUI
import VoiceKit

/// Cuerpo del panel: búsqueda arriba, lista y vista previa en paralelo, pie de
/// atajos abajo.
struct ContentView: View {
    @Bindable var model: AppModel
    let controller: PanelController

    @FocusState private var searchFocused: Bool
    @State private var hoveredID: Int64?

    private var accessibility: AccessibilityPreferences { .shared }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                SearchField(text: $model.searchText, focused: $searchFocused, count: model.items.count)

                // El dictado tiene que ser alcanzable SIN mantener una tecla: quien
                // tiene temblor, o usa Slow Keys o Sticky Keys, no puede sostener un
                // atajo 550 ms. Sin este botón la función existía y era inaccesible.
                // Visible también durante la cuenta: ocultarlo hacía desaparecer la
                // única puerta de ratón de quien no puede mantener una tecla, justo
                // mientras el atajo estaba pulsado, y reflowaba el buscador al volver.
                if let dictation = model.dictation,
                   DictationEntryPoints.showsMicrophoneButton(for: dictation.state) {
                    Button {
                        // La MISMA acción que ⌘D: el botón se pintaba en `.preparing` y
                        // `.finalizing`, donde `startWithoutGesture` no hace nada, así
                        // que era un control habilitado y mudo.
                        switch DictationEntryPoints.commandDAction(for: dictation.state) {
                        case .start:
                            dictation.startWithoutGesture(
                                locale: Locale.current,
                                mode: model.settings.dictationMode
                            )
                        case .stop: dictation.stop()
                        case .discard: dictation.discard()
                        }
                    } label: {
                        Image(systemName: "mic")
                            // 24×24 como los del banner: el glifo desnudo daba un
                            // blanco de ~13 pt, y este botón es justamente la puerta
                            // de entrada de quien no puede mantener una tecla.
                            .frame(width: 28, height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.informationalStrong)
                    .padding(.trailing, 6)
                    .help(String(localized: "dictation.start", bundle: .localized))
                    .accessibilityLabel(String(localized: "dictation.start", bundle: .localized))
                    // El atajo, en el propio botón: el pie que lo anunciaba va
                    // `accessibilityHidden` cuando hay permiso de accesibilidad —o sea
                    // en el caso normal— así que para quien usa VoiceOver la única vía
                    // de teclado al dictado era indescubrible.
                    .accessibilityHint(String(localized: "dictation.start.hint", bundle: .localized))
                }
            }

            // §10: «El indicador se ve siempre que el panel esté abierto». Estaba
            // solo en Ajustes y en el menú de la barra, así que quien tenía la
            // captura pausada no lo sabía mirando el panel.
            if model.settings.isPaused {
                PauseChip(remaining: model.settings.remainingPause) {
                    model.settings.resumeCapture()
                    model.syncSettingsToServices()
                }
                Hairline()
            }

            if let dictation = model.dictation,
               DictationEntryPoints.showsBanner(for: dictation.state) {
                DictationBanner(
                    state: dictation.state,
                    liveText: dictation.liveText,
                    liveTextIsVolatile: dictation.liveTextIsVolatile,
                    volatileCharacters: dictation.liveVolatileCharacters,
                    isExpanded: dictation.isTranscriptExpanded,
                    onToggleExpansion: { dictation.toggleTranscriptExpansion() },
                    onEditWord: { original, corrected in
                        dictation.applyEdit(original: original, corrected: corrected)
                    },
                    onEditingChanged: { dictation.setWordEditing($0) },
                    recentLearning: dictation.recentLearning,
                    onUndoLearning: { dictation.undoRecentLearning() },
                    onDiscard: { dictation.discard() },
                    failure: dictation.lastFailure,
                    onStop: { dictation.stop() },
                    onOpenSettings: { model.onOpenSettings?() },
                    onDismissFailure: { dictation.resetIfSettled() }
                )
                // La transición del diseño (§8.4): la banda **crece** desde el borde
                // superior en lugar de aparecer de golpe.
                //
                // No es decoración. Es el argumento entero de descubribilidad del gesto:
                // «una transición que empieza delante de los ojos se enseña sola». Sin
                // ella, mantener el atajo daba un corte seco —la lista se encogía y se
                // volvía a expandir de golpe— y no había nada que dijera «esto está
                // pasando porque sigues pulsando».
                //
                // Con «Reducir movimiento» no se anima **nada**: la banda aparece y
                // desaparece sin transición, y el avance sigue estando en la escalera de
                // puntos de `ArmingIndicator`. El umbral del gesto no cambia en ningún
                // caso: es un valor propio, la animación solo lo representa.
                .transition(DictationBannerTransition.current)
                Hairline()
                    .transition(DictationBannerTransition.current)
            }

            Hairline()

            if model.items.isEmpty {
                EmptyStateView(hasQuery: !model.searchText.isEmpty)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(spacing: 0) {
                    HistoryList(model: model, controller: controller, hoveredID: $hoveredID)
                        .frame(width: Metrics.listWidth)

                    Hairline(axis: .vertical)

                    PreviewPane(model: model)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }

            Hairline()

            // Un fallo del almacén dejaba la app aparentemente vacía sin decir
            // por qué. Si el disco está lleno o la base no abre, el usuario
            // tiene derecho a saberlo en vez de creer que perdió el historial.
            if let error = model.lastError {
                ErrorBanner(message: error) { model.dismissError() }
            }

            FooterBar(model: model)
        }
        // La animación que **ejecuta** la transición de la banda del dictado. Va atada al
        // estado del dictado con `value:`, así que solo corre cuando ese estado cambia: el
        // resto del panel —lista, filtro, previsualización— no se anima por esto.
        //
        // Tiene que estar en el contenedor y no en la banda: una transición de
        // inserción/retirada la ejecuta quien contiene al elemento que aparece, no el
        // elemento. Puesta dentro del `if`, la banda seguía apareciendo de golpe.
        // `animationIdentity` y no el estado entero: el estado cambia en cada tic de la
        // cuenta y eso animaba también la barra de avance, dejándola por detrás de lo que
        // mide. Ver `DictationSessionState.animationIdentity`.
        .animation(
            DictationBannerTransition.animation,
            value: model.dictation?.state.animationIdentity
        )
        // The expand/collapse of the live transcript rides the same animation — and
        // the same reduce-motion opt-out — as the banner itself: under "Reduce
        // motion" `DictationBannerTransition.animation` is nil and the height simply
        // changes, which is exactly what that setting asks for.
        .animation(
            DictationBannerTransition.animation,
            value: model.dictation?.isTranscriptExpanded
        )
        .frame(width: Metrics.panelWidth, height: Metrics.panelHeight)
        // Con «Reducir transparencia» el cristal se sustituye por una
        // superficie opaca: quien activa ese ajuste no puede leer texto sobre
        // material translúcido, y la app tiene que dejar de ser bonita antes
        // que dejar de ser legible.
        .background {
            if accessibility.reduceTransparency {
                Color(nsColor: .windowBackgroundColor)
            }
        }
        // El canto claro define el borde del panel contra fondos claros, donde
        // el material solo no basta para separarlo de lo que hay detrás.
        .overlay {
            RoundedRectangle(cornerRadius: Metrics.panelCornerRadius, style: .continuous)
                .strokeBorder(
                    Color.white.opacity(accessibility.increaseContrast ? 0.45 : 0.14),
                    lineWidth: 0.5
                )
                .allowsHitTesting(false)
        }
        .onAppear { searchFocused = true }
        // El foco vuelve al campo en cada apertura: el panel se reutiliza entre
        // invocaciones y sin esto la segunda vez no recibiría lo tecleado.
        .onChange(of: model.searchText) { _, _ in searchFocused = true }
    }
}

// MARK: - Separador

/// Línea de un cuarto de punto con margen lateral.
///
/// Un `Divider` de borde a borde trocea el panel en cajas. Con el margen, la
/// línea sugiere la separación sin cortar la superficie.
private struct Hairline: View {
    enum Axis { case horizontal, vertical }
    var axis: Axis = .horizontal

    var body: some View {
        Rectangle()
            .fill(.hairline)
            .frame(
                width: axis == .vertical ? 0.5 : nil,
                height: axis == .horizontal ? 0.5 : nil
            )
            .padding(axis == .horizontal ? .horizontal : .vertical, Metrics.Spacing.regular)
    }
}

// MARK: - Búsqueda

private struct SearchField: View {
    @Binding var text: String
    @FocusState.Binding var focused: Bool
    let count: Int

    var body: some View {
        HStack(spacing: Metrics.Spacing.regular) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: Metrics.IconSize.search, weight: .medium))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)

            TextField(
                String(localized: "search.placeholder", bundle: .localized),
                text: $text
            )
            .textFieldStyle(.plain)
            .font(.system(size: Metrics.FontSize.search, weight: .regular))
            .focused($focused)
            // Sin anillo de foco: el campo es el único elemento enfocable del
            // panel y siempre lo tiene, así que el marco no informa de nada y
            // sobre el cristal se lee como un recuadro negro alrededor del
            // buscador. La accesibilidad no se resiente porque no hay
            // navegación por foco entre controles que seguir.
            .focusEffectDisabled()
            .accessibilityLabel(String(localized: "a11y.search.label", bundle: .localized))
            .accessibilityHint(String(localized: "a11y.search.hint", bundle: .localized))
            // VoiceOver anuncia cuántos resultados hay al cambiar la búsqueda,
            // que es la información que un usuario vidente obtiene de un
            // vistazo a la lista.
            .accessibilityValue(
                String(
                    localized: "a11y.search.results",
                    defaultValue: "\(count) resultados",
                    bundle: .localized
                )
            )

            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    // Es un control, no un adorno: tiene que verse.
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.informational)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(String(localized: "search.clear", bundle: .localized))
                .help(String(localized: "search.clear", bundle: .localized))
            }
        }
        .padding(.horizontal, Metrics.Inset.panel)
        .frame(height: Metrics.searchHeight)
    }
}

// MARK: - Lista

private struct HistoryList: View {
    @Bindable var model: AppModel
    let controller: PanelController
    @Binding var hoveredID: Int64?

    private var accessibility: AccessibilityPreferences { .shared }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 2) {
                    ForEach(Array(model.items.enumerated()), id: \.element.id) { index, item in
                        HistoryRow(
                            item: item,
                            thumbnail: model.thumbnail(for: item),
                            isSelected: index == model.selectedIndex,
                            isHovered: hoveredID == item.id
                        )
                        .id(item.id)
                        .onAppear { model.loadMoreIfNeeded(currentIndex: index) }
                        .onHover { hovering in
                            hoveredID = hovering ? item.id : (hoveredID == item.id ? nil : hoveredID)
                        }
                        .onTapGesture(count: 2) {
                            controller.paste(item: item, plainText: false)
                        }
                        .onTapGesture {
                            model.selectedIndex = index
                        }
                        .contextMenu {
                            RowContextMenu(model: model, controller: controller, item: item)
                        }
                    }
                }
                .padding(.horizontal, Metrics.Inset.list)
                .padding(.vertical, Metrics.Spacing.snug)
            }
            .scrollIndicators(.never)
            .onChange(of: model.selectedIndex) { _, _ in
                guard let item = model.selectedItem else { return }
                withAnimation(accessibility.animation(.ambarQuick)) {
                    proxy.scrollTo(item.id, anchor: .center)
                }
            }
        }
        .accessibilityLabel(String(localized: "a11y.list.label", bundle: .localized))
    }
}

private struct RowContextMenu: View {
    let model: AppModel
    let controller: PanelController
    let item: ClipboardItem

    var body: some View {
        Button(String(localized: "action.paste", bundle: .localized)) {
            controller.paste(item: item, plainText: false)
        }
        Button(String(localized: "action.paste_plain", bundle: .localized)) {
            controller.paste(item: item, plainText: true)
        }
        Divider()
        Button(
            item.pinned
                ? String(localized: "action.unpin", bundle: .localized)
                : String(localized: "action.pin", bundle: .localized)
        ) {
            model.togglePin(item: item)
        }
        Button(String(localized: "action.delete", bundle: .localized), role: .destructive) {
            model.delete(item: item)
        }
    }
}

// MARK: - Estado vacío

private struct EmptyStateView: View {
    let hasQuery: Bool

    var body: some View {
        VStack(spacing: Metrics.Spacing.regular) {
            Image(systemName: hasQuery ? "magnifyingglass" : "doc.on.clipboard")
                .font(.system(size: Metrics.IconSize.empty, weight: .ultraLight))
                .foregroundStyle(Color.decorative)

            VStack(spacing: Metrics.Spacing.tight) {
                Text(
                    hasQuery
                        ? String(localized: "empty.no_results", bundle: .localized)
                        : String(localized: "empty.no_history", bundle: .localized)
                )
                .font(.system(size: Metrics.FontSize.body))
                .foregroundStyle(Color.informationalStrong)

                if !hasQuery {
                    Text(String(localized: "empty.hint", bundle: .localized))
                        .font(.system(size: Metrics.FontSize.caption))
                        .foregroundStyle(Color.informational)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Error

private struct ErrorBanner: View {
    let message: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: Metrics.Spacing.snug) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 10))
            Text(message)
                .font(.system(size: Metrics.FontSize.caption))
                .lineLimit(2)
            Spacer(minLength: 0)
            Button(action: onDismiss) {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    // Diana de 28: un glifo de 9 pt sin marco es hostil, y este es el
                    // único cierre de un aviso que si no se queda hasta reabrir el panel.
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(String(localized: "error.dismiss", bundle: .localized))
        }
        // El naranja del sistema medía **2,31:1** sobre el panel en claro, y 1,86:1 con
        // «Aumentar contraste» —empeora justo con el ajuste que se activa para poder
        // leer—. Muy por debajo del 4,5:1 de AA para texto pequeño, y esta banda es
        // donde el dictado CONFIESA que pudo perder texto (§7.2). El token propio mide
        // 8,59-12,19:1 en las mismas condiciones.
        //
        // El naranja se queda donde no transporta el mensaje: el velo del fondo. Y la
        // advertencia sigue codificada por la forma del icono, no solo por el color.
        .foregroundStyle(Color.informationalStrong)
        .padding(.horizontal, Metrics.Inset.panel)
        .padding(.vertical, Metrics.Spacing.snug)
        .background(Color.orange.opacity(0.12))
        // `.contain` y no `.combine`: con `.combine` el botón de cerrar se fusiona en el
        // elemento padre y **desaparece del orden de lectura**. La otra banda de la app
        // ya lo tenía arreglado; el arreglo no llegó a esta, que es la que sirve la
        // confesión del dictado.
        .accessibilityElement(children: .contain)
        .accessibilityLabel(message)
    }
}

// MARK: - Pie

private struct FooterBar: View {
    let model: AppModel
    @State private var emphasizeWarning = false

    private var accessibility: AccessibilityPreferences { .shared }

    /// ¿Hay un dictado en marcha? Cambia lo que hacen ⏎ y ⌘⌫, así que cambia lo que el pie
    /// puede afirmar sin mentir.
    ///
    /// Se pregunta a `DictationEntryPoints.enterAction`, no a `state.isMicrophoneOpen`
    /// directamente. Las dos hoy dan el mismo resultado, y esa coincidencia es
    /// precisamente el riesgo: el pie y el manejador de teclas (`PanelController.handle`)
    /// leían el estado por su cuenta, cada uno con su propia expresión. Mutar solo
    /// UNA —por ejemplo, esta propiedad, a `false` fijo— no rompía ningún test:
    /// `enterActuallyStopsALiveSession` comprueba que ⏎ para de verdad, y eso seguía
    /// siendo cierto con el pie mintiendo al lado, anunciando «↵ Pegar» mientras ⏎ para el
    /// dictado. Preguntando a la MISMA función que decide qué hace ⏎, los dos no pueden
    /// desincronizarse: si `enterAction` cambia, el pie cambia con ella.
    private var dictationIsListening: Bool {
        guard let state = model.dictation?.state else { return false }
        return DictationEntryPoints.enterAction(for: state) == .stopDictation
    }

    var body: some View {
        HStack(spacing: Metrics.Spacing.loose) {
            if !model.canAutoPaste {
                // Sin permiso la app sigue siendo útil (copia al portapapeles),
                // así que se avisa sin alarmar y se ofrece el camino al ajuste.
                Button {
                    Paster.requestAccessibilityPermission()
                    Paster.openAccessibilitySettings()
                } label: {
                    HStack(spacing: Metrics.Spacing.tight) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 9))
                        Text(String(localized: "permission.needed", bundle: .localized))
                            .font(.system(size: Metrics.FontSize.caption, weight: .medium))
                        Text(String(localized: "permission.action", bundle: .localized))
                            .font(.system(size: Metrics.FontSize.caption))
                            .underline()
                    }
                    // Medido: el naranja del sistema da **2,31:1** sobre el panel en claro
                    // y **1,95:1** con «Aumentar contraste» —empeora con el ajuste que se
                    // activa para poder leer—, muy por debajo del 4,5:1 de AA para texto
                    // pequeño. Es el mismo defecto que se arregló en `ErrorBanner` y que no
                    // llegó a su hermano, y aquí importa especialmente: §9.2 designa este
                    // pie como el único canal de «transcribí y no pude pegar».
                    //
                    // El naranja se queda en el velo del fondo, que es donde no transporta
                    // el mensaje, y la advertencia sigue codificada por la forma del icono.
                    .foregroundStyle(Color.informationalStrong)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: Metrics.chipCornerRadius, style: .continuous)
                            .fill(Color.orange.opacity(emphasizeWarning ? 0.22 : 0))
                    )
                    .scaleEffect(emphasizeWarning ? 1.04 : 1)
                }
                .buttonStyle(.plain)
                .help(String(localized: "permission.help", bundle: .localized))
                .accessibilityHint(String(localized: "permission.help", bundle: .localized))
                // Un intento de pegar sin permiso tiene que verse. Sin esto el
                // panel se cerraría sin más y parecería que la app no responde.
                .onChange(of: model.missingPermissionAttempts) { _, _ in
                    guard !accessibility.reduceMotion else { return }
                    withAnimation(.easeOut(duration: 0.12)) { emphasizeWarning = true }
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(650))
                        withAnimation(.easeIn(duration: 0.25)) { emphasizeWarning = false }
                    }
                }
            } else if dictationIsListening {
                // **Con el micrófono abierto el pie dice otra cosa, porque las teclas hacen
                // otra cosa.** Anunciar «↵ Pegar» mientras ⏎ para el dictado no es un detalle
                // cosmético: es la interfaz mintiendo sobre la única salida que el usuario
                // tiene a mano, y con el modelo nuevo —soltar ya no para— esa salida es lo
                // que hay que enseñar.
                KeyHint(keys: "↵", label: String(localized: "hint.stop_dictation", bundle: .localized))
                KeyHint(keys: "⌘⌫", label: String(localized: "hint.discard_dictation", bundle: .localized))
            } else {
                // Las pistas de teclado son decorativas para VoiceOver: sus acciones ya
                // se anuncian en cada fila, y leerlas en cada recorrido sería ruido. Se
                // ocultan ELLAS, no el pie entero — que es lo que se hacía antes, y con
                // eso el control de captura nuevo habría quedado fuera de alcance.
                KeyHint(keys: "↵", label: String(localized: "hint.paste", bundle: .localized))
                    .accessibilityHidden(true)
                KeyHint(keys: "⌘↵", label: String(localized: "hint.paste_plain", bundle: .localized))
                    .accessibilityHidden(true)
            }

            if !dictationIsListening {
                Group {
                    KeyHint(keys: "⌘P", label: String(localized: "hint.pin", bundle: .localized))
                    KeyHint(keys: "⌘⌫", label: String(localized: "hint.delete", bundle: .localized))
                }
                .accessibilityHidden(true)
            }

            if model.dictation != nil, !dictationIsListening {
                // La única vía de teclado al dictado. Sin anunciarla aquí, la
                // alternativa que el diseño promete es efectivamente secreta.
                // Esta NO se oculta: es la única vía por la que quien usa VoiceOver se
                // entera de que existe un camino de teclado al dictado. Ocultarla —lo que
                // hacía el pie entero cuando había permiso de accesibilidad, o sea en el
                // caso normal— dejaba ⌘D indescubrible.
                KeyHint(keys: "⌘D", label: String(localized: "dictation.start", bundle: .localized))
            }

            Spacer()

            // El control de la captura, en el panel y no enterrado en Ajustes, que es lo
            // que §10 exige: «El control vive en el panel, visible». Lo que había era solo
            // el **indicador**, y solo cuando ya estaba pausado: no había forma de iniciar
            // una pausa sin ir al menú de la barra, y desde Ajustes solo se alcanzaba la
            // indefinida —la variante que §10 señala como propensa al olvido.
            //
            // El selector de modo vive en el mismo menú (§8.5: «ahí mismo viven el
            // interruptor del historial y el selector de modo»), y no en un control aparte:
            // son dos decisiones poco frecuentes y el pie no da para más.
            CaptureMenu(model: model)

            if !model.items.isEmpty {
                Text(
                    String(
                        localized: "footer.count",
                        defaultValue: "\(model.items.count) entradas",
                        bundle: .localized
                    )
                )
                .font(.system(size: Metrics.FontSize.caption))
                .foregroundStyle(Color.informational)
                .monospacedDigit()
            }
        }
        .padding(.horizontal, Metrics.Inset.panel)
        .frame(height: Metrics.footerHeight)
    }
}

/// El control de la captura y del modo de dictado, desde el propio panel.
private struct CaptureMenu: View {
    let model: AppModel

    var body: some View {
        Menu {
            if model.settings.isPaused {
                Button(String(localized: "panel.pause.resume", bundle: .localized)) {
                    model.settings.resumeCapture()
                    model.syncSettingsToServices()
                }
            } else {
                // Las tres duraciones, incluidas las que vuelven solas al estado seguro.
                // Iniciar una pausa era lo único que no se podía hacer desde aquí.
                ForEach(HistoryPause.Duration.allCases, id: \.rawValue) { duration in
                    Button(CaptureMenu.title(for: duration)) {
                        model.settings.pauseCapture(duration)
                        model.syncSettingsToServices()
                    }
                }
            }

            if model.dictation != nil {
                Divider()
                Picker(
                    String(localized: "settings.dictation.mode", bundle: .localized),
                    selection: Binding(
                        get: { model.settings.dictationMode },
                        set: { model.settings.dictationMode = $0 }
                    )
                ) {
                    Text(String(localized: "settings.dictation.mode.live", bundle: .localized))
                        .tag(DictationMode.live)
                    Text(String(localized: "settings.dictation.mode.deferred", bundle: .localized))
                        .tag(DictationMode.deferred)
                }
            }
        } label: {
            Image(systemName: model.settings.isPaused ? "pause.circle.fill" : "pause.circle")
                .font(.system(size: 11))
        }
        // `.borderlessButton` está **deprecado** en macOS desde la 11.0, y el propio SDK
        // dicta la sustitución en el mensaje de deprecación: «Use .menuStyle(.button) and
        // .buttonStyle(.borderless)» (`SwiftUI.swiftinterface:17386`). Era el único
        // símbolo deprecado que quedaba en el árbol; lo encontró una auditoría contra el
        // SDK instalado.
        .menuStyle(.button)
        .buttonStyle(.borderless)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(String(localized: "menu.pause_for", bundle: .localized))
        .accessibilityLabel(String(localized: "menu.pause_for", bundle: .localized))
    }

    static func title(for duration: HistoryPause.Duration) -> String {
        switch duration {
        case .fifteenMinutes: String(localized: "menu.pause_15m", bundle: .localized)
        case .oneHour: String(localized: "menu.pause_1h", bundle: .localized)
        case .untilResumed: String(localized: "menu.pause_until_resumed", bundle: .localized)
        }
    }
}

private struct KeyHint: View {
    let keys: String
    let label: String

    var body: some View {
        HStack(spacing: Metrics.Spacing.tight) {
            Text(keys)
                .font(.system(size: Metrics.FontSize.micro, weight: .medium, design: .rounded))
                .foregroundStyle(Color.informationalStrong)
                .padding(.horizontal, 5)
                .padding(.vertical, 1.5)
                .background(
                    RoundedRectangle(cornerRadius: Metrics.chipCornerRadius, style: .continuous)
                        .fill(Color.primary.opacity(0.07))
                )
            Text(label)
                .font(.system(size: Metrics.FontSize.caption))
                .foregroundStyle(Color.informational)
        }
    }
}

/// Aviso de que la captura está pausada, con cuánto queda y cómo reanudar.
///
/// Creerse en pausa sin estarlo —o al revés— es un problema real de privacidad, no
/// un detalle de interfaz: por eso vive en el panel y no enterrado en Ajustes.
private struct PauseChip: View {
    let remaining: TimeInterval?
    let onResume: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "pause.circle.fill")
                .foregroundStyle(Color.informationalStrong)
                .accessibilityHidden(true)

            Text(label)
                .font(.system(size: 11))
                .foregroundStyle(Color.informationalStrong)

            Spacer()

            Button(String(localized: "panel.pause.resume", bundle: .localized), action: onResume)
                .buttonStyle(.remedy)
                .font(.system(size: 11))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    private var label: String {
        guard let remaining else {
            return String(localized: "panel.pause.indefinite", bundle: .localized)
        }
        let minutes = max(1, Int((remaining / 60).rounded()))
        return String(
            format: String(localized: "panel.pause.remaining", bundle: .localized),
            minutes
        )
    }
}

/// Cuándo se ofrecen las puertas del dictado que no exigen mantener una tecla.
///
/// Extraído a funciones puras porque las dos —el botón y ⌘D— se podían **borrar** sin
/// que ningún test fallara, y son el único camino de quien no puede sostener un atajo.
/// Es la misma clase de defecto —un llamador que falta— que las rondas anteriores
/// encontraron a mano tres veces.
enum DictationEntryPoints {
    /// El botón de micrófono se ve salvo cuando ya se está escuchando (ahí manda el
    /// control de parar de la banda). Durante la cuenta **sigue visible**: ocultarlo
    /// hacía desaparecer la puerta justo mientras el atajo estaba pulsado.
    static func showsMicrophoneButton(for state: DictationSessionState) -> Bool {
        !state.isMicrophoneOpen
    }

    /// ⌘D arranca, para o descarta según el estado.
    ///
    /// En `.preparing` y `.finalizing` no puede arrancar ni parar, y antes no hacía
    /// nada en silencio: descartar es la respuesta útil, porque son justo los estados
    /// en los que el usuario quiere salirse.
    static func commandDAction(for state: DictationSessionState) -> Action {
        switch state {
        case .listening: .stop
        case .preparing, .finalizing, .arming: .discard
        case .idle, .delivered, .failed: .start
        }
    }

    /// ¿Se pinta la banda del dictado?
    ///
    /// Nombrado aquí y no en la vista para que la elección de predicado sea afirmable: el
    /// gate usaba `deservesDisplay` y cambiarlo por `isActive` —que parece equivalente y
    /// no lo es— no rompía ningún test. La diferencia es justo el bloqueante de la ronda
    /// 1: con `isActive`, **los fallos no se pintan** y el dictado vuelve a fallar en
    /// silencio.
    static func showsBanner(for state: DictationSessionState) -> Bool {
        state.deservesDisplay
    }

    /// ¿Se ofrece el control de parar?
    ///
    /// Solo con el micrófono abierto, y **siempre** que esté abierto: es la única salida
    /// visible cuando el gesto no puede terminar —una tecla enclavada por Teclas
    /// Especiales, un teclado que reporta un modificador hundido—.
    static func showsStopControl(for state: DictationSessionState) -> Bool {
        state.isMicrophoneOpen
    }

    enum Action: Equatable { case start, stop, discard }

    /// Qué hace ⏎ según lo que esté pasando.
    ///
    /// Con el micrófono abierto **para el dictado**; es la salida natural del modelo de
    /// interacción actual, donde el gesto solo arranca. Sin sesión viva sigue siendo pegar la
    /// entrada seleccionada del historial, que es lo que ⏎ ha hecho siempre en este panel.
    static func enterAction(for state: DictationSessionState) -> EnterAction {
        state.isMicrophoneOpen ? .stopDictation : .pasteSelection
    }

    enum EnterAction: Equatable { case stopDictation, pasteSelection }

    /// Qué hace ⌘⌫ según lo que esté pasando.
    ///
    /// Con el micrófono abierto **descarta el dictado**. Antes no había ninguna ruta de
    /// teclado para descartar: ⏎ y ⌘D paran, y parar **entrega y pega**. Es decir, quien
    /// disparara el gesto sin querer y buscara la tecla obvia para cortar, pegaba en el
    /// documento — y con el modelo nuevo soltar tampoco aborta, así que la única salida era
    /// ⎋, que nada anuncia.
    static func deleteAction(for state: DictationSessionState) -> DeleteAction {
        state.isMicrophoneOpen ? .discardDictation : .deleteSelection
    }

    enum DeleteAction: Equatable { case discardDictation, deleteSelection }

    /// Qué abre ⌘, según lo que haya en pantalla.
    ///
    /// Los dos botones de remedio del banner —«Abrir Ajustes del Sistema» para el
    /// permiso y «Abrir Ajustes» para el modelo o el cupo— solo se podían pulsar con el
    /// ratón. El panel declara **un único elemento enfocable**, el campo de búsqueda, y
    /// su monitor de teclas se queda con los `keyDown`, así que el tabulador no llega a
    /// ellos. Quien no usa ratón veía el fallo y no tenía forma de arreglarlo.
    ///
    /// ⌘, es el atajo canónico de ajustes en macOS, y aquí abre **los que resuelven el
    /// fallo que se está mostrando**. Sin fallo abre los de Ámbar, que es lo que ⌘,
    /// hace en cualquier app y que el panel tampoco ofrecía.
    static func settingsShortcutTarget(
        state: DictationSessionState?,
        failure: DictationFailure?
    ) -> SettingsTarget {
        guard case .failed = state else { return .appSettings }
        switch failure {
        case .permissionDenied: return .systemMicrophone
        default: return .appSettings
        }
    }

    enum SettingsTarget: Equatable {
        /// El panel del sistema donde se concede el micrófono.
        case systemMicrophone
        /// Los ajustes de Ámbar.
        case appSettings
    }
}
