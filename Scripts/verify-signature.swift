// Verifica la firma EdDSA de un artefacto, usando la misma primitiva que la
// app: Curve25519 de CryptoKit. Existe como script para que el arnés de
// F6.2 pueda comprobar la firma sin arrancar la app entera.
//
// Uso: swift verify-signature.swift <fichero> <firma-base64> <clave-base64>
// Sale 0 si la firma es válida, 1 si no.
import CryptoKit
import Foundation

let args = CommandLine.arguments
guard args.count == 4 else {
    FileHandle.standardError.write(Data("uso: <fichero> <firma> <clave>\n".utf8))
    exit(2)
}

guard let data = FileManager.default.contents(atPath: args[1]) else {
    print("✗ no se pudo leer el artefacto")
    exit(1)
}
guard
    let signature = Data(base64Encoded: args[2]),
    let keyData = Data(base64Encoded: args[3]),
    let key = try? Curve25519.Signing.PublicKey(rawRepresentation: keyData)
else {
    print("✗ firma o clave malformadas")
    exit(1)
}

if key.isValidSignature(signature, for: data) {
    print("✓ firma EdDSA válida sobre \(data.count) bytes")
    exit(0)
} else {
    print("✗ firma EdDSA INVÁLIDA — el artefacto no es el que se firmó")
    exit(1)
}
