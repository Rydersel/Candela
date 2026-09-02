import CoreGraphics
import Foundation

/// Hardware facts read from IOKit during discovery.
///
/// A SIBLING of `ExternalDisplay`, not a widening of it: that type is three
/// fields under the engine's one-submitter invariant, and adding diagnostic
/// fields would touch every construction site and every fixture for the benefit
/// of one read-only pane.
///
/// Every field except the two size fields is already read on every discovery
/// pass by `Arm64DDC.getIoregServicesForMatching` and then dropped by
/// `DisplayDiscovery.discover()`'s `.map`; the sizes come from a dictionary
/// `ioregMatchScore` was already building. Nothing new goes on the DDC wire.
public struct DisplayHardwareFacts: Sendable, Equatable {
  /// The physical link type ("DisplayPort", "HDMI", "USB-C"), carried verbatim
  /// as the panel's IOKit `Transport` dictionary reports it. Deliberately not
  /// normalised or prettified: a pane that invents a vocabulary the kernel never
  /// used lies as soon as the kernel's vocabulary changes.
  public let transportUpstream: String?
  public let transportDownstream: String?
  public let manufacturerID: String?
  /// Often populated when the numeric serial is 0, which is why both are here.
  public let alphanumericSerialNumber: String?
  /// nil for 0: the MAG 341C reports 0, and 0 means "no serial" rather than
  /// serial number zero. The identical-twin collision caveat keys off this nil.
  public let numericSerialNumber: Int64?
  /// Physical panel size in centimetres, as the panel declares it. Two `Int?`
  /// fields rather than a tuple, because a tuple member blocks synthesized
  /// `Equatable`.
  public let physicalWidthCm: Int?
  public let physicalHeightCm: Int?
  /// The IORegistry entry path, which is the port and link path.
  public let ioDisplayLocation: String?
  /// 0…20 from `ioregMatchScore`: how confident the IOReg-to-CGDisplayID match
  /// is. A number because a row stating a number states the
  /// real one.
  public let ioregMatchScore: Int

  public init(
    transportUpstream: String?,
    transportDownstream: String?,
    manufacturerID: String?,
    alphanumericSerialNumber: String?,
    numericSerialNumber: Int64?,
    physicalWidthCm: Int?,
    physicalHeightCm: Int?,
    ioDisplayLocation: String?,
    ioregMatchScore: Int
  ) {
    self.transportUpstream = transportUpstream
    self.transportDownstream = transportDownstream
    self.manufacturerID = manufacturerID
    self.alphanumericSerialNumber = alphanumericSerialNumber
    self.numericSerialNumber = numericSerialNumber
    self.physicalWidthCm = physicalWidthCm
    self.physicalHeightCm = physicalHeightCm
    self.ioDisplayLocation = ioDisplayLocation
    self.ioregMatchScore = ioregMatchScore
  }

  /// The pure half, separated from IOKit so it is testable against fixtures.
  ///
  /// `IOregService`'s string fields default to `""` and its serial to `0` rather
  /// than nil, so "declared nothing" and "declared blank" arrive identical.
  /// Translating here is what stops a row rendering "Transport: " with nothing
  /// after it; a nil renders as an explicit "not reported".
  static func from(
    service: Arm64DDC.IOregService,
    matchScore: Int,
    physicalSizeCm: (width: Int, height: Int)?
  ) -> DisplayHardwareFacts {
    func present(_ raw: String) -> String? { raw.isEmpty ? nil : raw }
    return DisplayHardwareFacts(
      transportUpstream: present(service.transportUpstream),
      transportDownstream: present(service.transportDownstream),
      manufacturerID: present(service.manufacturerID),
      alphanumericSerialNumber: present(service.alphanumericSerialNumber),
      numericSerialNumber: service.serialNumber == 0 ? nil : service.serialNumber,
      physicalWidthCm: physicalSizeCm?.width,
      physicalHeightCm: physicalSizeCm?.height,
      ioDisplayLocation: present(service.ioDisplayLocation),
      ioregMatchScore: matchScore
    )
  }
}
