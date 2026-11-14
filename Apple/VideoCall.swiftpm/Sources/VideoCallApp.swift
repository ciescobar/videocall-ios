import SwiftUI

@main
struct VideoCallApp: App {
    @StateObject private var state = AppState()
    @Environment(\.scenePhase) private var phase
    var body: some Scene {
        WindowGroup {
            RootView().environmentObject(state).preferredColorScheme(.dark)
                .onChange(of: phase) { value in
                    if value == .background { state.goBackground() }
                    if value == .active { state.goForeground() }
                }
        }
    }
}

private let mint = Color(red: 0.25, green: 0.91, blue: 0.70)
private let appBackground = Color(red: 0.035, green: 0.075, blue: 0.10)

struct RootView: View {
    @EnvironmentObject var state: AppState
    @State private var settings = false
    @State private var confirmDelete = false
    var body: some View {
        ZStack {
            appBackground.ignoresSafeArea()
            if let call = state.call {
                if let media = state.media { ActiveCallView(session: call, media: media) }
                else { ringing(call) }
            } else if state.authorized { directory }
            else { welcome }
        }
        .tint(mint)
        .fullScreenCover(item: $state.faceRequest) { request in FaceFlowView(request: request).environmentObject(state).interactiveDismissDisabled() }
        .sheet(isPresented: $settings) { settingsView }
        .alert("VideoCall", isPresented: Binding(get: { state.message != nil }, set: { if !$0 { state.message = nil } })) {
            Button("Entendido", role: .cancel) { state.message = nil }
        } message: { Text(state.message ?? "") }
    }
    private var welcome: some View {
        ScrollView {
            VStack(spacing: 25) {
                Image(systemName: "video.bubble.fill").font(.system(size: 72)).foregroundStyle(mint)
                Text("VideoCall").font(.system(size: 40, weight: .bold, design: .rounded))
                Text("Más cerca, estés donde estés").font(.title3).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 16) {
                    Label("Audio y video con Android", systemImage: "person.2.fill")
                    Label("Registro facial en este iPad", systemImage: "faceid")
                    Label("Sin configurar servidores", systemImage: "network")
                }.padding(25).frame(maxWidth: .infinity, alignment: .leading).background(.white.opacity(0.05), in: RoundedRectangle(cornerRadius: 24))
                if let fatal = state.fatal { Text(fatal).foregroundStyle(.orange).textSelection(.enabled) }
                Button(action: state.requestEntry) {
                    Label(state.profile == nil ? "Crear mi registro facial" : "Verificar mi identidad", systemImage: "faceid")
                        .font(.headline).frame(maxWidth: .infinity).padding(12)
                }.buttonStyle(.borderedProminent).disabled(state.fatal != nil)
                Text("Versión de validación · mantén la app visible.\nEl registro facial es experimental y no garantiza identidad ni resistencia a fotos o videos.")
                    .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }.padding(30).frame(maxWidth: 570).frame(maxWidth: .infinity)
        }
    }
    private var directory: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 15) {
                        Image(systemName: "person.crop.circle.fill").font(.largeTitle).foregroundStyle(mint)
                        VStack(alignment: .leading) { Text(state.profile?.name ?? "Mi perfil").font(.headline); Text(state.status).font(.caption).foregroundStyle(state.online ? mint : .secondary) }
                    }.padding(.vertical, 8)
                }
                Section("Dispositivos disponibles · \(state.devices.count)") {
                    if state.devices.isEmpty {
                        VStack(alignment: .leading, spacing: 12) {
                            Label("Esperando al otro dispositivo", systemImage: "antenna.radiowaves.left.and.right")
                            Text("Abre VideoCall en Android y completa su identificación. Ambos deben tener internet y la app visible.").font(.subheadline).foregroundStyle(.secondary)
                        }.padding(.vertical, 18)
                    }
                    ForEach(state.devices) { device in
                        HStack(spacing: 15) {
                            Text(String(device.name.prefix(1)).uppercased()).font(.title2.bold()).frame(width: 45, height: 45).background(mint.opacity(0.15), in: Circle())
                            Text(device.name).font(.headline); Spacer()
                            Button { state.dial(device, video: false) } label: { Image(systemName: "phone.fill").frame(width: 38, height: 45) }.accessibilityLabel("Llamar a \(device.name) con audio").buttonStyle(.borderless)
                            Button { state.dial(device, video: true) } label: { Image(systemName: "video.fill").frame(width: 38, height: 45) }.accessibilityLabel("Videollamada a \(device.name)").buttonStyle(.borderless)
                        }.padding(.vertical, 7)
                    }
                }
                Section { Text("Grupo público de prueba: los nombres de las instalaciones participantes son visibles para ellas. La verificación facial se realiza localmente; no acredita ante el otro equipo una identidad certificada.").font(.footnote).foregroundStyle(.secondary) }
            }
            .scrollContentBackground(.hidden).background(appBackground)
            .navigationTitle("VideoCall")
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button { settings = true } label: { Image(systemName: "gearshape") }.accessibilityLabel("Ajustes") } }
        }
    }
    private func ringing(_ call: Session) -> some View {
        VStack(spacing: 28) {
            Spacer()
            Image(systemName: call.video ? "video.circle.fill" : "phone.circle.fill").font(.system(size: 100)).foregroundStyle(mint)
            Text(call.name).font(.largeTitle.bold()); Text(state.callPhase).font(.title3).foregroundStyle(.secondary)
            Text(call.video ? "Videollamada" : "Llamada de audio").foregroundStyle(mint)
            Spacer()
            HStack(spacing: 70) {
                roundControl("Rechazar", "phone.down.fill", color: .red) { state.end() }
                if !call.caller { roundControl("Contestar", "phone.fill", color: mint) { state.answer() } }
            }.padding(.bottom, 55)
        }.padding()
    }
    private var settingsView: some View {
        NavigationStack {
            Form {
                Section("Validación") {
                    Text(state.diagnostics).font(.footnote).textSelection(.enabled)
                    Button("Comprobar modelo facial") { state.testModel() }.disabled(state.call != nil || state.faceRequest != nil)
                    Toggle("Forzar TURN en la próxima llamada", isOn: $state.relayOnly).disabled(state.call != nil)
                    Text("Si TURN no responde, una llamada entre ciertas redes puede fallar. Comprueba la ruta en las estadísticas durante una llamada real.").font(.caption).foregroundStyle(.secondary)
                    Button("Conectar") { state.reconnect() }
                }
                Section("Mi registro") {
                    Text("Cinco plantillas cifradas en este equipo. No se guardan fotografías ni se envían al servicio de señalización.").font(.footnote)
                    Button("Borrar mi registro facial", role: .destructive) { confirmDelete = true }.disabled(state.call != nil)
                }
            }.navigationTitle("Ajustes").toolbar { Button("Listo") { settings = false } }
            .confirmationDialog("¿Borrar el registro facial de este iPad?", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("Borrar registro", role: .destructive) { settings = false; state.deleteProfile() }
                Button("Cancelar", role: .cancel) {}
            }
        }
    }
}

func roundControl(_ label: String, _ symbol: String, color: Color = .white.opacity(0.14), action: @escaping () -> Void) -> some View {
    Button(action: action) {
        VStack(spacing: 9) {
            Image(systemName: symbol).font(.system(size: 24, weight: .semibold)).frame(width: 62, height: 62).background(color, in: Circle())
            Text(label).font(.caption)
        }.foregroundStyle(.white)
    }.buttonStyle(.plain).accessibilityLabel(label)
}

struct ActiveCallView: View {
    let session: Session
    @ObservedObject var media: CallMedia
    @EnvironmentObject var state: AppState
    @State private var ownMain = false
    @State private var mirrored = false
    @State private var fill = false
    @State private var showStats = false
    @State private var pip = CGSize.zero
    @GestureState private var drag = CGSize.zero
    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.black.ignoresSafeArea()
                if session.video {
                    video(own: ownMain).frame(width: proxy.size.width, height: proxy.size.height).clipped()
                    VStack { HStack { Spacer(); video(own: !ownMain)
                        .frame(width: 130, height: 175).background(.black)
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                        .overlay(RoundedRectangle(cornerRadius: 20).stroke(.white.opacity(0.35), lineWidth: 1))
                        .shadow(radius: 12).offset(x: pip.width + drag.width, y: pip.height + drag.height)
                        .onTapGesture { ownMain.toggle() }
                        .gesture(DragGesture().updating($drag) { value, state, _ in state = value.translation }
                            .onEnded { value in
                                pip.width = min(0, max(-max(0, proxy.size.width - 175), pip.width + value.translation.width))
                                pip.height = min(max(0, proxy.size.height - 420), max(0, pip.height + value.translation.height))
                            })
                        .accessibilityLabel("Vista pequeña. Toca para intercambiar las cámaras.")
                    }; Spacer() }.padding(.top, 95).padding(.horizontal, 20)
                } else { Image(systemName: "person.crop.circle.fill").font(.system(size: 130)).foregroundStyle(mint.opacity(0.6)) }
                VStack {
                    HStack { VStack(alignment: .leading, spacing: 5) { Text(session.name).font(.title2.bold()); Text(state.callPhase).font(.subheadline).foregroundStyle(.white.opacity(0.8)) }; Spacer()
                        Menu {
                            if session.video {
                                Button("Intercambiar vistas", systemImage: "rectangle.2.swap") { ownMain.toggle() }
                                Button("Cambiar espejo de mi vista", systemImage: "arrow.left.and.right.righttriangle.left.righttriangle.right") { mirrored.toggle() }
                                Button(fill ? "Mostrar imagen completa" : "Llenar pantalla", systemImage: "arrow.up.left.and.arrow.down.right") { fill.toggle() }
                            }
                            Button("Estadísticas", systemImage: "chart.bar") { showStats.toggle() }
                        } label: { Image(systemName: "ellipsis").font(.title2).padding(15).background(.black.opacity(0.3), in: Circle()) }
                    }.padding(24).background(LinearGradient(colors: [.black.opacity(0.8), .clear], startPoint: .top, endPoint: .bottom))
                    if showStats { Text(media.diagnostic).font(.caption.monospaced()).padding(12).background(.black.opacity(0.7), in: Capsule()) }
                    Spacer()
                    if state.remoteMuted { Label("El otro micrófono está silenciado", systemImage: "mic.slash.fill").font(.caption).padding(10).background(.black.opacity(0.7), in: Capsule()) }
                    VStack(spacing: 22) {
                        HStack(spacing: 22) {
                            roundControl(media.muted ? "Activar micro" : "Silenciar", media.muted ? "mic.slash.fill" : "mic.fill") { media.toggleMute(); state.mediaChanged() }
                            roundControl("Altavoz", media.speaker ? "speaker.wave.2.fill" : "speaker.slash.fill", color: media.speaker ? mint.opacity(0.5) : .white.opacity(0.14)) { media.toggleSpeaker() }
                            if session.video {
                                roundControl(media.cameraOff ? "Activar cámara" : "Cámara", media.cameraOff ? "video.slash.fill" : "video.fill") { media.toggleCamera(); state.mediaChanged() }
                                roundControl("Girar", "arrow.triangle.2.circlepath.camera") { media.switchCamera() }
                            }
                        }
                        roundControl("Colgar", "phone.down.fill", color: .red) { state.end() }
                    }.padding(.top, 30).padding(.bottom, 22).frame(maxWidth: .infinity)
                        .background(LinearGradient(colors: [.clear, .black.opacity(0.9)], startPoint: .top, endPoint: .bottom))
                }.foregroundStyle(.white)
            }
        }
    }
    @ViewBuilder private func video(own: Bool) -> some View {
        if own ? media.cameraOff : state.remoteCameraOff {
            ZStack { Color(red: 0.06, green: 0.10, blue: 0.13); Image(systemName: "video.slash.fill").font(.largeTitle).foregroundStyle(.secondary) }
        } else if (own ? media.local : media.remote) == nil {
            ZStack { Color.black; ProgressView("Esperando video…") }
        } else { TrackView(track: own ? media.local : media.remote, mirrored: own && media.front && mirrored, fill: fill) }
    }
}

struct FaceFlowView: View {
    let request: FaceRequest
    @EnvironmentObject var state: AppState
    @State private var name = ""
    @State private var consent = false
    @State private var capture: FaceCapture?
    var body: some View {
        ZStack {
            appBackground.ignoresSafeArea()
            if let capture = capture { FaceCameraView(capture: capture, cancel: state.cancelFace) }
            else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        Image(systemName: "faceid").font(.system(size: 65)).foregroundStyle(mint)
                        Text("Tu rostro, tu perfil").font(.largeTitle.bold())
                        Text("Tomaremos cinco muestras: frente, un giro leve a cada lado, arriba y abajo. No necesitas mostrar el perfil completo.").font(.title3)
                        TextField("Tu nombre en las llamadas", text: $name).textContentType(.name).textFieldStyle(.roundedBorder)
                        Label("Buena luz de frente; ojos, nariz y boca visibles. Mantén el iPad quieto y a la altura de los ojos.", systemImage: "sun.max.fill")
                        Label("La cámara captura automáticamente cuando vas bien. Escucharás un pitido breve si el sonido está activado.", systemImage: "camera.fill")
                        Text("Las fotos se procesan en memoria y se descartan. Guardamos cinco plantillas numéricas cifradas solo en este iPad. Se usan al entrar y antes de contestar. Puedes borrarlas desde Ajustes. Es una comprobación experimental; podría confundirse o aceptar una foto o video.").font(.subheadline).foregroundStyle(.secondary)
                        Toggle("Acepto crear y guardar mi plantilla facial en este equipo", isOn: $consent)
                        Button("Comenzar registro") { begin() }.buttonStyle(.borderedProminent).controlSize(.large)
                            .disabled(!consent || name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        Button("Cancelar", role: .cancel) { state.cancelFace() }
                    }.padding(30).frame(maxWidth: 650).frame(maxWidth: .infinity)
                }
            }
        }.tint(mint)
        .onAppear { if !request.enroll { name = state.profile?.name ?? ""; begin() } }
        .onDisappear { capture?.stop() }
    }
    private func begin() {
        guard capture == nil else { return }
        let value = state.faceCapture(name: String(name.trimmingCharacters(in: .whitespacesAndNewlines).prefix(60)), request: request)
        capture = value; value.start()
    }
}

struct FaceCameraView: View {
    @ObservedObject var capture: FaceCapture
    let cancel: () -> Void
    var body: some View {
        VStack(spacing: 16) {
            HStack { Button("Cancelar", action: cancel); Spacer(); Text("Identificación facial").font(.headline); Spacer()
                Button(action: capture.toggleSound) { Image(systemName: capture.sound ? "speaker.wave.2.fill" : "speaker.slash.fill") }.accessibilityLabel("Activar o desactivar pitido")
            }
            HStack(spacing: 10) { ForEach(0..<capture.feedback.total, id: \.self) { index in
                Image(systemName: index < capture.feedback.accepted ? "checkmark.circle.fill" : "circle").font(.title2).foregroundStyle(index < capture.feedback.accepted ? mint : .white.opacity(0.3))
            }}
            ZStack {
                FacePreview(capture: capture).background(.black)
                FaceHalo(feedback: capture.feedback, mirrored: capture.mirrored).allowsHitTesting(false)
                if capture.feedback.flash { Color.green.opacity(0.15).allowsHitTesting(false) }
            }.clipShape(RoundedRectangle(cornerRadius: 32)).frame(maxWidth: 650, maxHeight: .infinity)
            Text(capture.feedback.pose.title).font(.title2.bold()).multilineTextAlignment(.center)
            Text(capture.feedback.text).font(.headline).foregroundStyle(capture.feedback.fatal ? .orange : capture.feedback.good ? mint : .white.opacity(0.85))
                .multilineTextAlignment(.center).frame(minHeight: 50)
            VStack(spacing: 6) {
                HStack { Text("Encuadre"); Spacer(); Text("\(capture.feedback.score) / 100") }
                ProgressView(value: Double(capture.feedback.score), total: 100).tint(mint)
                Text("No hace falta llegar a 100. Es una guía de posición, no un porcentaje de identidad.").font(.caption2).foregroundStyle(.secondary)
            }.frame(maxWidth: 550)
            Button(action: capture.toggleMirror) { Label("Cambiar vista ↔", systemImage: "arrow.left.arrow.right") }.buttonStyle(.bordered)
        }.padding(22)
    }
}

struct FaceHalo: View {
    let feedback: FaceFeedback
    let mirrored: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? 1 : 1.0 / 30)) { timeline in
            GeometryReader { geometry in
                let t = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
                let pulse = CGFloat(1 + 0.018 * sin(t * 3))
                let width = min(geometry.size.width * 0.63, geometry.size.height * 0.65)
                let height = width * 1.32
                ZStack {
                    Ellipse().stroke(feedback.good ? mint.opacity(0.22) : .white.opacity(0.10), lineWidth: 22).blur(radius: 9)
                    Ellipse().stroke(.white.opacity(0.20), style: StrokeStyle(lineWidth: 3, dash: [5, 9]))
                    Ellipse().trim(from: 0, to: CGFloat(feedback.accepted) / CGFloat(feedback.total))
                        .stroke(mint, style: StrokeStyle(lineWidth: 5, lineCap: .round)).rotationEffect(.degrees(-90))
                    if feedback.pose != .front {
                        let horizontal = feedback.pose == .left || feedback.pose == .right
                        let direction: CGFloat = feedback.pose == .left || feedback.pose == .up ? -1 : 1
                        let visual = horizontal && mirrored ? -direction : direction
                        Image(systemName: horizontal ? (visual < 0 ? "chevron.left.2" : "chevron.right.2") : (direction < 0 ? "chevron.up.2" : "chevron.down.2"))
                            .font(.system(size: 37, weight: .bold)).foregroundStyle(mint)
                            .offset(x: horizontal ? visual * (width * 0.54 + 8 * sin(t * 2.7)) : 0,
                                    y: horizontal ? 0 : direction * (height * 0.54 + 8 * sin(t * 2.7)))
                        Image(systemName: "face.smiling").font(.system(size: 66, weight: .ultraLight)).foregroundStyle(.white.opacity(0.45))
                            .rotation3DEffect(.degrees((horizontal ? 1 : 0) * Double(visual) * 22 * (1 + sin(t * 2)) / 2), axis: (x: 0, y: 1, z: 0))
                            .rotation3DEffect(.degrees((horizontal ? 0 : 1) * Double(direction) * 20 * (1 + sin(t * 2)) / 2), axis: (x: 1, y: 0, z: 0))
                    }
                }.frame(width: width, height: height).scaleEffect(pulse)
                    .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
            }
        }
    }
}
