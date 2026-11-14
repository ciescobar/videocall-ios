import Foundation
import CryptoKit
import CommonCrypto

enum LabError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}

struct RoomCrypto {
    let key: SymmetricKey
    let root: String
    init() throws {
        let password = Array("videocall-validation-public-v1-2026".utf8)
        let salt = Array("videocall-v1-room-key".utf8)
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = password.withUnsafeBytes { pass in salt.withUnsafeBytes { saltBytes in
            CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2),
                pass.baseAddress!.assumingMemoryBound(to: Int8.self), password.count,
                saltBytes.baseAddress!.assumingMemoryBound(to: UInt8.self), salt.count,
                CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), 120000, &bytes, 32)
        }}
        guard status == kCCSuccess else { throw LabError.message("No se pudo preparar el grupo de prueba.") }
        key = SymmetricKey(data: bytes)
        root = "mitech/videocall/v1/" + SHA256.hash(data: Data(bytes)).map { String(format: "%02x", $0) }.joined()
        bytes.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) }
    }
    func seal(_ json: [String: Any]) throws -> Data {
        let data = try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
        let box = try AES.GCM.seal(data, using: key, authenticating: Data(root.utf8))
        guard let combined = box.combined else { throw LabError.message("Cifrado incompleto") }
        return Data(combined.base64EncodedString().utf8)
    }
    func open(_ payload: Data) throws -> [String: Any] {
        guard let data = Data(base64Encoded: payload) else { throw LabError.message("Mensaje inválido") }
        let clear = try AES.GCM.open(AES.GCM.SealedBox(combined: data), using: key, authenticating: Data(root.utf8))
        guard let json = try JSONSerialization.jsonObject(with: clear) as? [String: Any] else { throw LabError.message("JSON inválido") }
        return json
    }
    func selfTest() throws {
        let url = AppResources.bundle.url(forResource: "interop", withExtension: "json")!
        let fixture = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
        guard root == fixture["root"] as? String,
              try open(Data((fixture["payload"] as! String).utf8))["name"] as? String == "Prueba Android ñ" else {
            throw LabError.message("Falló la compatibilidad de cifrado con Android")
        }
        var tampered = Data(base64Encoded: fixture["payload"] as! String)!
        tampered[tampered.count - 1] ^= 1
        do { _ = try open(Data(tampered.base64EncodedString().utf8)); throw LabError.message("Se aceptó un mensaje alterado") }
        catch is CryptoKitError { /* Authentication must reject the modified tag. */ }
    }
}

func milliseconds() -> Int64 { Int64(Date().timeIntervalSince1970 * 1000) }
func onMain(_ work: @escaping () -> Void) { if Thread.isMainThread { work() } else { DispatchQueue.main.async(execute: work) } }
