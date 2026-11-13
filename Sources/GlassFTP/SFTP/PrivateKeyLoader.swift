import Citadel
import Crypto
import Foundation

/// Turns a private key file into a Citadel authentication method.
///
/// Supported: OpenSSH-format ed25519 and RSA (optionally passphrase-protected,
/// which is what `ssh-keygen` writes today), and PEM ECDSA keys. Citadel has
/// no parser for OpenSSH-format ECDSA, so those get an error that says how to
/// convert them rather than a generic failure.
enum PrivateKeyLoader {
    enum KeyType: Equatable {
        case ed25519
        case rsa
        case ecdsaOpenSSH
        case ecdsaPEM
        case unknown
    }

    static func authenticationMethod(
        username: String,
        keyPath: String,
        passphrase: String?
    ) throws -> SSHAuthenticationMethod {
        let path = (keyPath as NSString).expandingTildeInPath
        guard let contents = try? String(contentsOfFile: path, encoding: .utf8) else {
            throw ProviderError.operationFailed("Could not read the private key at \(keyPath).")
        }
        let decryptionKey = passphrase.flatMap { $0.isEmpty ? nil : Data($0.utf8) }

        do {
            switch detectType(contents) {
            case .ed25519:
                let key = try Curve25519.Signing.PrivateKey(sshEd25519: contents, decryptionKey: decryptionKey)
                return .ed25519(username: username, privateKey: key)

            case .rsa:
                let key = try Insecure.RSA.PrivateKey(sshRsa: contents, decryptionKey: decryptionKey)
                return .rsa(username: username, privateKey: key)

            case .ecdsaPEM:
                return try ecdsa(pem: contents, username: username)

            case .ecdsaOpenSSH:
                throw ProviderError.operationFailed(
                    "OpenSSH-format ECDSA keys are not supported. Convert it to PEM with "
                        + "“ssh-keygen -p -m PEM -f \(keyPath)”, or use an ed25519 key."
                )

            case .unknown:
                throw ProviderError.operationFailed("\(keyPath) is not a supported private key.")
            }
        } catch let error as ProviderError {
            throw error
        } catch {
            throw describe(error, keyPath: keyPath, hasPassphrase: decryptionKey != nil)
        }
    }

    /// Reads the key type from the file without decrypting anything.
    ///
    /// In the OpenSSH format the public half is stored in the clear ahead of the
    /// encrypted private half, so its algorithm name can be found in the decoded
    /// payload even when the key has a passphrase.
    static func detectType(_ contents: String) -> KeyType {
        if contents.contains("BEGIN EC PRIVATE KEY") { return .ecdsaPEM }
        if contents.contains("BEGIN PRIVATE KEY") {
            // PKCS#8: CryptoKit's PEM initialisers accept it for the curves.
            return .ecdsaPEM
        }
        guard contents.contains("BEGIN OPENSSH PRIVATE KEY") else { return .unknown }

        let body = contents
            .split(separator: "\n")
            .filter { !$0.hasPrefix("-----") }
            .joined()
        guard let payload = Data(base64Encoded: body) else { return .unknown }
        // ASCII decoding replaces the binary bytes instead of failing on them.
        let text = String(decoding: payload, as: Unicode.ASCII.self)

        if text.contains("ssh-ed25519") { return .ed25519 }
        if text.contains("ecdsa-sha2-") { return .ecdsaOpenSSH }
        if text.contains("ssh-rsa") { return .rsa }
        return .unknown
    }

    private static func ecdsa(pem: String, username: String) throws -> SSHAuthenticationMethod {
        if let key = try? P256.Signing.PrivateKey(pemRepresentation: pem) {
            return .p256(username: username, privateKey: key)
        }
        if let key = try? P384.Signing.PrivateKey(pemRepresentation: pem) {
            return .p384(username: username, privateKey: key)
        }
        if let key = try? P521.Signing.PrivateKey(pemRepresentation: pem) {
            return .p521(username: username, privateKey: key)
        }
        throw ProviderError.operationFailed(
            "The PEM key could not be read. Encrypted PEM keys are not supported — "
                + "convert it with “ssh-keygen -p -f <key>”, which writes the OpenSSH format."
        )
    }

    private static func describe(_ error: Error, keyPath: String, hasPassphrase: Bool) -> ProviderError {
        let description = String(describing: error)
        if description.contains("missingDecryptionKey") {
            return .operationFailed("The key at \(keyPath) is protected by a passphrase. Enter it in the connection's settings.")
        }
        if description.contains("invalidCheck") || description.contains("cryptoError") {
            return hasPassphrase
                ? .operationFailed("Wrong passphrase for the key at \(keyPath).")
                : .operationFailed("The key at \(keyPath) could not be decrypted.")
        }
        return .operationFailed("Could not load the key at \(keyPath): \(description)")
    }
}
