import AVFoundation
import Foundation

/// Permiso de micrófono.
///
/// Existe como pieza propia porque **el momento de pedirlo es una decisión de
/// diseño, no un detalle**: si se pide durante el gesto, el diálogo del sistema
/// roba la ventana clave, el panel se cierra y el usuario concede el permiso para
/// encontrarse sin nada delante. Se pide al activar la función en Ajustes, con la
/// app traída al frente, y ahí no molesta a nadie.
///
/// Y hay una razón más para no dejarlo implícito: si nadie lo pide, lo dispara
/// `AVAudioEngine.start()` a mitad de la sesión, y una sesión que ya está
/// escuchando recibe silencio mientras el diálogo está en pantalla. El dictado no
/// falla: simplemente no transcribe nada, que es peor.
public enum MicrophoneAuthorization {
    /// Estado actual, sin preguntar nada al usuario.
    public static var current: MicrophonePermission {
        permission(for: AVCaptureDevice.authorizationStatus(for: .audio))
    }

    /// Traducción del estado del sistema al del producto.
    ///
    /// Aparte de `current` para poder afirmarla: el estado real no se puede inyectar en
    /// un test, y mientras la traducción vivía dentro del `switch` que lo consulta,
    /// tratar `restricted` como **concedido** no rompía nada. Eso pondría a la app a
    /// abrir el micrófono en un equipo gestionado que va a devolver silencio.
    public static func permission(for status: AVAuthorizationStatus) -> MicrophonePermission {
        switch status {
        case .authorized: .granted
        case .notDetermined: .notDetermined
        // `restricted` (control parental o gestión del dispositivo) se trata como
        // denegado: la app no puede hacer nada al respecto, y ofrecer un botón que
        // no funciona es peor que decir que no está disponible.
        case .denied, .restricted: .denied
        @unknown default: .denied
        }
    }

    /// ¿Hay alguna entrada de audio en el sistema?
    ///
    /// Se comprueba aparte del permiso porque el remedio es distinto: sin
    /// micrófono no hay nada que conceder.
    public static var hasInputDevice: Bool {
        !AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone, .external],
            mediaType: .audio,
            position: .unspecified
        ).devices.isEmpty
    }

    /// Pide el permiso si aún no se ha decidido.
    ///
    /// Devuelve el estado resultante. Si ya estaba denegado **no vuelve a
    /// preguntar** —macOS solo muestra el diálogo una vez— y hay que mandar al
    /// usuario a Ajustes del Sistema.
    @discardableResult
    public static func request() async -> MicrophonePermission {
        guard AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else {
            return current
        }
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        return granted ? .granted : .denied
    }

    /// URL del panel de Ajustes del Sistema donde se concede el micrófono, para
    /// cuando ya está denegado y no se puede volver a preguntar.
    public static var settingsURL: URL? {
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
    }
}
