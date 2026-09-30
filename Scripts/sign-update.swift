// Signs a release artifact (the DMG) with Ámbar's update key, EdDSA over Curve25519 — the
// same primitive `verify-signature.swift` checks and the release registry in Hydra expects in
// `edSignature`. The signature is what lets an installed copy refuse an update that was
// altered in transit, independently of HTTPS and of Apple's notarization.
//
// The private key never enters the repository. It lives in
// ~/Library/Application Support/Ambar-signing/update-ed25519.key (0600), created on the first
// run; back that file up — an app shipped with its public key can only ever accept updates
// signed by it.
//
// Usage: swift sign-update.swift <artifact>
// Prints the signature, the artifact's size and the public key, all base64 where it applies.
import CryptoKit
import Foundation

let args = CommandLine.arguments
guard args.count == 2 else {
    FileHandle.standardError.write(Data("usage: swift sign-update.swift <artifact>\n".utf8))
    exit(2)
}

let fileManager = FileManager.default
let keyDirectory = fileManager.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/Application Support/Ambar-signing", isDirectory: true)
let keyURL = keyDirectory.appendingPathComponent("update-ed25519.key")

func loadOrCreateKey() throws -> Curve25519.Signing.PrivateKey {
    if let stored = try? String(contentsOf: keyURL, encoding: .utf8),
       let raw = Data(base64Encoded: stored.trimmingCharacters(in: .whitespacesAndNewlines)) {
        return try Curve25519.Signing.PrivateKey(rawRepresentation: raw)
    }
    try fileManager.createDirectory(at: keyDirectory, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
    let key = Curve25519.Signing.PrivateKey()
    try Data(key.rawRepresentation.base64EncodedString().utf8).write(to: keyURL, options: .withoutOverwriting)
    try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
    FileHandle.standardError.write(Data("created a new update key at \(keyURL.path) — back it up\n".utf8))
    return key
}

guard let artifact = fileManager.contents(atPath: args[1]) else {
    FileHandle.standardError.write(Data("cannot read \(args[1])\n".utf8))
    exit(1)
}

do {
    let key = try loadOrCreateKey()
    let signature = try key.signature(for: artifact)
    print("edSignature: \(signature.base64EncodedString())")
    print("length: \(artifact.count)")
    print("publicKey: \(key.publicKey.rawRepresentation.base64EncodedString())")
} catch {
    FileHandle.standardError.write(Data("signing failed: \(error)\n".utf8))
    exit(1)
}
