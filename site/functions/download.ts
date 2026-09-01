// Server-side download counting (SR16). Every hit on /download is one Pages
// Functions invocation, and that invocation count is the download count: the
// hero and footer buttons point here, while Sparkle reads the appcast and
// fetches the archive directly, so update traffic never lands on this route.
// No client-side code is involved, which is what lets the trust section say
// there is no tracking on the page.
//
// GET only is deliberate: a HEAD probe from a link checker or an unfurler falls
// through to the static asset server, so it never inflates the invocation count
// SR16 reads as the download metric.
//
// ARCHIVE_URL must match the current appcast enclosure; the deploy task
// replaces the placeholder and verifies both resolve.
const ARCHIVE_URL = 'https://candela.fyi/CHANGE-AT-DEPLOY.zip'

// Untyped rather than annotated PagesFunction: that type ships in
// @cloudflare/workers-types, and the site takes no new dependencies.
export const onRequestGet = async () => Response.redirect(ARCHIVE_URL, 302)
