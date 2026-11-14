import Foundation

@main struct FaceGuidanceChecks {
    static func main() {
        var checks = 0
        func check(_ value: Bool, _ label: String) {
            precondition(value, label); checks += 1
        }
        check(FacePose.left.accepts(yaw: 7, pitch: 0, roll: 0), "Small side turn accepted")
        check(!FacePose.left.accepts(yaw: 5, pitch: 0, roll: 0), "Pose boundary respected")
        check(!FacePose.left.accepts(yaw: 40, pitch: 0, roll: 0), "Extreme profile rejected")
        check(FacePose.front.accepts(yaw: 14, pitch: 18, roll: 24), "Comfortable iPad front tilt accepted")
        check(!FacePose.front.accepts(yaw: .nan, pitch: 0, roll: 0), "NaN rejected")
        check(!FacePose.front.accepts(yaw: 0, pitch: 0, roll: .infinity), "Infinity rejected")
        check(FaceAngles.radians(yaw: 0, pitch: nil, roll: 0) == nil, "Missing pitch never becomes fake zero/999")
        check(FaceAngles.radians(yaw: .nan, pitch: 0, roll: 0) == nil, "Invalid detector angles rejected")
        let converted = FaceAngles.radians(yaw: .pi / 18, pitch: .pi / 10, roll: 0)!
        check(abs(converted.yaw - 10) < 0.001 && abs(converted.pitch + 18) < 0.001, "Vision downward pitch converted to guide-negative degrees")
        let angles = FaceAngles(yaw: 10, pitch: 18, roll: 0)
        check(FacePose.up.accepts(yaw: 10, pitch: 24, roll: 0, relativeTo: angles), "Small upward turn relative to natural posture")
        check(FacePose.down.accepts(yaw: 10, pitch: 12, roll: 0, relativeTo: angles), "Small downward turn relative to natural posture")
        check(!FacePose.up.accepts(yaw: 10, pitch: 18, roll: 0, relativeTo: angles), "Neutral posture cannot satisfy upward gesture")
        check(!FacePose.left.accepts(yaw: 43, pitch: 18, roll: 0, relativeTo: angles), "Calibration cannot allow extreme global profile")
        for pose in FacePose.allCases {
            let direct = pose.direction(mirrored: false), mirror = pose.direction(mirrored: true)
            check(direct.x == -mirror.x && direct.y == mirror.y, "Only horizontal cues flip")
        }
        check(FacePose.left.direction(mirrored: true).x == -1, "Left-pose mirror cue")
        check(FacePose.right.direction(mirrored: false).x == -1, "Right-pose direct cue")
        check(FacePose.up.direction(mirrored: true).y == -1, "Up remains up")
        let chinUp = FaceAngles.radians(yaw: 0, pitch: -.pi / 18, roll: 0)!
        let chinDown = FaceAngles.radians(yaw: 0, pitch: .pi / 18, roll: 0)!
        check(FacePose.up.accepts(yaw: chinUp.yaw, pitch: chinUp.pitch, roll: chinUp.roll), "Raw Vision UP activates UP guide")
        check(!FacePose.down.accepts(yaw: chinUp.yaw, pitch: chinUp.pitch, roll: chinUp.roll), "Raw Vision UP cannot satisfy DOWN")
        check(FacePose.down.accepts(yaw: chinDown.yaw, pitch: chinDown.pitch, roll: chinDown.roll), "Raw Vision DOWN activates DOWN guide")
        check(!FacePose.up.accepts(yaw: chinDown.yaw, pitch: chinDown.pitch, roll: chinDown.roll), "Raw Vision DOWN cannot satisfy UP")
        check(FacePose.up.moved(from: .front, yaw: 0, pitch: chinUp.pitch, previousYaw: 0, previousPitch: 0), "Raw UP satisfies upward transition")
        check(FacePose.down.moved(from: .up, yaw: 0, pitch: chinDown.pitch, previousYaw: 0, previousPitch: chinUp.pitch), "Raw DOWN satisfies downward transition")
        check(FacePose.front.moved(from: .down, yaw: 0, pitch: 0, previousYaw: 0, previousPitch: chinDown.pitch), "Return from DOWN to front uses normalized sign")
        for mirror in [false, true] {
            check(FacePose.up.direction(mirrored: mirror).y == -1 && FacePose.down.direction(mirrored: mirror).y == 1,
                "Selfie mirror never reverses vertical gestures")
        }
        let perfect = FaceFraming.evaluate(left: 91.2, top: 130, right: 388.8, bottom: 510, width: 480, height: 640)
        check(perfect.score == 100 && perfect.centered && perfect.distance && perfect.inside, "Android ideal framing")
        let offset = FaceFraming.evaluate(left: 139.2, top: 130, right: 436.8, bottom: 510, width: 480, height: 640)
        check(offset.score == 84 && offset.centered, "Android offset score, forgiving center")
        let distant = FaceFraming.evaluate(left: 185, top: 240, right: 295, bottom: 400, width: 480, height: 640)
        check(distant.distance && distant.centered && distant.inside && distant.score < 100, "Smaller tablet face can capture without a perfect score")
        let edge = FaceFraming.evaluate(left: 0, top: 130, right: 297.6, bottom: 510, width: 480, height: 640)
        check(edge.score <= 45 && !edge.inside, "Out-of-image score capped")
        check(FaceFraming.evaluate(left: .nan, top: 0, right: 1, bottom: 1, width: 480, height: 640).score == 0, "Invalid box rejected")
        check(FaceFraming.evaluate(left: 2, top: 0, right: 1, bottom: 1, width: 480, height: 640).score == 0, "Reversed box rejected")
        check(FacePose.left.moved(from: .front, yaw: 9, pitch: 0, previousYaw: 0, previousPitch: 0), "Motion passes at current angle")
        check(!FacePose.left.moved(from: .front, yaw: 2, pitch: 0, previousYaw: 0, previousPitch: 0), "Previous motion cannot latch acceptance")
        check(FacePose.front.moved(from: .left, yaw: 0, pitch: 0, previousYaw: 9, previousPitch: 0), "Return to front requires movement")
        var stability = FaceStability()
        check(!stability.observe(at: 10, good: true), "First frame never captures")
        check(!stability.observe(at: 10.125, good: true), "Two frames insufficient")
        check(stability.observe(at: 10.25, good: true), "Three valid frames over 250ms capture")
        stability.reset()
        _ = stability.observe(at: 20, good: true)
        _ = stability.observe(at: 20.125, good: true)
        let saved = stability.progress
        check(!stability.observe(at: 20.25, good: false) && stability.progress == saved, "Brief jitter cannot capture but preserves earned progress")
        check(!stability.observe(at: 20.375, good: true) && stability.progress == saved, "Invalid interval adds no hold credit")
        check(stability.observe(at: 20.5, good: true), "Automatic capture recovers after brief jitter")
        check(!stability.observe(at: 21, good: false) && stability.progress == 0, "Long frame gap clears hold")
        _ = stability.observe(at: 21.1, good: true)
        _ = stability.observe(at: 21.225, good: true)
        _ = stability.observe(at: 21.3, good: false)
        check(!stability.observe(at: 21.7, good: true) && stability.progress == 0, "Long invalid interval resets")
        check(!stability.observe(at: 19, good: true) && stability.progress == 0, "Clock rollback resets hold")
        stability.reset()
        check(!stability.observe(at: 15, good: true), "Orientation/sample reset requires new hold")
        var probe = FaceProbe()
        check(probe.observe(match: true, at: 0) == 2, "One matching capture only confirms")
        check(probe.observe(match: true, at: 0.3) == 3, "Two matching captures identify")
        check(probe.observe(match: false, at: 0.6) == 1, "Another face clears identification")
        check(probe.observe(match: true, at: 0.9) == 2, "Must confirm again after mismatch")
        check(probe.observe(match: true, at: 1.2) == 3, "Second fresh match identifies again")
        check(probe.status(at: 2.3) == 0, "Old results expire")
        check(probe.observe(match: true, at: 3) == 2, "Long interruption clears prior matches")
        check(probe.observe(match: true, at: 0) == 2, "Probe clock rollback clears prior matches")
        probe.reset(); check(probe.status(at: 0.1) == 0, "Lost face/close clears probe")
        check(probe.observe(match: true, at: .nan) == 0, "Invalid probe time rejected")
        print("PASS: \(checks) facial guidance checks; no biometric accuracy claim")
    }
}
