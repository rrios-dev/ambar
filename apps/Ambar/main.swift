import AppKit

// Punto de entrada sin storyboard ni `@main`: la app es un agente de la barra
// de menús, no una app de ventanas, así que se construye el `NSApplication` a
// mano y se fija la política de activación antes de arrancar el run loop.

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate

// `.accessory`: sin icono en el Dock y sin barra de menús propia. La app vive
// en la barra de estado y en su atajo global.
application.setActivationPolicy(.accessory)

application.run()
