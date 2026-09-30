#!/usr/bin/env swift
//
// Genera el fondo de la ventana del DMG.
//
// Por código y no como binario en el repo, por lo mismo que el icono: el diseño se ajusta
// en un diff legible en vez de sustituir un blob.
//
//   swift Scripts/make-dmg-background.swift <ruta-de-salida.png>
//
// **Sin una sola palabra.** El DMG es un único artefacto para los diez idiomas, y el fondo
// es una imagen: un texto pintado aquí saldría en español a un usuario japonés y no habría
// forma de traducirlo. Lo que tiene que comunicar —«arrastra esto ahí»— lo dice la flecha.
//
import AppKit
import Foundation

// El mismo ámbar del icono, muy rebajado: el fondo tiene que dejar leer los dos iconos que
// van encima, no competir con ellos.
let warmTop = NSColor(srgbRed: 0.99, green: 0.96, blue: 0.91, alpha: 1)
let warmBottom = NSColor(srgbRed: 0.96, green: 0.90, blue: 0.80, alpha: 1)
let arrowColor = NSColor(srgbRed: 0.62, green: 0.42, blue: 0.14, alpha: 0.55)

/// Medidas en puntos. La ventana del DMG se abre con este tamaño exacto, y las posiciones de
/// los iconos que fija `make-dmg.sh` están calculadas contra estas coordenadas: si cambia
/// una, hay que cambiar las dos.
let width: CGFloat = 620
let height: CGFloat = 400

func drawBackground(scale: CGFloat) -> NSBitmapImageRep? {
    let pixelsWide = Int(width * scale)
    let pixelsHigh = Int(height * scale)

    guard let representation = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixelsWide,
        pixelsHigh: pixelsHigh,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { return nil }

    representation.size = NSSize(width: width, height: height)

    NSGraphicsContext.saveGraphicsState()
    guard let context = NSGraphicsContext(bitmapImageRep: representation) else {
        NSGraphicsContext.restoreGraphicsState()
        return nil
    }
    NSGraphicsContext.current = context
    context.cgContext.setShouldAntialias(true)

    let rect = NSRect(x: 0, y: 0, width: width, height: height)
    NSGradient(starting: warmBottom, ending: warmTop)?.draw(in: rect, angle: 90)

    // La flecha, del icono de la app hacia la carpeta Aplicaciones. Va a la altura de los
    // dos iconos y ocupa el hueco entre ellos, sin llegar a tocarlos.
    let iconCenterY = height - 170
    let start = NSPoint(x: 250, y: iconCenterY)
    let end = NSPoint(x: 370, y: iconCenterY)
    let shaft = NSBezierPath()
    shaft.move(to: start)
    shaft.line(to: NSPoint(x: end.x - 18, y: end.y))
    shaft.lineWidth = 6
    shaft.lineCapStyle = .round
    arrowColor.setStroke()
    shaft.stroke()

    let head = NSBezierPath()
    head.move(to: end)
    head.line(to: NSPoint(x: end.x - 22, y: end.y + 13))
    head.line(to: NSPoint(x: end.x - 22, y: end.y - 13))
    head.close()
    arrowColor.setFill()
    head.fill()

    NSGraphicsContext.restoreGraphicsState()
    return representation
}

// El fondo se guarda a 2× y con la `size` en puntos: el Finder lo escala a la ventana, y a
// 1× la flecha se ve blanda en cualquier pantalla moderna.
guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("uso: make-dmg-background.swift <salida.png>\n".utf8))
    exit(2)
}

guard let representation = drawBackground(scale: 2),
      let data = representation.representation(using: .png, properties: [:])
else {
    FileHandle.standardError.write(Data("no se pudo dibujar el fondo\n".utf8))
    exit(1)
}

do {
    try data.write(to: URL(fileURLWithPath: CommandLine.arguments[1]))
} catch {
    FileHandle.standardError.write(Data("no se pudo escribir: \(error)\n".utf8))
    exit(1)
}
