import ServiceManagement
import Testing

// The D10 invariant, pinned now that the seam exists: `isEnabled` answers from
// the system on every read, never from a mirror. The fake's backing is mutated
// behind the object's back, exactly what System Settings or sfltool does to
// the real one.
@Suite("Login item") @MainActor
struct LoginItemTests {
  /// A settable stand-in for the system's registration state. A class so the
  /// service closures and the test share one backing.
  @MainActor final class SystemBox {
    var status: SMAppService.Status = .notRegistered
    var registerError: Error?
    var unregisterError: Error?
    private(set) var registerCalls = 0
    private(set) var unregisterCalls = 0

    var service: LoginItemService {
      LoginItemService(
        status: { self.status },
        register: {
          self.registerCalls += 1
          if let e = self.registerError { throw e }
          self.status = .enabled
        },
        unregister: {
          self.unregisterCalls += 1
          if let e = self.unregisterError { throw e }
          self.status = .notRegistered
        })
    }
  }

  struct StubError: Error, LocalizedError {
    var errorDescription: String? { "operation not permitted" }
  }

  @Test func theAnswerTracksTheSystemWithNoRefreshCall() {
    let box = SystemBox()
    let item = LoginItem(service: box.service)
    #expect(!item.isEnabled)
    // The outside-the-app change: no setEnabled, no refresh. A mirror would
    // keep answering the stale value; the live read must not.
    box.status = .enabled
    #expect(item.isEnabled)
    box.status = .notRegistered
    #expect(!item.isEnabled)
  }

  @Test func requiresApprovalReadsAsOff() {
    let box = SystemBox()
    box.status = .requiresApproval
    let item = LoginItem(service: box.service)
    // Not yet launching at login is the truth the toggle must show; approval
    // pending is the error surface's job, not the checkbox's.
    #expect(!item.isEnabled)
  }

  @Test func enablingRegistersAndReadsBackOn() {
    let box = SystemBox()
    let item = LoginItem(service: box.service)
    item.setEnabled(true)
    #expect(box.registerCalls == 1)
    #expect(item.isEnabled)
    #expect(item.lastError == nil)
  }

  @Test func aFailedRegisterShowsOffPlusTheError() {
    let box = SystemBox()
    box.registerError = StubError()
    let item = LoginItem(service: box.service)
    item.setEnabled(true)
    // The fork's lying checkbox, inverted: OFF plus an error, never ON.
    #expect(!item.isEnabled)
    #expect(item.lastError == "operation not permitted")
  }

  @Test func disablingUnregistersAndClearsTheError() {
    let box = SystemBox()
    box.registerError = StubError()
    let item = LoginItem(service: box.service)
    item.setEnabled(true)
    #expect(item.lastError != nil)
    box.registerError = nil
    item.setEnabled(true)
    item.setEnabled(false)
    #expect(box.unregisterCalls == 1)
    #expect(!item.isEnabled)
    #expect(item.lastError == nil)
  }

  @Test func aFailedUnregisterLeavesItOnPlusTheError() {
    let box = SystemBox()
    let item = LoginItem(service: box.service)
    item.setEnabled(true)
    box.unregisterError = StubError()
    item.setEnabled(false)
    #expect(item.isEnabled)
    #expect(item.lastError == "operation not permitted")
  }
}
