import CoreGraphics

/// Dónde debe aparecer el panel.
///
/// La lógica vive aquí, separada de `PanelController`, por una razón muy
/// concreta: el controlador necesita AppKit, un `NSPanel` real y el actor
/// principal, así que no se puede probar. Estas dos funciones son aritmética
/// sobre rectángulos y sí.
///
/// No es una separación cosmética. El caso que cubren —abrir el panel después
/// de desconectar el monitor donde estaba— es de los que no se descubren
/// programando, sino el día que pasa: el atajo responde, el panel se muestra,
/// y el usuario no ve nada y cree que la app está rota.
public enum PanelPlacement {
    /// Cuánto del panel debe quedar dentro de una pantalla para darlo por
    /// visible.
    ///
    /// No basta con que asome una esquina: un panel del que solo se ve el 10 %
    /// es tan inútil como uno invisible, y encima confunde más. Dos tercios es
    /// el punto donde sigue siendo manejable — se puede leer y agarrar para
    /// moverlo de vuelta.
    public static let minimumVisibleFraction: CGFloat = 0.6

    /// ¿Sigue siendo utilizable esta posición con las pantallas de ahora?
    ///
    /// - Parameters:
    ///   - origin: Esquina inferior izquierda propuesta, en coordenadas de
    ///     pantalla de AppKit.
    ///   - size: Tamaño del panel.
    ///   - screens: Áreas útiles de las pantallas conectadas (`visibleFrame`,
    ///     que ya descuenta la barra de menús y el Dock).
    public static func isUsable(
        origin: CGPoint,
        size: CGSize,
        screens: [CGRect]
    ) -> Bool {
        let proposed = CGRect(origin: origin, size: size)
        let area = proposed.width * proposed.height
        guard area > 0 else { return false }

        return screens.contains { screen in
            let overlap = screen.intersection(proposed)
            guard !overlap.isNull else { return false }
            return (overlap.width * overlap.height) > area * minimumVisibleFraction
        }
    }

    /// El sitio de partida: centrado en la pantalla indicada, algo por encima
    /// del centro geométrico.
    ///
    /// El desplazamiento hacia arriba no es un capricho. Una ventana centrada
    /// con exactitud matemática se percibe *baja*, porque el ojo sitúa el
    /// centro óptico por encima del real. Spotlight hace lo mismo.
    public static func centered(in screen: CGRect, size: CGSize) -> CGPoint {
        CGPoint(
            x: screen.midX - size.width / 2,
            y: screen.midY - size.height / 2 + screen.height * 0.08
        )
    }
}
