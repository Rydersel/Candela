import Testing

// The guided setup flow's commit routing (OB6): each recorded decision lands on
// exactly one existing write path, the launch-at-login write is differs-only
// (OB13), and a kept size is acknowledged rather than applied a second time.
// Every leg is a recorder here, so these pin the rules and nothing else.
@Suite("Onboarding commit router") @MainActor
struct OnboardingCommitRouterTests {
  /// One backing for every leg, so a test can assert what was called AND in
  /// what order. A class for the reason `LoginItemTests`' box is one: the
  /// closures and the test share it.
  @MainActor final class Recorder {
    enum Call: Equatable {
      case rename(String, String)
      case enroll(String)
      case unenroll(String)
      case telemetry(String)
      case telemetryOff(String)
      case launchAtLogin(Bool)
      case acknowledgeSize(String, Int, Int)
    }

    private(set) var calls: [Call] = []
    /// What the system says right now, mutable behind the router's back the way
    /// System Settings changes the real registration.
    var loginItemEnabled = false
    private(set) var loginItemReads = 0

    var router: OnboardingCommitRouter {
      OnboardingCommitRouter(
        writeFriendlyName: { key, name in self.calls.append(.rename(key, name)) },
        enrollInCare: { key in self.calls.append(.enroll(key)) },
        unenrollFromCare: { key in self.calls.append(.unenroll(key)) },
        enableMeasuredTelemetry: { key in self.calls.append(.telemetry(key)) },
        disableMeasuredTelemetry: { key in self.calls.append(.telemetryOff(key)) },
        isLoginItemEnabled: {
          self.loginItemReads += 1
          return self.loginItemEnabled
        },
        setLaunchAtLogin: { on in self.calls.append(.launchAtLogin(on)) },
        acknowledgeAppliedSize: { key, width, height in
          self.calls.append(.acknowledgeSize(key, width, height))
        })
    }
  }

  @Test func aRenameWritesTheFriendlyName() {
    let recorder = Recorder()
    recorder.router.route(.rename(displayKey: "MAG-1", name: "Desk"))
    #expect(recorder.calls == [.rename("MAG-1", "Desk")])
  }

  @Test func anEmptyRenameIsNotWritten() {
    let recorder = Recorder()
    recorder.router.route(.rename(displayKey: "MAG-1", name: ""))
    #expect(recorder.calls.isEmpty)
  }

  /// Blank under any whitespace is the same thing as blank everywhere else in
  /// the app: not a name, and the flow has no clear-the-name gesture for it to
  /// mean instead.
  @Test func aWhitespaceOnlyRenameIsNotWritten() {
    let recorder = Recorder()
    recorder.router.route(.rename(displayKey: "MAG-1", name: "  \n "))
    #expect(recorder.calls.isEmpty)
  }

  @Test func aRenameIsWrittenNormalized() {
    let recorder = Recorder()
    recorder.router.route(.rename(displayKey: "MAG-1", name: "  Desk  "))
    #expect(recorder.calls == [.rename("MAG-1", "Desk")])
  }

  @Test func enrollmentAndTelemetryKeepTheirOrder() {
    let recorder = Recorder()
    let router = recorder.router
    router.route(.enrollInCare(displayKey: "MAG-1"))
    router.route(.enableMeasuredTelemetry(displayKey: "MAG-1"))
    router.route(.enrollInCare(displayKey: "DELL-2"))
    router.route(.enableMeasuredTelemetry(displayKey: "DELL-2"))
    #expect(recorder.calls == [
      .enroll("MAG-1"), .telemetry("MAG-1"), .enroll("DELL-2"), .telemetry("DELL-2"),
    ])
  }

  @Test func unenrollmentRoutesToItsOwnLeg() {
    let recorder = Recorder()
    recorder.router.route(.unenrollFromCare(displayKey: "MAG-1"))
    #expect(recorder.calls == [.unenroll("MAG-1")])
  }

  @Test func turningMeasurementOffRoutesToItsOwnLeg() {
    let recorder = Recorder()
    recorder.router.route(.disableMeasuredTelemetry(displayKey: "MAG-1"))
    #expect(recorder.calls == [.telemetryOff("MAG-1")])
  }

  /// The off commits are routed, never re-interpreted: an un-enrollment must
  /// not drag the measurement pref down with it, because a later re-enrollment
  /// should find the choice the user made.
  @Test func unenrollmentDoesNotTouchTheMeasurementLeg() {
    let recorder = Recorder()
    let router = recorder.router
    router.route(.unenrollFromCare(displayKey: "MAG-1"))
    router.route(.unenrollFromCare(displayKey: "DELL-2"))
    #expect(recorder.calls == [.unenroll("MAG-1"), .unenroll("DELL-2")])
  }

  @Test func enrollmentAndTelemetryOffKeepTheirOrder() {
    let recorder = Recorder()
    let router = recorder.router
    router.route(.enrollInCare(displayKey: "MAG-1"))
    router.route(.disableMeasuredTelemetry(displayKey: "MAG-1"))
    router.route(.enrollInCare(displayKey: "DELL-2"))
    router.route(.disableMeasuredTelemetry(displayKey: "DELL-2"))
    #expect(recorder.calls == [
      .enroll("MAG-1"), .telemetryOff("MAG-1"), .enroll("DELL-2"), .telemetryOff("DELL-2"),
    ])
  }

  @Test func telemetryAloneRoutesWithoutEnrolling() {
    let recorder = Recorder()
    recorder.router.route(.enableMeasuredTelemetry(displayKey: "MAG-1"))
    #expect(recorder.calls == [.telemetry("MAG-1")])
  }

  @Test func launchAtLoginIsWrittenWhenItDiffers() {
    let recorder = Recorder()
    recorder.loginItemEnabled = false
    recorder.router.route(.setLaunchAtLogin(true))
    #expect(recorder.calls == [.launchAtLogin(true)])

    let off = Recorder()
    off.loginItemEnabled = true
    off.router.route(.setLaunchAtLogin(false))
    #expect(off.calls == [.launchAtLogin(false)])
  }

  @Test func launchAtLoginIsNotWrittenWhenItMatches() {
    let alreadyOn = Recorder()
    alreadyOn.loginItemEnabled = true
    alreadyOn.router.route(.setLaunchAtLogin(true))
    #expect(alreadyOn.calls.isEmpty)

    let alreadyOff = Recorder()
    alreadyOff.loginItemEnabled = false
    alreadyOff.router.route(.setLaunchAtLogin(false))
    #expect(alreadyOff.calls.isEmpty)
  }

  /// The gate compares against the system at routing time, not against a value
  /// captured earlier: the same router answers differently after the state
  /// changes behind it.
  @Test func theGateReadsTheLiveStateEveryTime() {
    let recorder = Recorder()
    let router = recorder.router
    recorder.loginItemEnabled = true
    router.route(.setLaunchAtLogin(true))
    recorder.loginItemEnabled = false
    router.route(.setLaunchAtLogin(true))
    #expect(recorder.calls == [.launchAtLogin(true)])
    #expect(recorder.loginItemReads == 2)
  }

  /// The apply already happened interactively, with its keep and revert
  /// countdown answered. The router has no apply leg at all, so this pins that
  /// a size commit produces the acknowledgement and nothing else.
  @Test func aKeptSizeIsAcknowledgedAndNotReapplied() {
    let recorder = Recorder()
    recorder.router.route(
      .applySize(displayKey: "MAG-1", looksLikeWidth: 2560, looksLikeHeight: 1080))
    #expect(recorder.calls == [.acknowledgeSize("MAG-1", 2560, 1080)])
  }
}
