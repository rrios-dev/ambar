import AppCore
import ClipboardKit
import GlassUI
import SwiftUI
import VoiceKit

/// Ventana de ajustes.
struct SettingsView: View {
    @Bindable var model: AppModel
    @State private var newBundleID = ""
    @State private var storageDescription = "—"

    private var settings: Settings { model.settings }

    var body: some View {
        Form {
            Section(String(localized: "settings.general", bundle: .localized)) {
                LabeledContent(String(localized: "settings.hotkey", bundle: .localized)) {
                    ShortcutRecorder(
                        combination: Binding(
                            get: { settings.hotKey },
                            set: { newValue in
                                settings.hotKey = newValue
                                // Sin esto el ajuste se guardaría pero el
                                // sistema seguiría escuchando el atajo viejo.
                                model.reloadHotKey()
                            }
                        )
                    )
                }

                // Si el atajo no pudo registrarse, aquí es donde se arregla: cambiándolo.
                if model.isHotKeyUnavailable {
                    Text(String(localized: "hotkey.unavailable", bundle: .localized))
                        .font(.system(size: 11))
                        .foregroundStyle(.orange)
                }

                Toggle(
                    String(localized: "settings.launch_at_login", bundle: .localized),
                    isOn: Binding(
                        get: { settings.launchAtLogin },
                        set: { settings.launchAtLogin = $0 }
                    )
                )
                // Nombre explícito para VoiceOver. Medido en el árbol real de esta ventana: dentro
                // de un `Form` agrupado, SwiftUI pinta el rótulo como texto suelto y deja la casilla
                // **sin nombre** (`AXCheckBox 36x16` vacío), así que se anuncia «casilla» y ya. Con el
                // rótulo separado del control, quien recorre la ventana no sabe cuál está tocando.
                .accessibilityLabel(String(localized: "settings.launch_at_login", bundle: .localized))

                Toggle(
                    String(localized: "settings.pause", bundle: .localized),
                    isOn: Binding(
                        get: { settings.isPaused },
                        set: {
                            settings.isPaused = $0
                            model.syncSettingsToServices()
                        }
                    )
                )
                // Nombre explícito para VoiceOver. Medido en el árbol real de esta ventana: dentro
                // de un `Form` agrupado, SwiftUI pinta el rótulo como texto suelto y deja la casilla
                // **sin nombre** (`AXCheckBox 36x16` vacío), así que se anuncia «casilla» y ya. Con el
                // rótulo separado del control, quien recorre la ventana no sabe cuál está tocando.
                .accessibilityLabel(String(localized: "settings.pause", bundle: .localized))

                // Cerrar la presentación cuenta como vista, para no insistir en cada
                // arranque. Este botón es la contrapartida de esa decisión: sin él, quien la
                // cierra antes de leerla no tiene forma de recuperarla.
                Button(String(localized: "onboarding.replay", bundle: .localized)) {
                    model.onReplayOnboarding?()
                }
            }

            // La consulta de la oferta cuelga de la SECCIÓN, no de la nota.
            //
            // Colgaba de `DictationOfferNote`, y con la oferta sin comprobar el `body` de
            // esa vista resuelve a `EmptyView` — que **no recibe `.task` ni `.onAppear`**
            // (medido con un arnés que replica la estructura). Era un cierre sobre sí
            // mismo: lo único que poblaba la oferta era un modificador que solo corría si
            // la oferta ya estaba poblada. Consecuencia: abrir Ajustes con el dictado
            // apagado no decía **nada** —ni «falta instalar el modelo (X MB)» con su
            // botón, ni «tu idioma no está admitido», ni «no hay permiso»— y el único
            // productor real de la oferta era darle al interruptor.
            Section(String(localized: "settings.dictation", bundle: .localized)) {
                Toggle(
                    String(localized: "settings.dictation.enabled", bundle: .localized),
                    isOn: Binding(
                        get: { settings.isDictationEnabled },
                        set: { wanted in
                            guard wanted else {
                                // Cierra la sesión viva: apagar la función con el
                                // micrófono abierto lo dejaba abierto.
                                model.disableDictation()
                                return
                            }
                            // Activar es lo que pide el permiso. Nunca el gesto.
                            Task { await model.enableDictation() }
                        }
                    )
                )
                // Nombre explícito para VoiceOver. Medido en el árbol real de esta ventana: dentro
                // de un `Form` agrupado, SwiftUI pinta el rótulo como texto suelto y deja la casilla
                // **sin nombre** (`AXCheckBox 36x16` vacío), así que se anuncia «casilla» y ya. Con el
                // rótulo separado del control, quien recorre la ventana no sabe cuál está tocando.
                .accessibilityLabel(String(localized: "settings.dictation.enabled", bundle: .localized))
                .disabled(model.isRequestingMicrophone)

                // Qué falta, si falta algo. Un interruptor que se enciende y no
                // funciona es peor que uno que explica por qué no puede.
                DictationOfferNote(offer: model.dictationOffer, model: model)
                Text(String(localized: "settings.dictation.help", bundle: .localized))
                    .font(.system(size: 11))
                    .foregroundStyle(Color.informational)

                if settings.isDictationEnabled {
                    Toggle(
                        String(localized: "settings.dictation.hold", bundle: .localized),
                        isOn: Binding(
                            get: { settings.isHoldGestureEnabled },
                            set: { settings.isHoldGestureEnabled = $0 }
                        )
                    )
                    // Nombre explícito para VoiceOver. Medido en el árbol real de esta ventana: dentro
                    // de un `Form` agrupado, SwiftUI pinta el rótulo como texto suelto y deja la casilla
                    // **sin nombre** (`AXCheckBox 36x16` vacío), así que se anuncia «casilla» y ya. Con el
                    // rótulo separado del control, quien recorre la ventana no sabe cuál está tocando.
                    .accessibilityLabel(String(localized: "settings.dictation.hold", bundle: .localized))
                    Text(String(localized: "settings.dictation.hold_help", bundle: .localized))
                        .font(.system(size: 11))
                        .foregroundStyle(Color.informational)

                    Toggle(
                        String(localized: "settings.dictation.atypical", bundle: .localized),
                        isOn: Binding(
                            get: { settings.isAtypicalSpeechEnabled },
                            set: { settings.isAtypicalSpeechEnabled = $0 }
                        )
                    )
                    // Nombre explícito para VoiceOver. Medido en el árbol real de esta ventana: dentro
                    // de un `Form` agrupado, SwiftUI pinta el rótulo como texto suelto y deja la casilla
                    // **sin nombre** (`AXCheckBox 36x16` vacío), así que se anuncia «casilla» y ya. Con el
                    // rótulo separado del control, quien recorre la ventana no sabe cuál está tocando.
                    .accessibilityLabel(String(localized: "settings.dictation.atypical", bundle: .localized))
                    Text(String(localized: "settings.dictation.atypical_help", bundle: .localized))
                        .font(.system(size: 11))
                        .foregroundStyle(Color.informational)

                    // La medición: lo que hace real la recomendación de modo. Sin ella,
                    // la oferta nunca puede advertir de que la máquina va justa.
                    HStack(spacing: 6) {
                        Button(String(localized: "settings.dictation.measure", bundle: .localized)) {
                            Task { await model.measureCapability() }
                        }
                        .buttonStyle(.remedy)
                        .disabled(model.isMeasuringCapability)
                        if model.isMeasuringCapability {
                            Text(String(localized: "settings.dictation.measuring", bundle: .localized))
                                .font(.system(size: 11))
                                .foregroundStyle(Color.informational)
                        }
                        if let error = model.capabilityError {
                            Text(error)
                                .font(.system(size: 11))
                                .foregroundStyle(Color.informationalStrong)
                        }
                    }
                    Text(String(localized: "settings.dictation.measure_help", bundle: .localized))
                        .font(.system(size: 11))
                        .foregroundStyle(Color.informational)

                    Picker(
                        String(localized: "settings.dictation.mode", bundle: .localized),
                        selection: Binding(
                            get: { settings.dictationMode },
                            set: {
                                settings.dictationMode = $0
                                // El estado del modelo depende del módulo configurado,
                                // así que cambiar de modo puede cambiar la oferta.
                                Task { await model.refreshDictationOffer() }
                            }
                        )
                    ) {
                        Text(String(localized: "settings.dictation.mode.live", bundle: .localized))
                            .tag(DictationMode.live)
                        Text(String(localized: "settings.dictation.mode.deferred", bundle: .localized))
                            .tag(DictationMode.deferred)
                    }
                }
            }
            .task { await model.refreshDictationOffer() }

            DictionarySection(model: model)

            Section(String(localized: "settings.recognition", bundle: .localized)) {
                Toggle(
                    String(localized: "settings.ocr", bundle: .localized),
                    isOn: Binding(
                        get: { settings.isOCREnabled },
                        set: { settings.isOCREnabled = $0 }
                    )
                )
                // Nombre explícito para VoiceOver. Medido en el árbol real de esta ventana: dentro
                // de un `Form` agrupado, SwiftUI pinta el rótulo como texto suelto y deja la casilla
                // **sin nombre** (`AXCheckBox 36x16` vacío), así que se anuncia «casilla» y ya. Con el
                // rótulo separado del control, quien recorre la ventana no sabe cuál está tocando.
                .accessibilityLabel(String(localized: "settings.ocr", bundle: .localized))
                Text(String(localized: "settings.ocr_help", bundle: .localized))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Section(String(localized: "settings.retention", bundle: .localized)) {
                Stepper(
                    value: Binding(
                        get: { settings.retentionDays },
                        set: { settings.retentionDays = $0 }
                    ),
                    in: 0...365,
                    step: 5
                ) {
                    Text(
                        settings.retentionDays == 0
                            ? String(localized: "settings.retention.unlimited", bundle: .localized)
                            : String(
                                localized: "settings.retention.days",
                                defaultValue: "Conservar \(settings.retentionDays) días",
                                bundle: .localized
                            )
                    )
                }

                Stepper(
                    value: Binding(
                        get: { settings.retentionGigabytes },
                        set: { settings.retentionGigabytes = $0 }
                    ),
                    in: 0...50,
                    step: 0.5
                ) {
                    Text(
                        settings.retentionGigabytes == 0
                            ? String(localized: "settings.storage.unlimited", bundle: .localized)
                            : String(
                                localized: "settings.storage.limit",
                                defaultValue: "Máximo \(settings.retentionGigabytes, specifier: "%.1f") GB",
                                bundle: .localized
                            )
                    )
                }

                LabeledContent(
                    String(localized: "settings.storage.current", bundle: .localized),
                    value: storageDescription
                )

                Button(String(localized: "settings.purge_now", bundle: .localized)) {
                    Task {
                        await model.applyRetention()
                        updateStorageDescription()
                    }
                }
            }

            Section(String(localized: "settings.privacy", bundle: .localized)) {
                Text(String(localized: "settings.privacy_help", bundle: .localized))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                ForEach(settings.excludedBundleIDs, id: \.self) { bundleID in
                    HStack {
                        Text(bundleID)
                            .font(.system(size: 11, design: .monospaced))
                        Spacer()
                        Button {
                            settings.excludedBundleIDs.removeAll { $0 == bundleID }
                            model.syncSettingsToServices()
                        } label: {
                            Image(systemName: "minus.circle")
                                // El glifo mide 13×13 y el área pulsable se ajustaba a él:
                                // por debajo del mínimo de 14 pt que este proyecto se exige, y
                                // un objetivo de ese tamaño se falla. Lo destapó el gate de
                                // accesibilidad al empezar a mirar la ventana de Ajustes.
                                //
                                // `contentShape` es lo que hace pulsable el marco entero y no
                                // solo el dibujo del símbolo: sin ella, agrandar el marco
                                // cambia la separación y deja el objetivo igual de pequeño.
                                .frame(width: 22, height: 22)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }

                HStack {
                    TextField(
                        String(localized: "settings.add_bundle", bundle: .localized),
                        text: $newBundleID
                    )
                    .font(.system(size: 11, design: .monospaced))

                    Button(String(localized: "settings.add", bundle: .localized)) {
                        let trimmed = newBundleID.trimmingCharacters(in: .whitespaces)
                        guard !trimmed.isEmpty, !settings.excludedBundleIDs.contains(trimmed) else { return }
                        settings.excludedBundleIDs.append(trimmed)
                        model.syncSettingsToServices()
                        newBundleID = ""
                    }
                    .disabled(newBundleID.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }

            Section(String(localized: "settings.permissions", bundle: .localized)) {
                HStack {
                    Image(systemName: model.canAutoPaste ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(model.canAutoPaste ? .green : .orange)
                    Text(
                        model.canAutoPaste
                            ? String(localized: "settings.accessibility.granted", bundle: .localized)
                            : String(localized: "settings.accessibility.missing", bundle: .localized)
                    )
                    Spacer()
                    if !model.canAutoPaste {
                        // **Dos botones, y el primero es el que faltaba.** Aquí solo había
                        // «Abrir Ajustes», que lleva a una lista donde la app puede no estar:
                        // igual que con el micrófono, macOS enumera en Accesibilidad lo que ha
                        // **solicitado** el permiso, y solicitarlo es justo lo que hace
                        // `requestAccessibilityPermission`. Sin este botón, la única forma de
                        // registrarse era el primer arranque de la app.
                        Button(String(localized: "permission.grant", bundle: .localized)) {
                            Paster.requestAccessibilityPermission()
                            // El diálogo del sistema se responde fuera de la app y macOS no
                            // avisa: sin el sondeo, esta sección seguiría diciendo que falta
                            // el permiso después de haberlo concedido.
                            model.refreshPermissionState()
                        }
                        Button(String(localized: "settings.open_settings", bundle: .localized)) {
                            Paster.openAccessibilitySettings()
                        }
                    }
                }
                Text(String(localized: "settings.accessibility_help", bundle: .localized))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                // Concedido con la app en marcha: el sistema puede no aplicarlo hasta que el
                // proceso se reinicie, y desde fuera eso se ve como «di el permiso y sigue sin
                // pegar». Se ofrece el reinicio en vez de dejar al usuario adivinando.
                if model.grantedWhileRunning {
                    HStack(spacing: 6) {
                        Text(String(localized: "permission.restart_needed", bundle: .localized))
                            .font(.system(size: 11))
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                        Button(String(localized: "permission.restart", bundle: .localized)) {
                            model.restart()
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460, height: 620)
        .onAppear {
            updateStorageDescription()
            model.refreshPermissionState()
        }
    }

    private func updateStorageDescription() {
        guard let store = model.store, let bytes = try? store.blobs.totalBytes() else {
            storageDescription = "—"
            return
        }
        let count = (try? store.count()) ?? 0
        let formatted = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        storageDescription = String(
            localized: "settings.storage.value",
            defaultValue: "\(formatted) · \(count) entradas",
            bundle: .localized
        )
    }
}
