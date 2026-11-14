import Foundation
import UIKit
import Vision
import CryptoKit
import Security

struct FaceProfile: Codable {
    let version: Int
    let name: String
    let samples: [[Float]]
    static func validate(_ profile: FaceProfile) throws {
        guard profile.version == 1, !profile.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              profile.samples.count == 5,
              profile.samples.allSatisfy({ vector in vector.count == 128 && vector.allSatisfy { $0.isFinite }
                  && abs(vector.reduce(Float(0)) { $0 + $1 * $1 } - 1) < 0.02 }) else {
            throw LabError.message("El registro facial no es válido. No se puede autorizar el acceso.")
        }
    }
}

enum FaceStore {
    private static let service = "com.mitech.videocall.face.v1"
    private static func query() -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: "local-key"]
    }
    private static func url() throws -> URL {
        let folder = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true).appendingPathComponent("Face", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var resource = URLResourceValues(); resource.isExcludedFromBackup = true
        var mutable = folder; try mutable.setResourceValues(resource)
        return folder.appendingPathComponent("profile.bin")
    }
    private static func key(create: Bool) throws -> SymmetricKey {
        var request = query(); request[kSecReturnData as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data, data.count == 32 { return SymmetricKey(data: data) }
        guard status == errSecItemNotFound, create else { throw LabError.message("No se puede abrir la clave facial local (\(status)).") }
        let value = SymmetricKey(size: .bits256)
        var insert = query(); insert[kSecValueData as String] = value.withUnsafeBytes { Data($0) }
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(insert as CFDictionary, nil) == errSecSuccess else { throw LabError.message("No se pudo proteger la clave facial.") }
        return value
    }
    static func load() throws -> FaceProfile? {
        let path = try url()
        guard FileManager.default.fileExists(atPath: path.path) else { return nil }
        let data = try AES.GCM.open(AES.GCM.SealedBox(combined: Data(contentsOf: path)), using: key(create: false),
            authenticating: Data(service.utf8))
        let profile = try JSONDecoder().decode(FaceProfile.self, from: data)
        try FaceProfile.validate(profile); return profile
    }
    static func save(_ profile: FaceProfile) throws {
        try FaceProfile.validate(profile)
        let encoded = try JSONEncoder().encode(profile)
        let sealed = try AES.GCM.seal(encoded, using: key(create: true), authenticating: Data(service.utf8))
        guard let data = sealed.combined else { throw LabError.message("No se pudo cifrar la plantilla.") }
        try data.write(to: url(), options: [.atomic, .completeFileProtection])
    }
    static func delete() throws {
        let path = try url()
        if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
        let status = SecItemDelete(query() as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw LabError.message("No se pudo borrar la clave facial.") }
    }
}

enum FaceMath {
    static func cosine(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == 128, b.count == 128 else { return -1 }
        return zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
    }
    static func matches(_ vector: [Float], _ references: [[Float]]) -> Bool {
        guard references.count == 5, cosine(vector, references[0]) >= 0.50 else { return false }
        let ranked = references.map { cosine(vector, $0) }.sorted(by: >)
        return (ranked[0] + ranked[1]) / 2 >= 0.48
    }
    static func normalize(_ values: [Float]) throws -> [Float] {
        let norm = sqrt(values.reduce(Float(0)) { $0 + $1 * $1 })
        guard values.count == 128, values.allSatisfy({ $0.isFinite }), norm.isFinite, norm > 0.000001 else {
            throw LabError.message("El modelo facial no produjo un resultado válido.")
        }
        return values.map { $0 / norm }
    }
    static func alignment(_ src: [CGPoint]) throws -> CGAffineTransform {
        let dst: [CGPoint] = [.init(x: 38.2946, y: 51.6963), .init(x: 73.5318, y: 51.5014),
            .init(x: 56.0252, y: 71.7366), .init(x: 41.5493, y: 92.3655), .init(x: 70.7299, y: 92.2041)]
        guard src.count == 5 else { throw LabError.message("Muestra ambos ojos, nariz y boca; gira menos.") }
        let sx = src.map(\.x).reduce(0, +) / 5, sy = src.map(\.y).reduce(0, +) / 5
        let dx = dst.map(\.x).reduce(0, +) / 5, dy = dst.map(\.y).reduce(0, +) / 5
        var aa: CGFloat = 0, bb: CGFloat = 0, norm: CGFloat = 0
        for i in 0..<5 {
            let x = src[i].x - sx, y = src[i].y - sy, u = dst[i].x - dx, v = dst[i].y - dy
            aa += x * u + y * v; bb += x * v - y * u; norm += x * x + y * y
        }
        guard norm > 1 else { throw LabError.message("Acerca el rostro un poco.") }
        let a = aa / norm, b = bb / norm
        return .init(a: a, b: b, c: -b, d: a, tx: dx - a * sx + b * sy, ty: dy - b * sx - a * sy)
    }
    static func landmarks(_ face: VNFaceObservation, width: Int, height: Int) throws -> [CGPoint] {
        guard let marks = face.landmarks, let left = marks.leftEye, let right = marks.rightEye,
              let nose = marks.noseCrest ?? marks.nose, let lips = marks.outerLips,
              !left.normalizedPoints.isEmpty, !right.normalizedPoints.isEmpty,
              !nose.normalizedPoints.isEmpty, lips.pointCount >= 2 else {
            throw LabError.message("Muestra ojos, nariz y boca; gira un poco menos.")
        }
        func point(_ p: CGPoint) -> CGPoint {
            .init(x: (face.boundingBox.minX + p.x * face.boundingBox.width) * CGFloat(width),
                  y: (1 - face.boundingBox.minY - p.y * face.boundingBox.height) * CGFloat(height))
        }
        func center(_ region: VNFaceLandmarkRegion2D) -> CGPoint {
            let p = region.normalizedPoints
            return point(.init(x: p.map(\.x).reduce(0, +) / CGFloat(p.count), y: p.map(\.y).reduce(0, +) / CGFloat(p.count)))
        }
        let eyes = [center(left), center(right)].sorted { $0.x < $1.x }
        let mouth = lips.normalizedPoints.map(point).sorted { $0.x < $1.x }
        // Nose crest runs from the bridge towards the tip; prefer its lowest image point.
        let tip = nose.normalizedPoints.map(point).max { $0.y < $1.y }!
        return [eyes[0], eyes[1], tip, mouth.first!, mouth.last!]
    }
}

/// CPU inference, loaded once per gate; never uploads or persists camera frames.
final class FaceModel {
    private let runtime: FaceRuntime
    init() throws {
        guard let url = AppResources.bundle.url(forResource: "sface", withExtension: "onnx") else { throw LabError.message("Falta el modelo facial.") }
        let digest = SHA256.hash(data: try Data(contentsOf: url, options: .mappedIfSafe)).map { String(format: "%02x", $0) }.joined()
        guard digest == "0ba9fbfa01b5270c96627c4ef784da859931e02f04419c829e83484087c34e79" else { throw LabError.message("Modelo facial dañado.") }
        runtime = try FaceRuntime(path: url.path)
    }
    func extract(_ image: CGImage, face: VNFaceObservation) throws -> [Float] {
        let transform = try FaceMath.alignment(FaceMath.landmarks(face, width: image.width, height: image.height))
        let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true; format.preferredRange = .standard
        let aligned = UIGraphicsImageRenderer(size: CGSize(width: 112, height: 112), format: format).image { context in
            UIColor.black.setFill(); context.fill(CGRect(x: 0, y: 0, width: 112, height: 112))
            context.cgContext.concatenate(transform)
            UIImage(cgImage: image).draw(in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        }
        guard let cg = aligned.cgImage else { throw LabError.message("No se pudo alinear la imagen.") }
        guard cg.bitsPerComponent == 8, cg.bitsPerPixel == 32,
              let provider = cg.dataProvider?.data, let pixels = CFDataGetBytePtr(provider) else {
            throw LabError.message("Formato de imagen facial no compatible.")
        }
        // Read UIKit's top-to-bottom image rows directly, preserving alignment orientation.
        // Account for the actual CGImage byte order instead of assuming RGBA/BGRA.
        let alphaFirst = cg.alphaInfo == .first || cg.alphaInfo == .premultipliedFirst || cg.alphaInfo == .noneSkipFirst
        let alphaLast = cg.alphaInfo == .last || cg.alphaInfo == .premultipliedLast || cg.alphaInfo == .noneSkipLast
        guard alphaFirst || alphaLast else { throw LabError.message("Canales de imagen facial no compatibles.") }
        let little = cg.bitmapInfo.intersection(.byteOrderMask) == .byteOrder32Little
        let channels = alphaFirst ? (little ? [2, 1, 0] : [1, 2, 3]) : (little ? [3, 2, 1] : [0, 1, 2])
        var floats = [Float](repeating: 0, count: 3 * 112 * 112)
        defer { floats.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } }
        for y in 0..<112 { for x in 0..<112 { for c in 0..<3 {
            floats[c * 112 * 112 + y * 112 + x] = Float(pixels[y * cg.bytesPerRow + x * 4 + channels[c]])
        }}}
        return try infer(floats)
    }
    private func infer(_ floats: [Float]) throws -> [Float] {
        return try FaceMath.normalize(runtime.infer(floats))
    }
    func smokeTest() throws { _ = try infer((0..<(3 * 112 * 112)).map { Float($0 % 251) }) }
}
