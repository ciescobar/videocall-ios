import Foundation

@main struct FaceGuidanceChecks {
    static func main() {
        var checks = 0
        func check(_ value: Bool, _ label: String) {
            precondition(value, label); checks += 1
        }
        check(FacePose.left.accepts(yaw: 7, pitch: 0, roll: 0), "Small side turn accepted")
        check(!FacePose.left.accepts(yaw: 6, pitch: 0, roll: 0), "Pose boundary respected")
        check(!FacePose.left.accepts(yaw: 33, pitch: 0, roll: 0), "Full profile not needed")
        check(!FacePose.front.accepts(yaw: .nan, pitch: 0, roll: 0), "NaN rejected")
        check(!FacePose.front.accepts(yaw: 0, pitch: 0, roll: .infinity), "Infinity rejected")
        for pose in FacePose.allCases {
            let direct = pose.direction(mirrored: false), mirror = pose.direction(mirrored: true)
            check(direct.x == -mirror.x && direct.y == mirror.y, "Only horizontal cues flip")
        }
        check(FacePose.left.direction(mirrored: true).x == -1, "Left-pose mirror cue")
        check(FacePose.right.direction(mirrored: false).x == -1, "Right-pose direct cue")
        check(FacePose.up.direction(mirrored: true).y == -1, "Up remains up")
        let perfect = FaceFraming.evaluate(left: 91.2, top: 130, right: 388.8, bottom: 510, width: 480, height: 640)
        check(perfect.score == 100 && perfect.centered && perfect.distance && perfect.inside, "Android ideal framing")
        let offset = FaceFraming.evaluate(left: 139.2, top: 130, right: 436.8, bottom: 510, width: 480, height: 640)
        check(offset.score == 84 && offset.centered, "Android offset score, forgiving center")
        let edge = FaceFraming.evaluate(left: 0, top: 130, right: 297.6, bottom: 510, width: 480, height: 640)
        check(edge.score <= 45 && !edge.inside, "Out-of-image score capped")
        check(FaceFraming.evaluate(left: .nan, top: 0, right: 1, bottom: 1, width: 480, height: 640).score == 0, "Invalid box rejected")
        check(FaceFraming.evaluate(left: 2, top: 0, right: 1, bottom: 1, width: 480, height: 640).score == 0, "Reversed box rejected")
        check(FacePose.left.moved(from: .front, yaw: 9, pitch: 0, previousYaw: 0, previousPitch: 0), "Motion passes at current angle")
        check(!FacePose.left.moved(from: .front, yaw: 2, pitch: 0, previousYaw: 0, previousPitch: 0), "Previous motion cannot latch acceptance")
        check(FacePose.front.moved(from: .left, yaw: 0, pitch: 0, previousYaw: 9, previousPitch: 0), "Return to front requires movement")
        var stability = FaceStability()
        check(!stability.observe(at: 10, good: true), "First frame never captures")
        check(!stability.observe(at: 10.2, good: true), "Short hold insufficient")
        check(stability.observe(at: 10.4, good: true), "350ms hold captures")
        check(!stability.observe(at: 10.5, good: false) && stability.progress == 0, "Bad frame resets and cannot capture")
        check(!stability.observe(at: 11, good: true), "Fresh hold after bad frame")
        check(!stability.observe(at: 13, good: true), "Frame gap resets hold")
        check(!stability.observe(at: 12, good: true), "Clock rollback resets hold")
        stability.reset()
        check(!stability.observe(at: 15, good: true), "Orientation/sample reset requires new hold")
        print("PASS: \(checks) facial guidance checks; no biometric accuracy claim")
    }
}
