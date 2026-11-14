import Foundation
import Network

/// MQTT 3.1.1, QoS 1. All mutable transport state belongs to queue.
final class MQTTClient {
    let crypto: RoomCrypto
    let id: String
    let name: String
    var onStatus: (String, Bool) -> Void = { _, _ in }
    var onMessage: (String, [String: Any]) -> Void = { _, _ in }
    private let queue = DispatchQueue(label: "VideoCall.MQTT")
    private var connection: NWConnection?
    private var generation = UUID()
    private var enabled = false
    private var closing = false
    private var ready = false
    private var buffer = Data()
    private var sequence: UInt16 = 0
    private var pending = [UInt16: TimeInterval]()
    private var lastRead = Date.timeIntervalSinceReferenceDate
    private var timer: DispatchSourceTimer?
    private var offlinePacket: UInt16?
    init(crypto: RoomCrypto, id: String, name: String) { self.crypto = crypto; self.id = id; self.name = name }
    func start() { queue.async { self.enabled = true; self.connect() } }
    func stop() {
        queue.async {
            self.enabled = false; self.closing = true
            guard self.ready else { self.dispose(); return }
            self.offlinePacket = self.publishPresence(false)
            let token = self.generation
            self.queue.asyncAfter(deadline: .now() + 1.5) { if token == self.generation { self.finishClose() } }
        }
    }
    func signal(to peer: String, json: [String: Any]) {
        queue.async {
            guard self.ready, !self.closing else { return }
            do { _ = try self.publish(topic: self.crypto.root + "/inbox/" + peer, payload: self.crypto.seal(json), retained: false) }
            catch { self.fail(error.localizedDescription) }
        }
    }
    private static func string(_ text: String) -> Data { let bytes = Data(text.utf8); return word(UInt16(bytes.count)) + bytes }
    private static func word(_ number: UInt16) -> Data { Data([UInt8(number >> 8), UInt8(number & 255)]) }
    private func packetID() -> UInt16 { sequence = sequence == .max ? 1 : sequence + 1; return sequence }
    private func send(_ header: UInt8, _ body: Data = Data()) {
        var count = body.count; var prefix = Data([header])
        repeat { var b = UInt8(count % 128); count /= 128; if count > 0 { b |= 128 }; prefix.append(b) } while count > 0
        let token = generation
        connection?.send(content: prefix + body, completion: .contentProcessed { [weak self] error in
            guard let self = self, token == self.generation else { return }
            if let error = error { self.fail(error.localizedDescription) }
        })
    }
    private func connect() {
        guard enabled else { return }
        dispose(); closing = false
        let token = generation
        status("Conectando con Mosquitto…", false)
        // NWParameters.tls retains system certificate and hostname verification.
        let link = NWConnection(host: "test.mosquitto.org", port: 8886, using: .tls)
        connection = link
        link.stateUpdateHandler = { [weak self] state in
            guard let self = self, token == self.generation else { return }
            switch state {
            case .ready:
                do {
                    let will = try self.crypto.seal(self.presence(false))
                    var body = Self.string("MQTT") + Data([4, 0x2e]) + Self.word(20)
                    body += Self.string("vc-" + self.id) + Self.string(self.crypto.root + "/presence/" + self.id)
                    body += Self.word(UInt16(will.count)) + will
                    self.send(0x10, body); self.receive(token)
                } catch { self.fail(error.localizedDescription) }
            case .failed(let error): self.fail(error.localizedDescription)
            case .waiting(let error): self.status("Red en espera: " + error.localizedDescription, false)
            default: break
            }
        }
        link.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 15) { [weak self] in
            guard let self = self, token == self.generation, !self.ready else { return }
            self.fail("Sin respuesta del servicio; reintentando")
        }
    }
    private func receive(_ token: UUID) {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self = self, token == self.generation else { return }
            if let data = data { self.buffer.append(data); self.parse() }
            guard token == self.generation else { return }
            if let error = error { self.fail(error.localizedDescription) }
            else if complete { self.fail("El servicio cerró la conexión") }
            else { self.receive(token) }
        }
    }
    private func parse() {
        while buffer.count >= 2 {
            let bytes = [UInt8](buffer.prefix(5)); var length = 0; var multiplier = 1; var pos = 1; var done = false
            while pos < bytes.count {
                let b = bytes[pos]; length += Int(b & 127) * multiplier; pos += 1
                if b & 128 == 0 { done = true; break }; multiplier *= 128
            }
            if !done { if buffer.count >= 5 { fail("Cabecera MQTT inválida") }; return }
            guard length <= 131072 else { fail("Mensaje demasiado grande"); return }
            guard buffer.count >= pos + length else { return }
            let header = buffer[buffer.startIndex]
            let body = Array(buffer.dropFirst(pos).prefix(length))
            buffer = Data(buffer.dropFirst(pos + length)); lastRead = Date.timeIntervalSinceReferenceDate
            handle(header, body)
        }
    }
    private func handle(_ header: UInt8, _ body: [UInt8]) {
        switch header >> 4 {
        case 2:
            guard body.count == 2, body[1] == 0 else { fail("El broker rechazó la sesión"); return }
            let number = packetID()
            let subs = Self.word(number) + Self.string(crypto.root + "/presence/+") + Data([1])
                + Self.string(crypto.root + "/inbox/" + id) + Data([1])
            send(0x82, subs)
        case 9:
            guard body.count == 4, body[2...].allSatisfy({ $0 <= 1 }) else { fail("Suscripción MQTT rechazada"); return }
            ready = true; _ = publishPresence(true); status("En línea · Mosquitto TLS", true)
            let beat = DispatchSource.makeTimerSource(queue: queue)
            beat.schedule(deadline: .now() + 10, repeating: 10)
            beat.setEventHandler { [weak self] in
                guard let self = self, !self.closing else { return }
                if Date.timeIntervalSinceReferenceDate - self.lastRead > 35 || self.pending.values.contains(where: { Date.timeIntervalSinceReferenceDate - $0 > 25 }) {
                    self.fail("Se perdió respuesta del servicio"); return
                }
                _ = self.publishPresence(true); self.send(0xc0)
            }
            timer?.cancel(); timer = beat; beat.resume()
        case 3:
            guard body.count >= 2 else { return }
            let count = Int(body[0]) * 256 + Int(body[1]); var pos = 2 + count
            guard count > 0, pos <= body.count, let topic = String(bytes: body[2..<pos], encoding: .utf8) else { return }
            let qos = (header >> 1) & 3
            if qos == 1 {
                guard pos + 2 <= body.count else { return }
                send(0x40, Data(body[pos..<(pos + 2)])); pos += 2
            } else if qos != 0 { fail("QoS no admitido"); return }
            if topic.contains("/inbox/") && header & 1 != 0 { return }
            if let json = try? crypto.open(Data(body.dropFirst(pos))) { onMain { self.onMessage(topic, json) } }
        case 4:
            if body.count == 2 {
                let number = UInt16(body[0]) * 256 + UInt16(body[1]); pending.removeValue(forKey: number)
                if number == offlinePacket { finishClose() }
            }
        case 13: break
        default: break
        }
    }
    private func presence(_ online: Bool) -> [String: Any] { ["id": id, "name": name, "online": online, "ts": milliseconds()] }
    @discardableResult private func publishPresence(_ online: Bool) -> UInt16? {
        do { return try publish(topic: crypto.root + "/presence/" + id, payload: crypto.seal(presence(online)), retained: true) }
        catch { fail(error.localizedDescription); return nil }
    }
    private func publish(topic: String, payload: Data, retained: Bool) throws -> UInt16 {
        guard pending.count < 256 else { throw LabError.message("El servicio no confirma los mensajes") }
        let number = packetID(); pending[number] = Date.timeIntervalSinceReferenceDate
        send(retained ? 0x33 : 0x32, Self.string(topic) + Self.word(number) + payload); return number
    }
    private func status(_ value: String, _ online: Bool) { onMain { self.onStatus(value, online) } }
    private func fail(_ reason: String) {
        guard connection != nil else { return }
        dispose(); status(reason, false)
        let token = generation
        if enabled { queue.asyncAfter(deadline: .now() + 5) { if token == self.generation { self.connect() } } }
    }
    private func finishClose() { send(0xe0); dispose(); status("Desconectado", false) }
    private func dispose() {
        generation = UUID(); timer?.cancel(); timer = nil
        connection?.stateUpdateHandler = nil; connection?.cancel(); connection = nil
        ready = false; buffer.removeAll(); pending.removeAll(); offlinePacket = nil
        lastRead = Date.timeIntervalSinceReferenceDate
    }
}
