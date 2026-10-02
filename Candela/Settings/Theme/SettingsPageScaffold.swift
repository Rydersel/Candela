import SwiftUI

/// The scroll, the content column and the page padding every settings page
/// shares, so a page declares its sections and nothing else.
///
/// The second initialiser exists for pages that scroll to an anchor and need
/// the proxy at build time. The plain one takes content immediately rather than
/// storing an escaping closure, sparing the common call site a rebuild per
/// scroll.
struct SettingsPageScaffold<Content: View>: View {
  private enum Source {
    case plain(Content)
    case reading((ScrollViewProxy) -> Content)
  }

  private let source: Source

  /// Fresh per initialisation, so a parent that rebuilt this scaffold always
  /// reaches the reading closure. The closure is the only part of the input
  /// that changes, and SwiftUI does not reliably count a new closure as a
  /// change [MEASURED 2026-10-02]: the first scaffold of this type in a process
  /// re-ran its body when its page re-rendered, every later one skipped it. A
  /// page whose closure reads plain defaults then kept showing stale values.
  /// The plain form needs nothing, because its content is built by the parent.
  private let rebuild: UUID?

  init(@ViewBuilder content: () -> Content) {
    self.source = .plain(content())
    self.rebuild = nil
  }

  init(@ViewBuilder reading: @escaping (ScrollViewProxy) -> Content) {
    self.source = .reading(reading)
    self.rebuild = UUID()
  }

  var body: some View {
    switch source {
    case let .plain(content):
      page { content }
    case let .reading(build):
      ScrollViewReader { proxy in
        page { build(proxy) }
      }
    }
  }

  private func page(@ViewBuilder _ content: () -> some View) -> some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 15) {
        content()
      }
      .frame(maxWidth: SettingsTheme.pageWidth, alignment: .leading)
      .padding(.horizontal, 32)
      .padding(.top, 24)
      .padding(.bottom, 32)
      // Centers the column as the window widens; content inside stays leading.
      .frame(maxWidth: .infinity)
      .background(OverlayScrollers())
    }
    .labeledContentStyle(ThemedLabeledContentStyle())
  }
}
