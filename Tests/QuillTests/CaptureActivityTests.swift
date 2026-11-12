import Foundation

struct CaptureActivityTests {
    func testSilenceIsHealthyWhenBuffersAreSaved() {
        let activity = CaptureActivity()
        activity.begin(now: 0)
        activity.receive(now: 10)
        activity.saved(frames: 480, peak: 0, now: 10)
        let result = activity.snapshot(now: 10.1)
        precondition(result.state == "Quiet · saving")
        precondition(!(result.warning))
        precondition(result.frames == 480)
        precondition(result.level == 0)
    }

    func testReceivingDoesNotProveSaving() {
        let activity = CaptureActivity()
        activity.begin(now: 0)
        activity.receive(now: 6)
        precondition(activity.snapshot(now: 6).state == "Not saving")
        precondition(activity.snapshot(now: 6).warning)
    }

    func testStallClearsMeterAndRecoversWithNewWrites() {
        let activity = CaptureActivity()
        activity.begin(now: 0)
        precondition(activity.snapshot(now: 1).state == "Waiting")
        activity.receive(now: 1)
        activity.saved(frames: 480, peak: 0.5, now: 1)
        precondition(activity.snapshot(now: 1.1).level > 0)
        precondition(activity.snapshot(now: 2).level == 0)
        precondition(activity.snapshot(now: 7).state == "No data")
        activity.receive(now: 8)
        activity.saved(frames: 480, peak: 0.5, now: 8)
        precondition(!(activity.snapshot(now: 8).warning))
        precondition(activity.snapshot(now: 8).frames == 960)
    }

    func testExplicitFailureSurvivesLaterSuccessfulWrite() {
        let activity = CaptureActivity()
        activity.begin(now: 0)
        activity.fail("Disk full")
        activity.receive(now: 1)
        activity.saved(frames: 480, peak: 1, now: 1)
        precondition(activity.snapshot(now: 1).warning)
        precondition(activity.snapshot(now: 1).error == "Disk full")
        activity.begin(now: 2)
        precondition(!(activity.snapshot(now: 2).warning))
        precondition(activity.snapshot(now: 2).frames == 0)
    }
}

@main
struct CaptureActivityTestRunner {
    static func main() {
        let tests = CaptureActivityTests()
        tests.testSilenceIsHealthyWhenBuffersAreSaved()
        tests.testReceivingDoesNotProveSaving()
        tests.testStallClearsMeterAndRecoversWithNewWrites()
        tests.testExplicitFailureSurvivesLaterSuccessfulWrite()
        print("Capture activity: all 4 tests passed")
    }
}
