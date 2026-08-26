import CoreGraphics
import Testing

@testable import Candela

/// The flow window leaves the target display only when it has to. A window
/// already off the target stays where the person is looking; one sitting on
/// the target moves to the nearest other screen, never to whichever screen
/// AppKit happens to list first.
@Suite struct CheckupFlowWindowHostTests {
  private let builtIn = CheckupFlowWindowHost.Screen(
    id: 1, frame: CGRect(x: 0, y: 0, width: 1728, height: 1117))
  private let mag = CheckupFlowWindowHost.Screen(
    id: 2, frame: CGRect(x: 1728, y: 0, width: 3440, height: 1440))
  private let dell = CheckupFlowWindowHost.Screen(
    id: 3, frame: CGRect(x: -2160, y: 0, width: 2160, height: 3840))
  private var screens: [CheckupFlowWindowHost.Screen] { [builtIn, mag, dell] }

  private var windowOnBuiltIn: CGRect { CGRect(x: 400, y: 200, width: 760, height: 620) }

  @Test func aWindowAlreadyOffTheTargetStaysPut() {
    let host = CheckupFlowWindowHost.host(
      for: windowOnBuiltIn, target: dell.id, screens: screens)
    #expect(host == nil)
  }

  @Test func aWindowOnTheTargetMovesToTheNearestOtherScreen() {
    let onMagsLeftEdge = CGRect(x: 1800, y: 200, width: 760, height: 620)
    let host = CheckupFlowWindowHost.host(for: onMagsLeftEdge, target: mag.id, screens: screens)
    #expect(host?.id == builtIn.id)

    let onDell = CGRect(x: -1500, y: 1000, width: 760, height: 620)
    #expect(CheckupFlowWindowHost.host(for: onDell, target: dell.id, screens: screens)?.id == builtIn.id)
  }

  @Test func theOnlyScreenBeingTheTargetMeansNowhereToGo() {
    let host = CheckupFlowWindowHost.host(
      for: windowOnBuiltIn, target: builtIn.id, screens: [builtIn])
    #expect(host == nil)
  }

  @Test func noTargetMeansNoMove() {
    #expect(CheckupFlowWindowHost.host(for: windowOnBuiltIn, target: nil, screens: screens) == nil)
  }
}
