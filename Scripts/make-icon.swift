#!/usr/bin/env swift
//
// Genera AppIcon.icns.
//
// El icono se dibuja por código y no se guarda como binario en el repo: así se
// puede ajustar el diseño en un diff legible en vez de sustituir un blob.
//
//   swift Scripts/make-icon.swift
//
import AppKit
import Foundation

// Ámbar: resina fósil sobre fondo de noche.
//
// El icono anterior era un squircle ÁMBAR con una gota BLANCA encima. Se
// cambió con la marca de la web (2026-08-22) por dos motivos medidos allí: la
// gota blanca se comía el color que da nombre al producto, y a tamaño de
// pestaña o de Dock pequeño lo que quedaba era una mancha naranja sin silueta.
//
// Ahora manda la gota, en ámbar, sobre un fondo oscuro que la deja brillar —
// y lleva dentro una INCLUSIÓN, que es lo que distingue el ámbar de una gota
// cualquiera: la resina atrapa algo y lo conserva intacto, que es exactamente
// lo que hace la app con lo que copias.
let deepAmber = NSColor(srgbRed: 0.63, green: 0.34, blue: 0.04, alpha: 1)
let midAmber = NSColor(srgbRed: 0.96, green: 0.65, blue: 0.14, alpha: 1)
let brightAmber = NSColor(srgbRed: 1.00, green: 0.84, blue: 0.60, alpha: 1)
/// El fondo: negro cálido, no negro neutro. Un gris azulado debajo del ámbar
/// lo enfría y lo deja pareciendo naranja de aviso.
let nightTop = NSColor(srgbRed: 0.165, green: 0.110, blue: 0.024, alpha: 1)
let nightBottom = NSColor(srgbRed: 0.078, green: 0.047, blue: 0.008, alpha: 1)
/// La inclusión, y el reflejo dentro de la gota.
let inclusion = NSColor(srgbRed: 0.13, green: 0.06, blue: 0.01, alpha: 1)
let sheen = NSColor(srgbRed: 1.0, green: 0.97, blue: 0.93, alpha: 1)

func drawIcon(size: CGFloat) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size))
    image.lockFocus()

    let context = NSGraphicsContext.current!.cgContext
    context.setShouldAntialias(true)
    context.interpolationQuality = .high

    // El lienzo lleva margen: macOS espera que el arte no llegue al borde.
    let inset = size * 0.055
    let rect = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)

    // Squircle, la forma de icono del sistema.
    let radius = rect.width * 0.2237
    let shape = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

    context.saveGState()
    shape.addClip()

    // El fondo de noche.
    NSGradient(colors: [nightTop, nightBottom])!.draw(in: rect, angle: -90)

    // Y un halo de ámbar detrás de la gota: sin él el fondo es un rectángulo
    // negro y el icono parece un sello, no una piedra iluminada por dentro.
    context.saveGState()
    NSGradient(
        colors: [midAmber.withAlphaComponent(0.22), midAmber.withAlphaComponent(0.0)],
        atLocations: [0.0, 1.0],
        colorSpace: .sRGB
    )!.draw(
        fromCenter: NSPoint(x: rect.midX, y: rect.midY - rect.height * 0.02),
        radius: 0,
        toCenter: NSPoint(x: rect.midX, y: rect.midY - rect.height * 0.02),
        radius: rect.width * 0.46,
        options: []
    )
    context.restoreGState()

    // La gota. Punta arriba, panza abajo: es como cae la resina, y es lo que
    // hace la silueta reconocible a cualquier tamaño.
    let dropWidth = rect.width * 0.50
    let dropHeight = rect.height * 0.62
    let dropX = rect.midX - dropWidth / 2
    let dropY = rect.midY - dropHeight / 2 - rect.height * 0.03

    let drop = NSBezierPath()
    drop.move(to: NSPoint(x: dropX + dropWidth / 2, y: dropY + dropHeight))
    drop.curve(
        to: NSPoint(x: dropX + dropWidth, y: dropY + dropHeight * 0.32),
        controlPoint1: NSPoint(x: dropX + dropWidth * 0.62, y: dropY + dropHeight * 0.82),
        controlPoint2: NSPoint(x: dropX + dropWidth, y: dropY + dropHeight * 0.60)
    )
    drop.curve(
        to: NSPoint(x: dropX + dropWidth / 2, y: dropY),
        controlPoint1: NSPoint(x: dropX + dropWidth, y: dropY + dropHeight * 0.13),
        controlPoint2: NSPoint(x: dropX + dropWidth * 0.79, y: dropY)
    )
    drop.curve(
        to: NSPoint(x: dropX, y: dropY + dropHeight * 0.32),
        controlPoint1: NSPoint(x: dropX + dropWidth * 0.21, y: dropY),
        controlPoint2: NSPoint(x: dropX, y: dropY + dropHeight * 0.13)
    )
    drop.curve(
        to: NSPoint(x: dropX + dropWidth / 2, y: dropY + dropHeight),
        controlPoint1: NSPoint(x: dropX, y: dropY + dropHeight * 0.60),
        controlPoint2: NSPoint(x: dropX + dropWidth * 0.38, y: dropY + dropHeight * 0.82)
    )
    drop.close()

    // Degradado dentro de la gota: la luz entra por arriba a la izquierda, la
    // misma dirección que el reflejo y que el canto del squircle. Tres luces
    // en tres direcciones distintas es lo que hace que un icono parezca un
    // collage.
    context.saveGState()
    drop.addClip()
    NSGradient(colors: [brightAmber, midAmber, deepAmber])!.draw(
        in: NSRect(x: dropX, y: dropY, width: dropWidth, height: dropHeight),
        angle: -70
    )
    context.restoreGState()

    // La inclusión: lo que la resina atrapó.
    let seed = NSBezierPath(
        ovalIn: NSRect(
            x: dropX + dropWidth * 0.40,
            y: dropY + dropHeight * 0.22,
            width: dropWidth * 0.30,
            height: dropHeight * 0.19
        )
    )
    var transform = AffineTransform(translationByX: dropX + dropWidth * 0.55, byY: dropY + dropHeight * 0.315)
    transform.rotate(byDegrees: -18)
    transform.translate(x: -(dropX + dropWidth * 0.55), y: -(dropY + dropHeight * 0.315))
    seed.transform(using: transform)
    inclusion.withAlphaComponent(0.50).setFill()
    seed.fill()

    // El reflejo alto: lee la gota como volumen translúcido y no como recorte.
    let sparkle = NSBezierPath(
        ovalIn: NSRect(
            x: dropX + dropWidth * 0.19,
            y: dropY + dropHeight * 0.50,
            width: dropWidth * 0.20,
            height: dropHeight * 0.24
        )
    )
    sheen.withAlphaComponent(0.34).setFill()
    sparkle.fill()

    context.restoreGState()

    // Filo claro en el borde, como el canto de un cristal.
    NSColor.white.withAlphaComponent(0.16).setStroke()
    shape.lineWidth = max(1, size * 0.005)
    shape.stroke()

    image.unlockFocus()
    return image
}

func png(from image: NSImage, pixels: Int) -> Data? {
    guard let representation = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { return nil }

    representation.size = NSSize(width: pixels, height: pixels)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: representation)
    image.draw(
        in: NSRect(x: 0, y: 0, width: pixels, height: pixels),
        from: .zero,
        operation: .sourceOver,
        fraction: 1
    )
    NSGraphicsContext.restoreGraphicsState()

    return representation.representation(using: .png, properties: [:])
}

// El iconset intermedio va a un temporal: en el repo solo queda el .icns final.
let iconset = FileManager.default.temporaryDirectory
    .appending(path: "AmbarAppIcon-\(UUID().uuidString).iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

// Los nombres son los que exige iconutil; no se pueden inventar.
let variants: [(name: String, pixels: Int)] = [
    ("icon_16x16", 16), ("icon_16x16@2x", 32),
    ("icon_32x32", 32), ("icon_32x32@2x", 64),
    ("icon_128x128", 128), ("icon_128x128@2x", 256),
    ("icon_256x256", 256), ("icon_256x256@2x", 512),
    ("icon_512x512", 512), ("icon_512x512@2x", 1024),
]

for variant in variants {
    let image = drawIcon(size: CGFloat(variant.pixels))
    guard let data = png(from: image, pixels: variant.pixels) else {
        FileHandle.standardError.write(Data("No se pudo generar \(variant.name)\n".utf8))
        exit(1)
    }
    try data.write(to: iconset.appending(path: "\(variant.name).png"))
}

// Se invoca iconutil aquí mismo para que el script deje el artefacto final y
// no un paso intermedio que haya que recordar.
let destination = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appending(path: "apps/Ambar/Resources/AppIcon.icns")

let process = Process()
process.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
process.arguments = ["-c", "icns", iconset.path, "-o", destination.path]
try process.run()
process.waitUntilExit()

try? FileManager.default.removeItem(at: iconset)

guard process.terminationStatus == 0 else {
    FileHandle.standardError.write(Data("iconutil falló\n".utf8))
    exit(1)
}

print("✓ \(destination.path)")
