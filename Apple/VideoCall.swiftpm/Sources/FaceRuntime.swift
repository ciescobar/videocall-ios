import Foundation
import onnxruntime

/// Calls Microsoft's prebuilt C framework from Swift. No C/ObjC source target is built on iPad.
/// All calls belong to the face processing queue. Tensor storage stays alive through Run.
final class FaceRuntime {
    private let api: UnsafePointer<OrtApi>
    private var env: OpaquePointer?
    private var session: OpaquePointer?
    private var memory: OpaquePointer?
    private var inputName = ""
    private var outputName = ""
    init(path: String) throws {
        guard let base = OrtGetApiBase(), let api = base.pointee.GetApi(UInt32(ORT_API_VERSION)) else {
            throw LabError.message("ONNX Runtime no está disponible.")
        }
        self.api = api
        do {
            try check(api.pointee.CreateEnv(ORT_LOGGING_LEVEL_WARNING, "VideoCall", &env))
            var options: OpaquePointer?
            try check(api.pointee.CreateSessionOptions(&options)); defer { api.pointee.ReleaseSessionOptions(options) }
            try check(api.pointee.SetIntraOpNumThreads(options, 2))
            try path.withCString { try check(api.pointee.CreateSession(env, $0, options, &session)) }
            try check(api.pointee.CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &memory))
            var allocator: UnsafeMutablePointer<OrtAllocator>?
            try check(api.pointee.GetAllocatorWithDefaultOptions(&allocator))
            var input: UnsafeMutablePointer<CChar>?, output: UnsafeMutablePointer<CChar>?
            defer {
                if let input = input { _ = api.pointee.AllocatorFree(allocator, input) }
                if let output = output { _ = api.pointee.AllocatorFree(allocator, output) }
            }
            try check(api.pointee.SessionGetInputName(session, 0, allocator, &input))
            try check(api.pointee.SessionGetOutputName(session, 0, allocator, &output))
            guard let i = input, let o = output else { throw LabError.message("Modelo facial sin entrada/salida.") }
            inputName = String(cString: i); outputName = String(cString: o)
        } catch { release(); throw error }
    }
    private func check(_ status: OpaquePointer?) throws {
        if let status = status {
            let message = api.pointee.GetErrorMessage(status).map { String(cString: $0) } ?? "Error sin descripción"
            api.pointee.ReleaseStatus(status); throw LabError.message("Motor facial: " + message)
        }
    }
    func infer(_ input: [Float]) throws -> [Float] {
        guard input.count == 3 * 112 * 112 else { throw LabError.message("Entrada facial incorrecta.") }
        var floats = input
        defer { floats.withUnsafeMutableBytes { $0.initializeMemory(as: UInt8.self, repeating: 0) } }
        return try floats.withUnsafeMutableBytes { bytes in
            var value: OpaquePointer?
            let dimensions: [Int64] = [1, 3, 112, 112]
            try dimensions.withUnsafeBufferPointer { shape in
                try check(api.pointee.CreateTensorWithDataAsOrtValue(memory, bytes.baseAddress, bytes.count,
                    shape.baseAddress, shape.count, ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT, &value))
            }
            defer { api.pointee.ReleaseValue(value) }
            return try inputName.withCString { i in try outputName.withCString { o in
                let inputNames: [UnsafePointer<CChar>?] = [i], outputNames: [UnsafePointer<CChar>?] = [o]
                let inputs: [OpaquePointer?] = [value]; var outputs: [OpaquePointer?] = [nil]
                defer { outputs.forEach { api.pointee.ReleaseValue($0) } }
                try inputNames.withUnsafeBufferPointer { names in
                    try outputNames.withUnsafeBufferPointer { outNames in
                        try inputs.withUnsafeBufferPointer { inputValues in
                            try outputs.withUnsafeMutableBufferPointer { outputValues in
                                try check(api.pointee.Run(session, nil, names.baseAddress, inputValues.baseAddress, 1,
                                    outNames.baseAddress, 1, outputValues.baseAddress))
                            }
                        }
                    }
                }
                guard let output = outputs[0] else { throw LabError.message("Sin resultado facial.") }
                var info: OpaquePointer?
                try check(api.pointee.GetTensorTypeAndShape(output, &info)); defer { api.pointee.ReleaseTensorTypeAndShapeInfo(info) }
                var count = 0
                try check(api.pointee.GetTensorShapeElementCount(info, &count))
                var type = ONNX_TENSOR_ELEMENT_DATA_TYPE_UNDEFINED
                try check(api.pointee.GetTensorElementType(info, &type))
                guard count == 128, type == ONNX_TENSOR_ELEMENT_DATA_TYPE_FLOAT else { throw LabError.message("Salida facial de dimensión o tipo incorrectos.") }
                var raw: UnsafeMutableRawPointer?
                try check(api.pointee.GetTensorMutableData(output, &raw))
                guard let raw = raw else { throw LabError.message("Resultado facial vacío.") }
                return Array(UnsafeBufferPointer(start: raw.assumingMemoryBound(to: Float.self), count: 128))
            }}
        }
    }
    private func release() {
        api.pointee.ReleaseSession(session); session = nil
        api.pointee.ReleaseMemoryInfo(memory); memory = nil
        api.pointee.ReleaseEnv(env); env = nil
    }
    deinit { release() }
}
