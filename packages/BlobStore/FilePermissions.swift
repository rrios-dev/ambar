import Foundation

/// Permisos del almacén local.
///
/// Un historial de portapapeles es de lo más sensible que guarda una máquina:
/// acumula todo lo copiado, incluidas contraseñas de gestores que no marcan su
/// contenido como confidencial, tokens y mensajes privados. Con los permisos
/// que hereda la `umask` por defecto (`755` / `644`) cualquier otra cuenta del
/// sistema puede leerlo entero.
///
/// Aquí se fija lo contrario: solo el dueño, y nadie más.
public enum FilePermissions {
    // Se construyen en cada acceso en lugar de guardarse como constantes: un
    // `[FileAttributeKey: Any]` global no es `Sendable` y bajo Swift 6 sería
    // estado mutable compartido. Construir un diccionario de una entrada no
    // tiene coste apreciable.

    /// `rwx------`
    public static var directory: [FileAttributeKey: Any] { [.posixPermissions: 0o700] }
    /// `rw-------`
    public static var file: [FileAttributeKey: Any] { [.posixPermissions: 0o600] }

    /// Crea el directorio con permisos restringidos desde el principio.
    ///
    /// Importa que sea en la creación y no después: entre un `createDirectory`
    /// permisivo y un `chmod` posterior hay una ventana, por breve que sea, en
    /// la que el directorio es legible.
    public static func createDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true,
            attributes: directory
        )
    }

    /// Restringe lo que ya existe.
    ///
    /// Las instalaciones anteriores a este cambio tienen el historial expuesto,
    /// y actualizar la app no lo arregla solo. Se aplica en cada arranque
    /// —es barato— para que el problema se cierre sin que el usuario tenga que
    /// hacer nada ni enterarse de que existió.
    public static func restrict(_ url: URL) {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: url.path(percentEncoded: false), isDirectory: &isDirectory)
        else { return }

        try? manager.setAttributes(
            isDirectory.boolValue ? directory : file,
            ofItemAtPath: url.path(percentEncoded: false)
        )
    }

    /// Restringe un árbol completo.
    public static func restrictTree(at root: URL) {
        restrict(root)

        let manager = FileManager.default
        guard let enumerator = manager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: []
        ) else { return }

        while let url = enumerator.nextObject() as? URL {
            restrict(url)
        }
    }
}
