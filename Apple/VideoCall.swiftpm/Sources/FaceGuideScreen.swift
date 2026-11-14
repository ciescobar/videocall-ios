import SwiftUI

private let faceMint = Color(red: 0.25, green: 0.94, blue: 0.73)
private let faceBlue = Color(red: 0.34, green: 0.70, blue: 1)

struct FaceCameraView: View {
    @ObservedObject var capture: FaceCapture
    let cancel: () -> Void
    private var feedback: FaceFeedback { capture.feedback }
    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width > geometry.size.height && geometry.size.width > 700
            VStack(spacing: 16) {
                HStack {
                    Button(action: cancel) { Image(systemName: "xmark").frame(width: 44, height: 44) }
                        .accessibilityLabel("Cancelar identificación")
                    Spacer()
                    VStack(spacing: 3) {
                        Text("Tu identidad").font(.headline)
                        Text("Paso \(min(feedback.accepted + 1, feedback.total)) de \(feedback.total)")
                            .font(.caption).foregroundStyle(.white.opacity(0.6))
                    }
                    Spacer()
                    Button(action: capture.toggleSound) {
                        Image(systemName: capture.sound ? "speaker.wave.2.fill" : "speaker.slash.fill")
                            .frame(width: 44, height: 44)
                    }.accessibilityLabel(capture.sound ? "Desactivar pitido" : "Activar pitido")
                }
                if wide {
                    HStack(spacing: 24) {
                        camera
                        ScrollView { instructions }.frame(width: min(340, geometry.size.width * 0.36))
                    }
                } else {
                    camera.frame(minHeight: 180, maxHeight: .infinity)
                    ScrollView { instructions }.frame(maxHeight: geometry.size.height * 0.43)
                }
            }.padding(20).frame(maxWidth: 1100).frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(red: 0.025, green: 0.065, blue: 0.085))
        }.tint(faceMint)
    }
    private var camera: some View {
        ZStack(alignment: .top) {
            FacePreview(capture: capture).background(.black)
            FaceHalo(feedback: feedback, mirrored: capture.mirrored).allowsHitTesting(false)
            HStack(spacing: 6) {
                Image(systemName: "lock.shield.fill")
                Text("Procesamiento en este iPad")
            }.font(.caption2.weight(.medium)).padding(.horizontal, 12).padding(.vertical, 8)
                .background(.black.opacity(0.5), in: Capsule()).padding(.top, 14)
        }.clipShape(RoundedRectangle(cornerRadius: 30))
            .overlay(RoundedRectangle(cornerRadius: 30).stroke(.white.opacity(0.1), lineWidth: 1))
    }
    private var instructions: some View {
        VStack(spacing: 14) {
            HStack(spacing: 8) {
                ForEach(0..<feedback.total, id: \.self) { index in
                    ZStack {
                        Circle().fill(index < feedback.accepted ? faceMint : .white.opacity(0.08))
                        if index < feedback.accepted { Image(systemName: "checkmark").font(.caption.bold()).foregroundStyle(.black) }
                        else { Text("\(index + 1)").font(.caption.bold()).foregroundStyle(index == feedback.accepted ? faceMint : .white.opacity(0.4)) }
                    }.frame(width: 30, height: 30)
                        .overlay(Circle().stroke(index == feedback.accepted ? faceMint : .clear, lineWidth: 2))
                }
            }.animation(.easeInOut(duration: 0.25), value: feedback.accepted)
            Text(feedback.fatal ? "Necesitamos intentarlo de nuevo" : feedback.pose.title)
                .font(.title2.bold()).multilineTextAlignment(.center)
            Text(feedback.text).font(.subheadline.weight(.medium))
                .foregroundStyle(feedback.fatal ? .orange : feedback.good ? faceMint : .white.opacity(0.8))
                .multilineTextAlignment(.center).frame(minHeight: 40)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                check("Centro", good: feedback.centered)
                check("Distancia", good: feedback.distance)
                check("Imagen", good: feedback.imageGood)
                check("Posición", good: feedback.poseGood)
            }
            VStack(spacing: 7) {
                HStack {
                    Text(feedback.good ? "Captura automática…" : "Encuadre")
                    Spacer()
                    Text(feedback.good ? "Mantén un instante" : "\(feedback.score) / 100")
                }.font(.caption.weight(.medium))
                ProgressView(value: feedback.good ? feedback.hold : Double(feedback.score) / 100)
                    .tint(faceMint).animation(.linear(duration: 0.1), value: feedback.hold)
                Text("La foto se toma sola. No necesitas llenar el óvalo ni llegar a 100. Sigue las flechas con giros pequeños.")
                    .font(.caption).foregroundStyle(.white.opacity(0.5)).multilineTextAlignment(.center)
            }
            Button(action: capture.toggleMirror) {
                Label(capture.mirrored ? "Vista espejo · cambiar" : "Vista directa · cambiar", systemImage: "arrow.left.arrow.right")
                    .font(.caption.weight(.medium)).padding(.vertical, 4)
            }.buttonStyle(.bordered)
        }.padding(.vertical, 4).frame(maxWidth: 520).frame(maxWidth: .infinity)
    }
    private func check(_ title: String, good: Bool) -> some View {
        Label(title, systemImage: good ? "checkmark.circle.fill" : "circle.dotted")
            .font(.caption2.weight(.medium)).foregroundStyle(good ? faceMint : .white.opacity(0.45))
            .padding(.horizontal, 10).padding(.vertical, 8)
            .background(good ? faceMint.opacity(0.10) : .white.opacity(0.04), in: Capsule())
    }
}

struct FaceHalo: View {
    let feedback: FaceFeedback
    let mirrored: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || feedback.fatal)) { timeline in
            Canvas { context, size in
                draw(context: &context, size: size, now: ProcessInfo.processInfo.systemUptime,
                    animationTime: timeline.date.timeIntervalSinceReferenceDate)
            }
        }.accessibilityHidden(true)
    }
    private func draw(context: inout GraphicsContext, size: CGSize, now: Double, animationTime: Double) {
        guard size.width > 0, size.height > 0 else { return }
        // Match AVCaptureVideoPreviewLayer.resizeAspect, including letterboxing.
        let aspect = max(0.1, feedback.imageAspect)
        let iw = min(size.width, size.height * aspect)
        let ih = iw / aspect
        let image = CGRect(x: (size.width - iw) / 2, y: (size.height - ih) / 2, width: iw, height: ih)
        let ow = min(iw * 0.78, ih * 0.62)
        let oh = min(ih * 0.84, ow * 1.32)
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let oval = CGRect(x: center.x - ow / 2, y: center.y - oh / 2, width: ow, height: oh)
        let t = reduceMotion ? 0 : animationTime
        let pulse = 0.5 + 0.5 * sin(t * 2.6)
        let ink = feedback.good ? faceMint : faceBlue
        var shade = Path(CGRect(origin: .zero, size: size)); shade.addEllipse(in: oval)
        context.fill(shade, with: .color(.black.opacity(0.43)), style: FillStyle(eoFill: true))
        context.stroke(Path(ellipseIn: oval.insetBy(dx: -6 - pulse * 3, dy: -6 - pulse * 3)),
            with: .color(ink.opacity(0.09 + 0.08 * pulse)), lineWidth: 14)
        let progress = min(1, (Double(feedback.accepted) + feedback.hold) / Double(max(1, feedback.total)))
        let direction = feedback.pose.direction(mirrored: mirrored)
        for index in 0..<72 {
            let a = Double(index) / 72 * 2 * .pi - .pi / 2
            let b = a + 0.055
            var segment = Path()
            segment.move(to: CGPoint(x: center.x + cos(a) * ow / 2, y: center.y + sin(a) * oh / 2))
            segment.addLine(to: CGPoint(x: center.x + cos(b) * ow / 2, y: center.y + sin(b) * oh / 2))
            let aimed = cos(a) * direction.x + sin(a) * direction.y > 0.72
            let color: Color = Double(index) / 72 < progress ? faceMint : aimed ? faceBlue : .white.opacity(0.22)
            context.stroke(segment, with: .color(color), style: StrokeStyle(lineWidth: aimed ? 5 : 3, lineCap: .round))
        }
        // Lightweight head demonstrates the requested motion without hiding the camera.
        if !feedback.good && !feedback.fatal {
            let movement = reduceMotion ? 0.65 : (1 + sin(t * 2.4)) / 2
            let shift = CGSize(width: direction.x * ow * 0.055 * movement, height: direction.y * oh * 0.045 * movement)
            let head = CGRect(x: center.x - ow * 0.18 + shift.width, y: center.y - oh * 0.19 + shift.height,
                width: ow * 0.36, height: oh * 0.38)
            context.stroke(Path(ellipseIn: head), with: .color(.white.opacity(0.18)), lineWidth: 2)
            for side in [-1.0, 1.0] {
                let eye = CGRect(x: center.x + side * ow * 0.065 + shift.width * 2 - 3,
                    y: center.y - oh * 0.04 + shift.height * 2 - 2, width: 6, height: 4)
                context.fill(Path(ellipseIn: eye), with: .color(.white.opacity(0.38)))
            }
            var nose = Path()
            nose.move(to: CGPoint(x: center.x + shift.width * 2, y: center.y - 2 + shift.height * 2))
            nose.addLine(to: CGPoint(x: center.x + shift.width * 2 + direction.x * 6, y: center.y + 10 + shift.height * 2))
            context.stroke(nose, with: .color(.white.opacity(0.35)), style: StrokeStyle(lineWidth: 2, lineCap: .round))
            if feedback.pose != .front {
                let arrowCenter = CGPoint(x: center.x + direction.x * (ow * 0.39 + movement * 8),
                    y: center.y + direction.y * (oh * 0.40 + movement * 8))
                var arrow = Path()
                let dx = CGFloat(direction.x), dy = CGFloat(direction.y)
                arrow.move(to: CGPoint(x: arrowCenter.x - dx * 16, y: arrowCenter.y - dy * 16))
                arrow.addLine(to: CGPoint(x: arrowCenter.x + dx * 16, y: arrowCenter.y + dy * 16))
                arrow.move(to: CGPoint(x: arrowCenter.x + dx * 5 - dy * 10, y: arrowCenter.y + dy * 5 + dx * 10))
                arrow.addLine(to: CGPoint(x: arrowCenter.x + dx * 16, y: arrowCenter.y + dy * 16))
                arrow.addLine(to: CGPoint(x: arrowCenter.x + dx * 5 + dy * 10, y: arrowCenter.y + dy * 5 - dx * 10))
                context.stroke(arrow, with: .color(faceMint), style: StrokeStyle(lineWidth: 4, lineCap: .round, lineJoin: .round))
            }
        }
        if feedback.seen && now - feedback.observedAt < 1.4 {
            let box = feedback.faceRect
            let x = mirrored ? 1 - box.maxX : box.minX
            let rect = CGRect(x: image.minX + x * iw, y: image.minY + box.minY * ih,
                width: box.width * iw, height: box.height * ih)
            let color: Color = feedback.centered && feedback.distance ? faceMint : .orange
            context.stroke(Path(roundedRect: rect, cornerRadius: 18), with: .color(color.opacity(0.7)), lineWidth: 1.5)
            if !feedback.centered {
                var line = Path(); line.move(to: CGPoint(x: rect.midX, y: rect.midY)); line.addLine(to: center)
                context.stroke(line, with: .color(color.opacity(0.5)), style: StrokeStyle(lineWidth: 1, dash: [3, 5]))
            }
        }
        let elapsed = now - feedback.capturedAt
        if feedback.capturedAt > 0 && elapsed >= 0 && elapsed < 1 {
            if elapsed < 0.42 {
                context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(faceMint.opacity(0.22 * (1 - elapsed / 0.42))))
            }
            let text = Text("✓ Captura \(feedback.accepted) de \(feedback.total)").font(.headline).foregroundColor(faceMint)
            context.draw(text, at: CGPoint(x: center.x, y: oval.maxY + 26))
        }
    }
}
