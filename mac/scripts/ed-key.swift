// Ed25519 for the release scripts, with CryptoKit; run by ed-key.sh.
//
//   public                      reads Sparkle's private key (base64, as
//                               generate_keys -x writes it) from standard
//                               input and prints the public key for
//                               SUPublicEDKey
//   verify FILE SIGNATURE KEY   checks a sign_update signature of FILE with
//                               the public key KEY, as Sparkle does
import CryptoKit
import Foundation

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

func base64(_ text: String, _ what: String) -> Data {
    guard let data = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
        fail("\(what) is not base64")
    }
    return data
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "public":
    let secret = base64(readLine(strippingNewline: true) ?? "", "the private key")
    switch secret.count {
    case 32: // a seed, what generate_keys makes since Sparkle 2.0
        guard let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: secret) else {
            fail("the private key is not an Ed25519 seed")
        }
        print(key.publicKey.rawRepresentation.base64EncodedString())
    case 96: // the old format: 64 bytes of private key, then the public key
        print(secret.suffix(32).base64EncodedString())
    default:
        fail("the private key has \(secret.count) bytes; Sparkle's have 32 (or 96)")
    }
case "verify" where arguments.count == 4:
    guard let data = FileManager.default.contents(atPath: arguments[1]) else {
        fail("cannot read \(arguments[1])")
    }
    let signature = base64(arguments[2], "the signature")
    guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: base64(arguments[3], "the public key")) else {
        fail("the public key is not an Ed25519 key")
    }
    guard key.isValidSignature(signature, for: data) else {
        fail("the signature of \(arguments[1]) does not match the public key")
    }
default:
    fail("usage: ed-key.swift public | verify FILE SIGNATURE PUBLIC_KEY")
}
