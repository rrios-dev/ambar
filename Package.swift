// swift-tools-version: 6.2
import PackageDescription

// Ámbar + ForgeKit — ecosistema nativo del monorepo Forge.
//
// Un único Package.swift multi-target: los targets cuestan casi cero en tiempo
// de build y ya aíslan dependencias (un target no puede importar lo que no
// declara). Se promueven a paquetes independientes cuando aparezca un segundo
// consumidor; hacerlo al revés no es trivial.
//
// Este grafo es paralelo al de Bun/Turbo: `native/` queda fuera del glob de
// workspaces del monorepo. Ver docs/architecture/native-platform.md.

let package = Package(
    name: "Ambar",
    defaultLocalization: "es",
    platforms: [.macOS(.v26)],
    products: [
        .executable(name: "Ambar", targets: ["Ambar"]),
        .library(name: "BlobStore", targets: ["BlobStore"]),
        .library(name: "ClipboardKit", targets: ["ClipboardKit"]),
        .library(name: "GlassUI", targets: ["GlassUI"]),
        .library(name: "AppCore", targets: ["AppCore"]),
        .library(name: "VoiceKit", targets: ["VoiceKit"]),
    ],
    targets: [
        // Almacén de binarios direccionado por contenido (SHA-256) + thumbnails.
        // Sin dependencias: sirve a cualquier app que guarde blobs.
        .target(
            name: "BlobStore",
            path: "packages/BlobStore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // Captura del portapapeles, modelo de datos y persistencia SQLite/FTS5.
        .target(
            name: "ClipboardKit",
            dependencies: ["BlobStore"],
            path: "packages/ClipboardKit",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // Primitivos visuales Liquid Glass reusables — el germen de un
        // "Poesía nativo". Sin relación de código con el Poesía web.
        .target(
            name: "GlassUI",
            path: "packages/GlassUI",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // Dictado por voz. Aislado a propósito: decide cuándo se abre el
        // micrófono, y cuanta menos superficie tenga, menos hay que auditar. La app lo enlaza pero **no depende de él para arrancar**:
        // con la función apagada no se instancia nada.
        //
        // No se llama `Dictation` para no colisionar con `DictationTranscriber`
        // del sistema al leer los imports.
        .target(
            name: "VoiceKit",
            path: "packages/VoiceKit",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // Servicios de app de escritorio: hotkeys, pegado, arranque al inicio.
        .target(
            name: "AppCore",
            path: "packages/AppCore",
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        // La app. Delgada: wiring + UI propia.
        .executableTarget(
            name: "Ambar",
            dependencies: ["BlobStore", "ClipboardKit", "GlassUI", "AppCore", "VoiceKit"],
            path: "apps/Ambar",
            // El icono lo coloca el script de empaquetado directamente en
            // Contents/Resources; incluirlo además como recurso del target
            // duplicaría 1,4 MB dentro del bundle.
            exclude: [
                "Info.plist", "Ambar.entitlements",
                "Resources/AppIcon.icns",
                // Material fuente del icono: lo consume Icon Composer, no la app.
                "Resources/IconSource",
            ],
            resources: [.process("Resources")],
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),

        .testTarget(
            name: "BlobStoreTests",
            dependencies: ["BlobStore"],
            path: "Tests/BlobStoreTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "ClipboardKitTests",
            dependencies: ["ClipboardKit", "BlobStore"],
            path: "Tests/ClipboardKitTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "GlassUITests",
            dependencies: ["GlassUI"],
            path: "Tests/GlassUITests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "AppCoreTests",
            dependencies: ["AppCore"],
            path: "Tests/AppCoreTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "VoiceKitTests",
            dependencies: ["VoiceKit"],
            path: "Tests/VoiceKitTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        // Tests de la app. El ejecutable se puede importar con `@testable`, y hacía
        // falta: el coordinador del dictado era la única pieza sin cobertura.
        .testTarget(
            name: "AmbarTests",
            dependencies: ["Ambar", "VoiceKit", "AppCore"],
            path: "Tests/AmbarTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
