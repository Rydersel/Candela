import CoreGraphics
import Foundation

/// Hardware facts read from IOKit during discovery and, until now, discarded.
///
/// A SIBLING of `ExternalDisplay`, not a widening of it. `ExternalDisplay` is
/// three fields and sits under the engine's one-submitter invariant; putting
/// eight diagnostic fields into it would touch every construction site and
/// every fixture for the benefit of one read-only pane. Keeping the two apart
/// also keeps the write path's value type free of anything a diagnostics pane
/// might later want to mutate or reformat.
///
/// Every field here except `physicalWidthCm`/`physicalHeightCm` is already read
/// on every discovery pass by `Arm64DDC.getIoregServicesForMatching` and then
/// dropped on the floor by `DisplayDiscovery.discover()`'s `.map`; the two size
/// fields are re-read by `Arm64DDC.physicalSizeCm(displayID:)` from a dictionary
/// `ioregMatchScore` was already building and throwing away. Nothing new goes on
/// the DDC wire — no I2C transaction, timing, retry or written value changes.
public struct DisplayHardwareFacts: Sendable, Equatable {
  /// The physical link type — "DisplayPort", "HDMI", "USB-C". THE marquee
  /// diagnostic in this feature. Carried verbatim as the panel's IOKit
  /// `Transport` dictionary reports it; this type deliberately does not
  /// normalise or prettify the spelling, because a diagnostics pane that
  /// invents a vocabulary the kernel never used is a pane that lies when the
  /// kernel's vocabulary changes.
  public let transportUpstream: String?
  public let transportDownstream: String?
  public let manufacturerID: String?
  /// Often populated when the numeric serial is 0, which is why both are here.
  public let alphanumericSerialNumber: String?
  /// nil for 0: the MAG 341C reports 0, and 0 is "no serial", not "serial
  /// number zero" — the identical-twin collision caveat keys off this nil.
  public let numericSerialNumber: Int64?
  /// Physical panel size in centimetres, as the panel declares it. Two `Int?`
  /// fields rather than a tuple — a tuple member blocks synthesized
  /// `Equatable`, and these live in an observable dictionary.
  public let physicalWidthCm: Int?
  public let physicalHeightCm: Int?
  /// The IORegistry entry path — the port/link path.
  public let ioDisplayLocation: String?
  /// 0…20 from `ioregMatchScore`. How confident the IOReg↔CGDisplayID match
  /// is. Reported as a number because DT30 rule (g) says where a row states a
  /// number it states the real one.
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
  /// `IOregService`'s string fields default to `""` and its serial to `0`
  /// rather than to nil, so "the panel declared nothing" and "the panel
  /// declared blank" arrive identical. Translating that HERE is what stops a
  /// row rendering an empty value where a reason was promised (DT30 rule e):
  /// a row that renders "Transport: " with nothing after it has told the user
  /// nothing while looking like it told them something, whereas a nil can be
  /// rendered as an explicit "not reported".
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
