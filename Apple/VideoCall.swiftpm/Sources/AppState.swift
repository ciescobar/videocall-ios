import SwiftUI
import AVFoundation
import WebRTC

struct Device: Identifiable { let id: String; var name: String; var seen: TimeInterval }
struct Session: Identifiable {
    let id: String
    let peer: String
    let name: String
    let video: Bool
    let caller: Bool
}
struct FaceRequest: Identifiable { let id = UUID(); let incoming: String?; let enroll: Bool; var test = false; var reenroll = false }

final class AppState: ObservableObject {
    @Published var profile: FaceProfile?
    @Published var authorized = false
    @Published var faceRequest: FaceRequest?
    @Published var devices = [Device]()
    @Published var status = "Identifícate para conectarte"
    @Published var online = false
    @Published var call: Session?
    @Published var callPhase = ""
    @Published var media: CallMedia?
    @Published var message: String?
    @Published var fatal: String?
    @Published var diagnostics = "Comprobando compatibilidad…"
    @Published var relayOnly = false
    @Published var remoteMuted = false
    @Published var remoteCameraOff = false
    private var transport: MQTTClient?
    private var crypto: RoomCrypto?
    private var timer: Timer?
    private var timeout: DispatchWorkItem?
    private var recovery: DispatchWorkItem?
    private var seenMessages = Set<String>()
    private var seenOrder = [String]()
    private var ended = [String: TimeInterval]()
    private var background = false
    private var answering = false
    private var permissionRequest: UUID?
    private var activeFace: FaceCapture?
    private var id: String {
        if let id = UserDefaults.standard.string(forKey: "deviceID") { return id }
        let value = UUID().uuidString.lowercased(); UserDefaults.standard.set(value, forKey: "deviceID"); return value
    }
    init() {
        do { profile = try FaceStore.load() } catch { fatal = "No se puede abrir el registro facial: " + error.localizedDescription }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do {
                let crypto = try RoomCrypto(); try crypto.selfTest()
                onMain { self?.crypto = crypto; self?.diagnostics = "Cifrado compatible con Android · prueba local aprobada" }
            } catch { onMain { self?.fatal = error.localizedDescription; self?.diagnostics = "Falló la comprobación de cifrado" } }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            let now = Date.timeIntervalSinceReferenceDate
            self?.devices.removeAll { now - $0.seen > 35 }
            self?.ended = self?.ended.filter { now - $0.value < 120 } ?? [:]
        }
        NotificationCenter.default.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            if (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt) == AVAudioSession.InterruptionType.began.rawValue { self?.end("La llamada terminó por una interrupción de audio.") }
        }
    }
    func requestEntry() {
        guard fatal == nil, faceRequest == nil else { return }
        faceRequest = FaceRequest(incoming: nil, enroll: profile == nil)
    }
    func startUserTest() {
        guard authorized, profile != nil, call == nil, faceRequest == nil, !background else { return }
        faceRequest = FaceRequest(incoming: nil, enroll: false, test: true)
    }
    func startReenrollment() {
        guard authorized, profile != nil, fatal == nil, call == nil, faceRequest == nil, !background else { return }
        faceRequest = FaceRequest(incoming: nil, enroll: true, reenroll: true)
    }
    func faceCapture(name: String, request: FaceRequest) -> FaceCapture {
        let capture = FaceCapture(name: name, profile: request.enroll ? nil : profile, test: request.test,
            replacing: request.reenroll ? profile : nil) { [weak self] profile in
            guard !request.test else { return }
            guard let self = self, self.faceRequest?.id == request.id, !self.background else { return }
            self.activeFace = nil; self.faceRequest = nil; self.profile = profile
            if request.reenroll { self.message = "Matrícula actualizada: cinco posiciones completadas." }
            if let incoming = request.incoming {
                guard self.call?.id == incoming, self.answering else { return }
                self.permissionsAndStart(answering: true)
            } else { self.authorized = true; self.connect() }
        }
        activeFace = capture; return capture
    }
    func cancelFace() {
        let incoming = faceRequest?.incoming
        activeFace?.stop(); activeFace = nil; faceRequest = nil
        if incoming != nil { end("Verificación cancelada") }
    }
    private func connect() {
        guard authorized, !background, let profile = profile, let crypto = crypto, transport == nil else { return }
        let mqtt = MQTTClient(crypto: crypto, id: id, name: profile.name); transport = mqtt
        mqtt.onStatus = { [weak self, weak mqtt] status, online in
            guard let self = self, self.transport === mqtt else { return }
            self.status = status; self.online = online
            if !online { self.devices.removeAll(); if self.call != nil { self.end("Se perdió la conexión de señalización.") } }
        }
        mqtt.onMessage = { [weak self, weak mqtt] topic, json in
            guard let self = self, self.transport === mqtt, !self.background, self.authorized else { return }
            self.receive(topic, json)
        }
        mqtt.start()
    }
    func reconnect() { guard crypto != nil else { message = "Espera a que termine la comprobación de cifrado."; return }; connect() }
    private func send(_ type: String, session: Session, fields: [String: Any] = [:]) {
        var data = fields
        data.merge(["type": type, "call": session.id, "video": session.video, "from": id,
            "name": profile?.name ?? "iPad", "ts": milliseconds(), "mid": UUID().uuidString.lowercased(), "v": 1]) { _, new in new }
        transport?.signal(to: session.peer, json: data)
    }
    private func receive(_ topic: String, _ json: [String: Any]) {
        guard let crypto = crypto else { return }
        if topic.hasPrefix(crypto.root + "/presence/") {
            guard let peer = json["id"] as? String, peer != id, peer.count <= 80,
                  topic == crypto.root + "/presence/" + peer,
                  let name = json["name"] as? String, let alive = json["online"] as? Bool else { return }
            if !alive { devices.removeAll { $0.id == peer }; return }
            guard let ts = json["ts"] as? NSNumber, abs(Double(milliseconds()) - ts.doubleValue) < 35000 else { return }
            let device = Device(id: peer, name: String(name.prefix(60)), seen: Date.timeIntervalSinceReferenceDate)
            if let index = devices.firstIndex(where: { $0.id == peer }) { devices[index] = device }
            else if devices.count < 200 { devices.append(device); devices.sort { $0.name < $1.name } }
            return
        }
        guard topic == crypto.root + "/inbox/" + id,
              let peer = json["from"] as? String, peer != id, peer.count <= 80,
              let callID = json["call"] as? String, callID.count <= 80,
              let type = json["type"] as? String,
              let ts = json["ts"] as? NSNumber, abs(Double(milliseconds()) - ts.doubleValue) < 60000,
              let mid = json["mid"] as? String, mid.count <= 80, !seenMessages.contains(mid),
              (json["v"] as? NSNumber)?.intValue == 1 else { return }
        seenMessages.insert(mid); seenOrder.append(mid)
        if seenOrder.count > 512 { seenMessages.remove(seenOrder.removeFirst()) }
        let history = peer + ":" + callID
        if type == "invite" {
            guard ended[history] == nil else { return }
            if call?.id == callID && call?.peer == peer { return }
            let incoming = Session(id: callID, peer: peer, name: String((json["name"] as? String ?? "Android").prefix(60)), video: json["video"] as? Bool ?? false, caller: false)
            guard call == nil, faceRequest == nil else { send("busy", session: incoming); return }
            call = incoming; callPhase = "Llamada entrante"; answering = false; armTimeout(60, session: incoming); return
        }
        guard let session = call, session.id == callID, session.peer == peer else {
            if type == "end" { rememberEnded(history) }; return
        }
        switch type {
        case "end": end("La otra persona terminó la llamada.", notify: false)
        case "busy": end("El otro dispositivo está ocupado.", notify: false)
        case "verifying": if session.caller && media == nil { callPhase = "Está verificando su identidad…"; armTimeout(90, session: session) }
        case "accept": if session.caller && media == nil && permissionRequest == nil { permissionsAndStart(answering: false) }
        case "offer":
            if !session.caller && answering, let media = media, let text = json["sdp"] as? String {
                media.remoteSDP(text, offer: true) { [weak self] sdp in guard self?.call?.id == callID else { return }; self?.send("answer", session: session, fields: ["sdp": sdp]) }
            }
        case "answer": if session.caller, let text = json["sdp"] as? String { media?.remoteSDP(text, offer: false, answer: { _ in }) }
        case "ice":
            if let candidate = json["candidate"] as? String, candidate.count < 8192,
               let index = json["sdpMLineIndex"] as? NSNumber, index.intValue >= 0, index.intValue <= 32 {
                media?.add(RTCIceCandidate(sdp: candidate, sdpMLineIndex: index.int32Value, sdpMid: json["sdpMid"] as? String))
            }
        case "media": remoteMuted = json["muted"] as? Bool ?? false; remoteCameraOff = json["cameraOff"] as? Bool ?? false
        default: break
        }
    }
    func dial(_ device: Device, video: Bool) {
        guard authorized, online, call == nil, faceRequest == nil else { return }
        let session = Session(id: UUID().uuidString.lowercased(), peer: device.id, name: device.name, video: video, caller: true)
        call = session; callPhase = "Comprobando permisos…"
        requestPermissions(session: session) { [weak self] granted in
            guard let self = self, self.call?.id == session.id else { return }
            if granted { self.callPhase = "Llamando…"; self.send("invite", session: session); self.armTimeout(60, session: session) }
            else { self.end("Permite micrófono y cámara en Ajustes para llamar.") }
        }
    }
    func answer() {
        guard let session = call, !session.caller, !answering, let _ = profile else { return }
        answering = true; send("verifying", session: session); callPhase = "Verifica tu rostro para contestar"
        armTimeout(90, session: session); faceRequest = FaceRequest(incoming: session.id, enroll: false)
    }
    private func requestPermissions(session: Session, done: @escaping (Bool) -> Void) {
        let request = UUID(); permissionRequest = request
        AVCaptureDevice.requestAccess(for: .audio) { [weak self] audio in
            func finish(_ camera: Bool) { onMain {
                guard let self = self, self.permissionRequest == request, self.call?.id == session.id, !self.background else { return }
                self.permissionRequest = nil; done(audio && camera)
            }}
            if session.video { AVCaptureDevice.requestAccess(for: .video, completionHandler: finish) } else { finish(true) }
        }
    }
    private func permissionsAndStart(answering: Bool) {
        guard let session = call else { return }
        requestPermissions(session: session) { [weak self] granted in
            guard let self = self, self.call?.id == session.id else { return }
            guard granted else { self.end("Faltan permisos de micrófono o cámara."); return }
            do {
                let rtc = try CallMedia(video: session.video, relayOnly: self.relayOnly); self.media = rtc
                rtc.onICE = { [weak self] ice in
                    guard self?.call?.id == session.id else { return }
                    self?.send("ice", session: session, fields: ["candidate": ice.sdp, "sdpMid": ice.sdpMid ?? "", "sdpMLineIndex": ice.sdpMLineIndex])
                }
                rtc.onError = { [weak self] error in if self?.call?.id == session.id { self?.end(error) } }
                rtc.onState = { [weak self] state in
                    guard let self = self, self.call?.id == session.id else { return }
                    switch state {
                    case .connected, .completed: self.callPhase = "En llamada"; self.timeout?.cancel(); self.recovery?.cancel()
                    case .failed, .closed: self.end("No se pudo mantener la conexión de medios.")
                    case .disconnected:
                        self.callPhase = "Recuperando conexión…"; self.recovery?.cancel()
                        let work = DispatchWorkItem { [weak self] in if self?.call?.id == session.id { self?.end("Se perdió la conexión de medios.") } }
                        self.recovery = work; DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: work)
                    default: break
                    }
                }
                self.callPhase = "Conectando audio y video…"; self.armTimeout(45, session: session)
                if answering { self.send("accept", session: session) }
                else { rtc.offer { [weak self] sdp in guard self?.call?.id == session.id else { return }; self?.send("offer", session: session, fields: ["sdp": sdp]) } }
            } catch { self.end(error.localizedDescription) }
        }
    }
    func mediaChanged() {
        guard let session = call, let media = media else { return }
        send("media", session: session, fields: ["muted": media.muted, "cameraOff": media.cameraOff])
    }
    private func armTimeout(_ seconds: Double, session: Session) {
        timeout?.cancel()
        let work = DispatchWorkItem { [weak self] in if self?.call?.id == session.id { self?.end("Se agotó el tiempo de espera de la llamada.") } }
        timeout = work; DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
    }
    private func rememberEnded(_ key: String) {
        ended[key] = Date.timeIntervalSinceReferenceDate
        if ended.count > 512, let first = ended.min(by: { $0.value < $1.value }) { ended.removeValue(forKey: first.key) }
    }
    func end(_ reason: String? = nil, notify: Bool = true) {
        guard let session = call else { return }
        if notify { send("end", session: session) }; rememberEnded(session.peer + ":" + session.id)
        call = nil; timeout?.cancel(); recovery?.cancel(); permissionRequest = nil; answering = false
        if faceRequest?.incoming == session.id { activeFace?.stop(); activeFace = nil; faceRequest = nil }
        media?.close(); media = nil; remoteMuted = false; remoteCameraOff = false
        if let reason = reason { message = reason }
    }
    func goBackground() {
        background = true; end(notify: true); cancelFace(); authorized = false
        transport?.stop(); transport = nil; devices.removeAll(); online = false; status = "Vuelve a identificarte para conectarte"
    }
    func goForeground() { background = false }
    func deleteProfile() {
        guard authorized, call == nil else { return }
        transport?.stop(); transport = nil; online = false; devices.removeAll(); authorized = false
        do {
            try FaceStore.delete(); profile = nil; UserDefaults.standard.removeObject(forKey: "deviceID")
            UserDefaults.standard.removeObject(forKey: "faceCooldown"); status = "Crea un nuevo registro facial"
        } catch { fatal = error.localizedDescription }
    }
    func testModel() {
        diagnostics = "Comprobando integridad y ejecución del modelo…"
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            do { let model = try FaceModel(); try model.smokeTest(); onMain { self?.diagnostics = "Modelo íntegro · salida de 128 valores válida. No acredita precisión facial ni llamadas." } }
            catch { onMain { self?.diagnostics = "Error del modelo: " + error.localizedDescription } }
        }
    }
}
