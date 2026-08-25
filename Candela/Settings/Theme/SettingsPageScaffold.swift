import SwiftUI

/// The scroll, the content column and the page padding every settings page
/// shares, so a page declares its sections and nothing else.
///
/// Two initialisers because a handful of pages scroll to an anchor and need the
/// proxy at build time. The plain one takes its content immediately rather than
/// storing an escaping closure, which keeps the common call site free of
/// `@escaping` and of a rebuild per scroll.
struct SettingsPageScaffold<Content: View>: View {
  private enum Source {
    case plain(Content)
    case reading((ScrollViewProxy) -> Content)
  }

  private let source: Source

  init(@ViewBuilder content: () -> Content) {
    self.source = .plain(content())
  }

  init(@ViewBuilder reading: @escaping (ScrollViewProxy) -> Content) {
    self.source = .reading(reading)
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
      // The column stays centered as the window widens; the content inside it
      // stays leading.
      .frame(maxWidth: .infinity)
    }
    .labeledContentStyle(ThemedLabeledContentStyle())
  }
}
