import SwiftUI
import AVFoundation
import Vision
import CoreImage

struct FaceFeedback {
    var text = "Preparando cámara y modelo…"
    var score = 0
    var accepted = 0
    var total = 5
    var pose: FacePose = .front
    var good = false
    var hold = 0.0
    var seen = false
    var centered = false
    var distance = false
    var imageGood = false
    var faceRect = CGRect.zero
    var imageAspect: CGFloat = 0.75
    var observedAt = 0.0
    var capturedAt = 0.0
    var flash = false
    var fatal = false
    var yaw: Double = 0
    var pitch: Double = 0
}

final class FaceCapture: NSObject, ObservableObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    @Published var feedback = FaceFeedback()
    @Published var mirrored = UserDefaults.standard.object(forKey: "faceMirror011") as? Bool ?? true
    @Published var sound = UserDefaults.standard.object(forKey: "faceSound") as? Bool ?? true
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "VideoCall.Face")
    private let ci = CIContext(options: [.cacheIntermediates: false])
    private let name: String
    private let profile: FaceProfile?
    private let completion: (FaceProfile) -> Void
    private var model: FaceModel?
    private var active = true // Main-thread delivery gate; worker uses stopped.
    private var stopped = false
    private var configured = false
    private var orientation: AVCaptureVideoOrientation = .portrait
    private var output: AVCaptureVideoDataOutput?
    private var steps: [FacePose]
    private var samples = [[Float]]()
    private var lastTime: TimeInterval = 0
    private var deadline = ProcessInfo.processInfo.systemUptime + 180
    private var stability = FaceStability()
    private var capturedAt = 0.0
    private var pauseUntil: TimeInterval = 0
    private var stickyUntil: TimeInterval = 0
    private var stickyText = ""
    private var previousPose: FacePose?
    private var previousYaw: Double = 0
    private var previousPitch: Double = 0
    private var failures = 0
    private var player: AVAudioPlayer?

    init(name: String, profile: FaceProfile?, completion: @escaping (FaceProfile) -> Void) {
        self.name = name; self.profile = profile; self.completion = completion
        steps = profile == nil ? FacePose.allCases : [.front, FacePose.allCases.dropFirst().randomElement()!, .front]
        super.init(); feedback.total = steps.count
    }
    func start() {
        guard active else { return }
        let until = UserDefaults.standard.double(forKey: "faceCooldown")
        guard Date().timeIntervalSince1970 >= until else {
            publishError("Espera \(Int(ceil(until - Date().timeIntervalSince1970))) segundos antes de intentarlo de nuevo."); return
        }
        AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
            guard let self = self else { return }
            self.queue.async {
                guard !self.stopped else { return }
                guard granted else { self.publishError("Permite la cámara en Ajustes para registrar o verificar tu rostro."); return }
                do { self.model = try FaceModel(); try self.configure(); self.deadline = ProcessInfo.processInfo.systemUptime + 180; self.session.startRunning() }
                catch { self.publishError(error.localizedDescription) }
            }
        }
    }
    func stop() { active = false; player?.stop(); player = nil; queue.async { self.shutdown() } }
    private func shutdown() {
        stopped = true; if session.isRunning { session.stopRunning() }
        output?.setSampleBufferDelegate(nil, queue: nil); model = nil; samples.removeAll()
    }
    func toggleMirror() { mirrored.toggle(); UserDefaults.standard.set(mirrored, forKey: "faceMirror011") }
    func toggleSound() { sound.toggle(); UserDefaults.standard.set(sound, forKey: "faceSound") }
    func orient(_ value: AVCaptureVideoOrientation) {
        queue.async {
            guard self.orientation != value else { return }
            self.orientation = value; self.stability.reset()
            if let link = self.output?.connection(with: .video), link.isVideoOrientationSupported { link.videoOrientation = value }
        }
    }
    private func configure() throws {
        guard !configured else { return }
        session.beginConfiguration(); defer { session.commitConfiguration() }
        session.sessionPreset = .vga640x480
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .front) else { throw LabError.message("No hay cámara frontal disponible.") }
        let input = try AVCaptureDeviceInput(device: camera)
        guard session.canAddInput(input) else { throw LabError.message("La cámara está ocupada.") }; session.addInput(input)
        let out = AVCaptureVideoDataOutput(); out.alwaysDiscardsLateVideoFrames = true
        out.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        out.setSampleBufferDelegate(self, queue: queue)
        guard session.canAddOutput(out) else { throw LabError.message("No se puede leer la cámara.") }; session.addOutput(out)
        if let link = out.connection(with: .video) {
            if link.isVideoOrientationSupported { link.videoOrientation = orientation }
            if link.isVideoMirroringSupported { link.automaticallyAdjustsVideoMirroring = false; link.isVideoMirrored = false }
        }
        output = out; configured = true
    }
    private func publish(_ value: FaceFeedback) { onMain { [weak self] in guard let self = self, self.active else { return }; self.feedback = value } }
    private func publishError(_ value: String) { var f = FaceFeedback(); f.text = value; f.fatal = true; publish(f) }
    private func moved(_ yaw: Double, _ pitch: Double) -> Bool {
        steps[samples.count].moved(from: previousPose, yaw: yaw, pitch: pitch,
            previousYaw: previousYaw, previousPitch: previousPitch)
    }
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        let now = ProcessInfo.processInfo.systemUptime
        guard !stopped, now - lastTime >= 0.10, now >= pauseUntil, samples.count < steps.count else { return }; lastTime = now
        if now > deadline { publishError("Se agotó el tiempo. Cancela y vuelve a intentarlo con buena luz."); shutdown(); return }
        guard let buffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let image = ci.createCGImage(CIImage(cvPixelBuffer: buffer), from: CGRect(x: 0, y: 0, width: CVPixelBufferGetWidth(buffer), height: CVPixelBufferGetHeight(buffer))) else { return }
        var f = FaceFeedback(); f.pose = steps[samples.count]; f.accepted = samples.count; f.total = steps.count
        f.imageAspect = CGFloat(image.width) / CGFloat(image.height); f.capturedAt = capturedAt
        do {
            let request = VNDetectFaceLandmarksRequest()
            try VNImageRequestHandler(cgImage: image, orientation: .up, options: [:]).perform([request])
            guard let faces = request.results, faces.count == 1, let face = faces.first else {
                stability.reset(); f.text = "Muestra un solo rostro, completo y con buena luz."; publish(f); return
            }
            let yaw = (face.yaw?.doubleValue ?? 999) * 180 / .pi
            let pitch = (face.pitch?.doubleValue ?? 999) * 180 / .pi
            let roll = (face.roll?.doubleValue ?? 999) * 180 / .pi
            f.yaw = yaw; f.pitch = pitch
            let w = CGFloat(image.width), h = CGFloat(image.height), side = min(w, h)
            let rect = CGRect(x: face.boundingBox.minX * w, y: (1 - face.boundingBox.maxY) * h,
                width: face.boundingBox.width * w, height: face.boundingBox.height * h)
            let dx = abs(rect.midX - w / 2) / side, dy = abs(rect.midY - h / 2) / side, size = rect.width / side
            let framing = FaceFraming.evaluate(left: Double(rect.minX), top: Double(rect.minY),
                right: Double(rect.maxX), bottom: Double(rect.maxY), width: Double(w), height: Double(h))
            f.score = framing.score; f.centered = framing.centered && framing.inside
            f.distance = framing.distance && rect.width >= 120 && rect.height >= 120
            f.seen = true; f.observedAt = now
            f.faceRect = CGRect(x: rect.minX / w, y: rect.minY / h, width: rect.width / w, height: rect.height / h)
            var hint: String?
            if rect.width < 120 || rect.height < 120 || size < 0.35 { hint = "Acércate un poco." }
            else if size > 0.88 || rect.width > w * 0.94 || rect.height > h * 0.95 { hint = "Aléjate un poco." }
            else if dx > 0.25 || dy > 0.28 || rect.minX < 4 || rect.minY < 4 || rect.maxX > w - 4 || rect.maxY > h - 4 { hint = "Centra todo el rostro en la vista." }
            else { hint = quality(buffer, rect: rect) }
            f.imageGood = hint == nil
            if hint == nil && !f.pose.accepts(yaw: yaw, pitch: pitch, roll: roll) { hint = abs(roll) > 22 ? "Mantén la cabeza vertical." : f.pose.title + ". Basta un giro leve." }
            if hint == nil && !moved(yaw, pitch) { hint = "Mueve un poco la cabeza hacia la nueva posición." }
            if let hint = hint {
                stability.reset(); f.text = now < stickyUntil ? stickyText : hint; publish(f); return
            }
            f.good = true; f.text = "Vas bien · mantén la posición un instante"
            let ready = stability.observe(at: now, good: true); f.hold = stability.progress
            guard ready else { publish(f); return }
            guard let model = model else { return }
            let vector = try model.extract(image, face: face)
            if let profile = profile {
                guard FaceMath.matches(vector, profile.samples) else {
                    failures += 1; stability.reset()
                    if failures >= 3 {
                        UserDefaults.standard.set(Date().timeIntervalSince1970 + 30, forKey: "faceCooldown")
                        publishError("No coincide con el registro. Espera 30 segundos antes de repetir."); shutdown(); return
                    }
                    stickyText = "No coincide todavía. Mira de frente, mejora la luz y gira menos."
                    stickyUntil = now + 2.2; f.text = stickyText; f.good = false; pauseUntil = now + 0.45; publish(f); return
                }
            } else if let first = samples.first, FaceMath.cosine(first, vector) < 0.42 {
                stability.reset(); stickyText = "Gira menos: repetiremos solo esta posición."
                stickyUntil = now + 2.2; f.text = stickyText; f.good = false; publish(f); return
            }
            samples.append(vector); previousPose = f.pose; previousYaw = yaw; previousPitch = pitch
            stability.reset(); pauseUntil = now + 0.45; deadline = now + (profile == nil ? 180 : 90)
            capturedAt = now; f.capturedAt = now; f.hold = 0; f.accepted = samples.count; f.flash = true; f.text = "¡Captura lista!"; publish(f); beep()
            if samples.count == steps.count {
                let result = profile ?? FaceProfile(version: 1, name: name, samples: samples)
                do { if profile == nil { try FaceStore.save(result) } }
                catch { publishError("No se pudo guardar el registro: " + error.localizedDescription); shutdown(); return }
                shutdown()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak self] in
                    guard let self = self, self.active else { return }; self.active = false; self.completion(result)
                }
            }
        } catch {
            stability.reset(); f.text = error.localizedDescription; f.good = false; publish(f)
        }
    }
    private func quality(_ buffer: CVPixelBuffer, rect: CGRect) -> String? {
        CVPixelBufferLockBaseAddress(buffer, .readOnly); defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { return "No se pudo leer la imagen." }
        let stride = CVPixelBufferGetBytesPerRow(buffer), w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        let bytes = base.assumingMemoryBound(to: UInt8.self)
        var sum = 0.0, gradient = 0.0, count = 0
        func luma(_ x: Int, _ y: Int) -> Double { let i = y * stride + x * 4; return Double(bytes[i + 2]) * 0.299 + Double(bytes[i + 1]) * 0.587 + Double(bytes[i]) * 0.114 }
        for y in Swift.stride(from: max(1, Int(rect.minY)), to: min(h - 1, Int(rect.maxY)), by: 3) {
            for x in Swift.stride(from: max(1, Int(rect.minX)), to: min(w - 1, Int(rect.maxX)), by: 3) {
                let value = luma(x, y); sum += value; gradient += abs(value - luma(x + 1, y)); count += 1
            }
        }
        guard count > 0 else { return "Centra el rostro." }
        if sum / Double(count) < 55 { return "Busca más luz de frente." }
        if sum / Double(count) > 225 { return "Evita luz demasiado intensa." }
        if gradient / Double(count) < 1.8 { return "Limpia la cámara y mantente quieto." }
        return nil
    }
    private func beep() {
        onMain { [weak self] in
            guard let self = self, self.active, self.sound,
                  let url = AppResources.bundle.url(forResource: "capture", withExtension: "wav") else { return }
            do {
                try AVAudioSession.sharedInstance().setCategory(.ambient, mode: .default, options: [.mixWithOthers])
                self.player = try AVAudioPlayer(contentsOf: url); self.player?.volume = 0.35; self.player?.play()
            } catch { /* Visual confirmation remains available; never changes system volume. */ }
        }
    }
}

final class PreviewSurface: UIView {
    override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
    var preview: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    var orientationChanged: ((AVCaptureVideoOrientation) -> Void)?
    var mirrored = false
    override func layoutSubviews() {
        super.layoutSubviews()
        guard let ui = window?.windowScene?.interfaceOrientation else { return }
        let orientation: AVCaptureVideoOrientation
        switch ui { case .landscapeLeft: orientation = .landscapeLeft
        case .landscapeRight: orientation = .landscapeRight
        case .portraitUpsideDown: orientation = .portraitUpsideDown
        default: orientation = .portrait }
        if let link = preview.connection {
            if link.isVideoOrientationSupported { link.videoOrientation = orientation }
            if link.isVideoMirroringSupported { link.automaticallyAdjustsVideoMirroring = false; link.isVideoMirrored = mirrored }
        }
        orientationChanged?(orientation)
    }
}
struct FacePreview: UIViewRepresentable {
    @ObservedObject var capture: FaceCapture
    func makeUIView(context: Context) -> PreviewSurface {
        let view = PreviewSurface(); view.preview.session = capture.session; view.preview.videoGravity = .resizeAspect
        view.orientationChanged = { [weak capture] in capture?.orient($0) }; return view
    }
    func updateUIView(_ view: PreviewSurface, context: Context) { view.mirrored = capture.mirrored; view.setNeedsLayout() }
    static func dismantleUIView(_ view: PreviewSurface, coordinator: ()) { view.preview.session = nil; view.orientationChanged = nil }
}
