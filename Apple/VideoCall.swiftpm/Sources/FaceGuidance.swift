import Foundation

// Shared capture rules, independent of camera/UI so they can run on the build host.
enum FacePose: Int, CaseIterable {
    case front, left, right, up, down
    var title: String { ["Mira de frente", "Gira suavemente hacia un lado", "Gira hacia el otro lado", "Mira un poco arriba", "Mira un poco abajo"][rawValue] }
    var symbol: String { ["face.smiling", "arrow.turn.up.left", "arrow.turn.up.right", "arrow.up", "arrow.down"][rawValue] }
    func accepts(yaw: Double, pitch: Double, roll: Double) -> Bool {
        guard yaw.isFinite, pitch.isFinite, roll.isFinite, abs(roll) <= 22 else { return false }
        switch self {
        case .front: return abs(yaw) < 12 && abs(pitch) < 12
        case .left: return yaw > 6 && yaw < 32 && abs(pitch) < 22
        case .right: return yaw < -6 && yaw > -32 && abs(pitch) < 22
        case .up: return pitch > 6 && pitch < 27 && abs(yaw) < 20
        case .down: return pitch < -6 && pitch > -27 && abs(yaw) < 20
        }
    }
    func direction(mirrored: Bool) -> (x: Double, y: Double) {
        let x: Double = self == .left ? 1 : self == .right ? -1 : 0
        return (mirrored ? -x : x, self == .up ? -1 : self == .down ? 1 : 0)
    }
    func moved(from previous: FacePose?, yaw: Double, pitch: Double, previousYaw: Double, previousPitch: Double) -> Bool {
        guard yaw.isFinite, pitch.isFinite else { return false }
        guard let previous = previous else { return true }
        switch self {
        case .left: return yaw - previousYaw >= 4
        case .right: return previousYaw - yaw >= 4
        case .up: return pitch - previousPitch >= 4
        case .down: return previousPitch - pitch >= 4
        case .front:
            switch previous {
            case .left: return previousYaw - yaw >= 4
            case .right: return yaw - previousYaw >= 4
            case .up: return previousPitch - pitch >= 4
            case .down: return pitch - previousPitch >= 4
            case .front: return false
            }
        }
    }
}

struct FaceFraming {
    let score: Int
    let centered: Bool
    let distance: Bool
    let inside: Bool
    static func evaluate(left: Double, top: Double, right: Double, bottom: Double, width: Double, height: Double) -> FaceFraming {
        guard [left, top, right, bottom, width, height].allSatisfy({ $0.isFinite }),
              width > 0, height > 0, right > left, bottom > top else {
            return FaceFraming(score: 0, centered: false, distance: false, inside: false)
        }
        let side = min(width, height)
        let dx = ((left + right) / 2 - width / 2) / side
        let dy = ((top + bottom) / 2 - height / 2) / side
        let size = (right - left) / side
        let inside = left >= 4 && top >= 4 && right <= width - 4 && bottom <= height - 4
        let centerScore = max(0, 1 - hypot(dx, dy) / 0.4)
        let sizeScore = max(0, 1 - abs(size - 0.62) / 0.38)
        let score = Int((100 * (0.65 * centerScore + 0.35 * sizeScore)).rounded())
        return FaceFraming(score: max(0, min(inside ? 100 : 45, score)),
            centered: abs(dx) <= 0.25 && abs(dy) <= 0.28, distance: size >= 0.35 && size <= 0.88, inside: inside)
    }
}

struct FaceStability {
    private var last: Double?
    private var goodTime = 0.0
    private var frames = 0
    var progress: Double { min(1, goodTime / 0.35) }
    mutating func reset() { last = nil; goodTime = 0; frames = 0 }
    mutating func observe(at time: Double, good: Bool) -> Bool {
        guard time.isFinite, good else { reset(); return false }
        if let last = last, time >= last, time - last < 1.2 { goodTime += time - last }
        else { goodTime = 0; frames = 0 }
        last = time; frames += 1
        return frames >= 2 && goodTime >= 0.35
    }
}
