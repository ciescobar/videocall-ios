import Foundation
import AVFoundation
import WebRTC
import CryptoKit
import SwiftUI

/// Methods and callbacks are serialized on the main thread; native capture has its own queue.
final class CallMedia: NSObject, RTCPeerConnectionDelegate, ObservableObject {
    private static let factory: RTCPeerConnectionFactory = {
        RTCInitializeSSL()
        return RTCPeerConnectionFactory(encoderFactory: RTCDefaultVideoEncoderFactory(), decoderFactory: RTCDefaultVideoDecoderFactory())
    }()
    @Published var local: RTCVideoTrack?
    @Published var remote: RTCVideoTrack?
    @Published var muted = false
    @Published var cameraOff = false
    @Published var front = true
    @Published var speaker = true
    @Published var diagnostic = "ICE: esperando conexión"
    var onICE: (RTCIceCandidate) -> Void = { _ in }
    var onState: (RTCIceConnectionState) -> Void = { _ in }
    var onError: (String) -> Void = { _ in }
    private var connection: RTCPeerConnection?
    private var audio: RTCAudioTrack?
    private var capture: RTCCameraVideoCapturer?
    private let cameraQueue = DispatchQueue(label: "VideoCall.CallCamera")
    private var cameraRevision = 0
    private var cameraRunning = false // cameraQueue only
    private var closed = false
    private var audioActive = false
    private var remoteReady = false
    private var remotePending = false
    private var offerStarted = false
    private var candidates = [RTCIceCandidate]()
    private var statsTimer: Timer?
    let video: Bool

    init(video: Bool, relayOnly: Bool) throws {
        self.video = video
        super.init()
        let config = RTCConfiguration(); config.sdpSemantics = .unifiedPlan
        config.continualGatheringPolicy = .gatherContinually
        if relayOnly { config.iceTransportPolicy = .relay }
        let username = "\(Int(Date().timeIntervalSince1970) + 86400):videocall"
        let auth = HMAC<Insecure.SHA1>.authenticationCode(for: Data(username.utf8), using: SymmetricKey(data: Data("openrelayprojectsecret".utf8)))
        config.iceServers = [RTCIceServer(urlStrings: ["stun:stun.l.google.com:19302"]),
            RTCIceServer(urlStrings: ["turn:staticauth.openrelay.metered.ca:80?transport=udp",
                "turn:staticauth.openrelay.metered.ca:443?transport=tcp"], username: username, credential: Data(auth).base64EncodedString())]
        guard let pc = Self.factory.peerConnection(with: config, constraints: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil), delegate: nil) else {
            throw LabError.message("No se pudo iniciar WebRTC.")
        }
        connection = pc; pc.delegate = self
        let source = Self.factory.audioSource(with: RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil))
        let track = Self.factory.audioTrack(with: source, trackId: "audio0"); audio = track; pc.add(track, streamIds: ["videocall"])
        if video {
            let source = Self.factory.videoSource(); capture = RTCCameraVideoCapturer(delegate: source)
            let track = Self.factory.videoTrack(with: source, trackId: "video0"); local = track; pc.add(track, streamIds: ["videocall"])
        }
        speaker = video
        do { try configureAudio() } catch { close(); throw error }
        if video { updateCamera() }
        statsTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.stats() }
    }
    private func configureAudio() throws {
        let rtc = RTCAudioSession.sharedInstance(); rtc.lockForConfiguration(); defer { rtc.unlockForConfiguration() }
        try rtc.setCategory(.playAndRecord, with: [.allowBluetooth])
        try rtc.setMode(.voiceChat)
        if !audioActive { try rtc.setActive(true); audioActive = true }
        try rtc.overrideOutputAudioPort(speaker ? .speaker : .none)
    }
    func toggleMute() { muted.toggle(); audio?.isEnabled = !muted }
    func toggleSpeaker() { speaker.toggle(); do { try configureAudio() } catch { onError(error.localizedDescription) } }
    func toggleCamera() { guard video else { return }; cameraOff.toggle(); local?.isEnabled = !cameraOff; updateCamera() }
    func switchCamera() { guard video else { return }; front.toggle(); updateCamera() }
    private func updateCamera() {
        guard let capturer = capture else { return }
        cameraRevision += 1; let revision = cameraRevision
        let position: AVCaptureDevice.Position = front ? .front : .back
        let shouldRun = !closed && !cameraOff
        // Retain until the queued stop completes, including after the owner releases a call.
        cameraQueue.async {
            if self.cameraRunning { capturer.stopCapture(); self.cameraRunning = false }
            guard shouldRun else { return }
            guard let device = RTCCameraVideoCapturer.captureDevices().first(where: { $0.position == position }),
                  let format = RTCCameraVideoCapturer.supportedFormats(for: device).min(by: {
                      let a = CMVideoFormatDescriptionGetDimensions($0.formatDescription), b = CMVideoFormatDescriptionGetDimensions($1.formatDescription)
                      return abs(Int(a.width) - 640) < abs(Int(b.width) - 640)
                  }) else { onMain { if !self.closed { self.onError("Cámara no disponible") } }; return }
            let maxFPS = format.videoSupportedFrameRateRanges.map(\.maxFrameRate).max() ?? 15
            capturer.startCapture(with: device, format: format, fps: Int(min(30, maxFPS))) { error in
                if let error = error { onMain { if !self.closed && self.cameraRevision == revision { self.onError(error.localizedDescription) } } }
            }
            self.cameraRunning = true
        }
    }
    func offer(_ completion: @escaping (String) -> Void) {
        guard !closed, !offerStarted, let pc = connection else { return }; offerStarted = true
        pc.offer(for: constraints()) { [weak self] sdp, error in
            onMain {
                guard let self = self, !self.closed else { return }
                guard let sdp = sdp, error == nil else { self.onError(error?.localizedDescription ?? "No se creó la oferta"); return }
                pc.setLocalDescription(sdp) { error in onMain {
                    guard !self.closed else { return }
                    if let error = error { self.onError(error.localizedDescription) } else { completion(sdp.sdp) }
                }}
            }
        }
    }
    func remoteSDP(_ text: String, offer: Bool, answer: @escaping (String) -> Void) {
        guard !closed, !remoteReady, !remotePending, let pc = connection, text.count < 65000 else { return }
        remotePending = true
        pc.setRemoteDescription(RTCSessionDescription(type: offer ? .offer : .answer, sdp: text)) { [weak self] error in onMain {
            guard let self = self, !self.closed else { return }
            if let error = error { self.onError(error.localizedDescription); return }
            self.remoteReady = true; self.remotePending = false
            let buffered = self.candidates; self.candidates.removeAll(); buffered.forEach { self.add($0) }
            if offer {
                pc.answer(for: self.constraints()) { sdp, error in onMain {
                    guard !self.closed else { return }
                    guard let sdp = sdp, error == nil else { self.onError(error?.localizedDescription ?? "No se creó la respuesta"); return }
                    pc.setLocalDescription(sdp) { error in onMain {
                        guard !self.closed else { return }
                        if let error = error { self.onError(error.localizedDescription) } else { answer(sdp.sdp) }
                    }}
                }}
            }
            self.findRemote()
        }}
    }
    private func constraints() -> RTCMediaConstraints {
        RTCMediaConstraints(mandatoryConstraints: ["OfferToReceiveAudio": "true", "OfferToReceiveVideo": video ? "true" : "false"], optionalConstraints: nil)
    }
    func add(_ candidate: RTCIceCandidate) {
        guard !closed else { return }
        guard remoteReady else { if candidates.count < 128 { candidates.append(candidate) }; return }
        connection?.add(candidate) { [weak self] error in
            if let error = error { onMain { if let self = self, !self.closed { self.diagnostic = "ICE descartado: " + error.localizedDescription } } }
        }
    }
    private func findRemote() { if remote == nil { remote = connection?.transceivers.compactMap { $0.receiver.track as? RTCVideoTrack }.first } }
    private func stats() {
        guard !closed else { return }; findRemote()
        connection?.statistics { [weak self] report in onMain {
            guard let self = self, !self.closed else { return }
            let all = report.statistics
            let selected = all.values.first(where: { $0.type == "transport" })?.values["selectedCandidatePairId"] as? String
            let pair = selected.flatMap { all[$0] } ?? all.values.first(where: {
                $0.type == "candidate-pair" && ($0.values["nominated"] as? NSNumber)?.boolValue == true && $0.values["state"] as? String == "succeeded"
            })
            guard let pair = pair else { self.diagnostic = "ICE: ruta todavía sin confirmar"; return }
            let localID = pair.values["localCandidateId"] as? String ?? "", remoteID = pair.values["remoteCandidateId"] as? String ?? ""
            let l = all[localID]?.values["candidateType"] as? String ?? "?", r = all[remoteID]?.values["candidateType"] as? String ?? "?"
            let route = l == "relay" || r == "relay" ? "TURN confirmado" : "Ruta \(l) ↔ \(r)"
            let rtt = (pair.values["currentRoundTripTime"] as? NSNumber)?.doubleValue
            self.diagnostic = route + (rtt.map { " · \(Int($0 * 1000)) ms" } ?? "")
        }}
    }
    func close() {
        guard !closed else { return }; closed = true; statsTimer?.invalidate(); statsTimer = nil
        local?.isEnabled = false; audio?.isEnabled = false; updateCamera()
        connection?.delegate = nil; connection?.close(); connection = nil
        candidates.removeAll(); local = nil; remote = nil; audio = nil
        let rtc = RTCAudioSession.sharedInstance(); rtc.lockForConfiguration()
        if audioActive { try? rtc.setActive(false); audioActive = false }; rtc.unlockForConfiguration()
    }
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) { onMain { [weak self] in self?.findRemote() } }
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) { onMain { [weak self] in guard let self = self, !self.closed else { return }; self.findRemote(); self.onState(newState) } }
    func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) { onMain { [weak self] in guard let self = self, !self.closed else { return }; self.onICE(candidate) } }
    func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) { dataChannel.close() }
}

struct TrackView: UIViewRepresentable {
    let track: RTCVideoTrack?
    var mirrored = false
    var fill = false
    final class Coordinator { var track: RTCVideoTrack? }
    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> RTCMTLVideoView {
        let view = RTCMTLVideoView(frame: .zero); view.clipsToBounds = true; return view
    }
    func updateUIView(_ view: RTCMTLVideoView, context: Context) {
        if context.coordinator.track !== track {
            context.coordinator.track?.remove(view); context.coordinator.track = track; track?.add(view)
        }
        view.videoContentMode = fill ? .scaleAspectFill : .scaleAspectFit
        view.transform = CGAffineTransform(scaleX: mirrored ? -1 : 1, y: 1)
    }
    static func dismantleUIView(_ view: RTCMTLVideoView, coordinator: Coordinator) { coordinator.track?.remove(view); coordinator.track = nil }
}
