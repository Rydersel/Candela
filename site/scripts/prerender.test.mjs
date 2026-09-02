import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import test from 'node:test'
import {
  articleJsonLd,
  buildSitemap,
  guideMetadata,
  guidesIndexMetadata,
  htmlToAgentMarkdown,
  inlineStylesheet,
  injectAppMarkup,
  latestGuideUpdate,
  pageMetadata,
  privacyMetadata,
  rebaseNestedAssets,
  validatePageHtml,
  validateSeoOutput,
} from './prerender.mjs'

const root = new URL('../', import.meta.url)

test('injectAppMarkup puts rendered content inside the app root', () => {
  const shell = '<body><div id="root"></div><script src="/app.js"></script></body>'
  const rendered = '<main><h1>Candela</h1><img src="/assets/tour.webp" alt="" /></main>'

  const result = injectAppMarkup(shell, rendered)

  assert.match(result, /<div id="root"><main><h1>Candela<\/h1>/)
  assert.match(result, /<img src="\.\/assets\/tour\.webp"/)
  assert.match(result, /<script src="\/app\.js"><\/script>/)
})

test('htmlToAgentMarkdown keeps page content and removes browser chrome', () => {
  const html = `<!doctype html><html><head>
    <title>Candela</title>
    <meta name="description" content="Display health for Mac." />
    <meta property="og:image" content="https://candela.fyi/social-card.png" />
  </head><body>
    <header><a href="#main">Skip to content</a></header>
    <main id="main">
      <nav><a href="#features">Features</a></nav>
      <img src="data:image/svg+xml,decorative" alt="" />
      <h1>The display software Apple forgot to ship.</h1>
      <p>Protect your panel with <strong>measured care</strong>.</p>
      <button><span>brew install candela</span><span aria-hidden="true">click to copy</span></button>
      <figure role="img" aria-label="Adaptive dimming keeps moving content bright.">
        <span aria-hidden="true">you move the window</span>
      </figure>
      <a href="https://github.com/rydersel/candela">View the source</a>
    </main>
    <footer>Copyright Candela</footer>
  </body></html>`

  const markdown = htmlToAgentMarkdown(html)

  assert.match(markdown, /^---\ntitle: Candela\ndescription: Display health for Mac\.\nimage: https:\/\/candela\.fyi\/social-card\.png\n---/)
  assert.match(markdown, /# The display software Apple forgot to ship\./)
  assert.match(markdown, /Protect your panel with \*\*measured care\*\*\./)
  assert.match(markdown, /brew install candela/)
  assert.match(markdown, /Adaptive dimming keeps moving content bright\./)
  assert.match(markdown, /\[View the source\]\(https:\/\/github\.com\/rydersel\/candela\)/)
  assert.doesNotMatch(markdown, /Skip to content|Copyright Candela|Features|data:image|click to copy|you move the window|<main/)
})

test('validateSeoOutput accepts the complete production discovery contract', () => {
  const html = `<!doctype html>
    <html lang="en"><head>
      <title>Candela: Display Health and OLED Protection for Mac</title>
      <meta name="description" content="Candela protects OLED displays from burn-in and checks panels for defects and wear." />
      <meta name="robots" content="index, follow" />
      <link rel="canonical" href="https://candela.fyi/" />
      <meta property="og:url" content="https://candela.fyi/" />
      <meta property="og:image" content="https://candela.fyi/social-card.png" />
      <meta name="twitter:card" content="summary_large_image" />
      <script type="application/ld+json">{"@context":"https://schema.org","@type":"SoftwareApplication","name":"Candela"}</script>
    </head><body><div id="root"><main><h1>The display software Apple forgot to ship.</h1></main></div></body></html>`
  const robots = 'User-agent: *\nAllow: /\nSitemap: https://candela.fyi/sitemap.xml\n'
  const sitemap = '<?xml version="1.0"?><urlset><url><loc>https://candela.fyi/</loc></url></urlset>'

  assert.doesNotThrow(() => validateSeoOutput({ html, robots, sitemap }))
})

test('validateSeoOutput rejects a JavaScript-only shell', () => {
  const html = '<html lang="en"><head><title>Candela</title></head><body><div id="root"></div></body></html>'

  assert.throws(
    () => validateSeoOutput({ html, robots: 'User-agent: *', sitemap: '<urlset />' }),
    /pre-rendered h1/i,
  )
})

test('robots.txt advertises the sitemap the build generates', async () => {
  const robots = await readFile(new URL('public/robots.txt', root), 'utf8')
  assert.match(robots, /^User-agent: \*$/m)
  assert.match(robots, /^Sitemap: https:\/\/candela\.fyi\/sitemap\.xml$/m)
})

test('buildSitemap lists every page and dates the ones that carry a date', () => {
  const sitemap = buildSitemap([
    { path: '/' },
    { path: '/privacy/' },
    { path: '/guides/', lastmod: '2026-09-03' },
    { path: '/guides/oled-burn-in-mac/', lastmod: '2026-09-03' },
  ])
  assert.match(sitemap, /^<\?xml version="1\.0" encoding="UTF-8"\?>\n<urlset xmlns="http:\/\/www\.sitemaps\.org\/schemas\/sitemap\/0\.9">/)
  assert.match(sitemap, /<url>\n    <loc>https:\/\/candela\.fyi\/<\/loc>\n  <\/url>/)
  assert.match(sitemap, /<loc>https:\/\/candela\.fyi\/privacy\/<\/loc>/)
  assert.match(sitemap, /<url>\n    <loc>https:\/\/candela\.fyi\/guides\/<\/loc>\n    <lastmod>2026-09-03<\/lastmod>\n  <\/url>/)
  assert.match(sitemap, /<url>\n    <loc>https:\/\/candela\.fyi\/guides\/oled-burn-in-mac\/<\/loc>\n    <lastmod>2026-09-03<\/lastmod>\n  <\/url>/)
  assert.doesNotMatch(sitemap, /<loc>https:\/\/candela\.fyi\/privacy\/<\/loc>\n    <lastmod>/)
  assert.match(sitemap, /<\/urlset>\n$/)
})

test('privacyMetadata gives the public disclosure its own canonical identity', () => {
  const shell = '<title>Landing</title><meta name="description" content="Landing description" /><link rel="canonical" href="https://candela.fyi/" /><meta property="og:url" content="https://candela.fyi/" /><meta property="og:title" content="Landing" /><meta property="og:description" content="Landing description" /><meta name="twitter:title" content="Landing" /><meta name="twitter:description" content="Landing description" />\n      <script type="application/ld+json">{"@type":"SoftwareApplication"}</script>'
  const result = privacyMetadata(shell)
  assert.match(result, /<title>Privacy \| Candela<\/title>/)
  assert.match(result, /content="How Candela's first-party website analytics work, what they do not collect, and how to opt out\."/)
  assert.match(result, /rel="canonical" href="https:\/\/candela\.fyi\/privacy\/"/)
  assert.match(result, /property="og:url" content="https:\/\/candela\.fyi\/privacy\/"/)
  assert.match(result, /property="og:title" content="Privacy \| Candela"/)
  assert.match(result, /name="twitter:title" content="Privacy \| Candela"/)
  assert.match(result, /property="og:description" content="How Candela's first-party/)
  assert.match(result, /name="twitter:description" content="How Candela's first-party/)
  assert.doesNotMatch(result, /Landing/)
  assert.doesNotMatch(result, /ld\+json/)
})

test('inlineStylesheet replaces the built stylesheet link with its contents', () => {
  const shell = '<head><link rel="stylesheet" crossorigin href="./assets/index-abc.css"></head>'
  const out = inlineStylesheet(shell, (href) => (href === './assets/index-abc.css' ? 'body{margin:0}' : null))
  assert.equal(out, '<head><style>body{margin:0}</style></head>')
  const fonts = inlineStylesheet(shell, () => '@font-face{src:url(./sans-abc.woff2)}')
  assert.equal(fonts, '<head><style>@font-face{src:url(/assets/sans-abc.woff2)}</style></head>')
  assert.equal(inlineStylesheet(shell, () => null), shell)
})

test('rebaseNestedAssets points a nested page at the root favicon and assets', () => {
  const out = rebaseNestedAssets('<link rel="icon" href="./favicon.svg" /><img src="./assets/a.webp" srcset="./assets/a.webp 1x, ./assets/b.webp 2x" />')
  assert.equal(out, '<link rel="icon" href="../favicon.svg" /><img src="../assets/a.webp" srcset="../assets/a.webp 1x, ../assets/b.webp 2x" />')
})

const guide = {
  slug: 'oled-burn-in-mac',
  path: '/guides/oled-burn-in-mac/',
  title: 'How to prevent OLED burn-in on a Mac',
  description: 'What wears, what macOS offers, and where software "fills" the gap.',
  published: '2026-09-02',
  updated: '2026-09-03',
  checkedOn: 'macOS 26',
  body: 'Body.',
  html: '<p>Body.</p>',
}

const landingShell = '<title>Landing</title><meta name="description" content="Landing description" /><link rel="canonical" href="https://candela.fyi/" /><meta property="og:type" content="website" /><meta property="og:url" content="https://candela.fyi/" /><meta property="og:title" content="Landing" /><meta property="og:description" content="Landing description" /><meta name="twitter:title" content="Landing" /><meta name="twitter:description" content="Landing description" />\n      <script type="application/ld+json">{"@type":"SoftwareApplication"}</script>'

test('guideMetadata gives a guide its own identity and Article data', () => {
  const result = guideMetadata(landingShell, guide)
  assert.match(result, /<title>How to prevent OLED burn-in on a Mac \| Candela<\/title>/)
  assert.match(result, /<meta name="description" content="What wears, what macOS offers, and where software &quot;fills&quot; the gap\." \/>/)
  assert.match(result, /rel="canonical" href="https:\/\/candela\.fyi\/guides\/oled-burn-in-mac\/"/)
  assert.match(result, /property="og:type" content="article"/)
  assert.match(result, /property="og:url" content="https:\/\/candela\.fyi\/guides\/oled-burn-in-mac\/"/)
  assert.match(result, /property="og:title" content="How to prevent OLED burn-in on a Mac \| Candela"/)
  assert.doesNotMatch(result, /Landing/)
  const entries = JSON.parse(result.match(/<script type="application\/ld\+json">([\s\S]*?)<\/script>/)[1])
  const data = entries.find((entry) => entry['@type'] === 'Article')
  const crumbs = entries.find((entry) => entry['@type'] === 'BreadcrumbList')
  assert.equal(crumbs.itemListElement[2].name, guide.title)
  assert.match(result, /property="article:published_time" content="2026-09-02"/)
  assert.match(result, /property="article:modified_time" content="2026-09-03"/)
  assert.equal(data.headline, guide.title)
  assert.equal(data.datePublished, '2026-09-02')
  assert.equal(data.dateModified, '2026-09-03')
  assert.equal(data.author.name, 'Ryder Selikow')
  assert.equal(data.about['@type'], 'SoftwareApplication')
})

test('guideMetadata carries a dollar sign through instead of expanding it', () => {
  const result = guideMetadata(landingShell, { ...guide, title: 'Costs $5 and $& more', description: 'Group $1 is not a reference' })
  assert.match(result, /<title>Costs \$5 and \$&amp; more \| Candela<\/title>/)
  assert.match(result, /<meta property="og:title" content="Costs \$5 and \$&amp; more \| Candela" \/>/)
  assert.match(result, /<meta name="description" content="Group \$1 is not a reference" \/>/)
  assert.match(result, /<meta name="twitter:description" content="Group \$1 is not a reference" \/>/)
  assert.doesNotMatch(result, /Landing/)
  const data = JSON.parse(result.match(/<script type="application\/ld\+json">([\s\S]*?)<\/script>/)[1]).find((entry) => entry['@type'] === 'Article')
  assert.equal(data.headline, 'Costs $5 and $& more')
})

test('guidesIndexMetadata names the hub and drops the landing structured data', () => {
  const result = guidesIndexMetadata(landingShell)
  assert.match(result, /<title>Guides \| Candela<\/title>/)
  assert.match(result, /rel="canonical" href="https:\/\/candela\.fyi\/guides\/"/)
  assert.doesNotMatch(result, /ld\+json/)
})

test('pageMetadata escapes a closing script tag inside structured data', () => {
  const result = pageMetadata(landingShell, { title: 'T', description: 'D', path: '/x/', jsonLd: { '@type': 'Article', headline: 'a</script><script>b' } })
  assert.doesNotMatch(result, /<\/script><script>b/)
  assert.match(result, /<\\\/script>/)
})

test('articleJsonLd carries the fields the discovery contract checks', () => {
  const data = articleJsonLd(guide)
  assert.equal(data['@context'], 'https://schema.org')
  assert.equal(data.url, 'https://candela.fyi/guides/oled-burn-in-mac/')
  assert.equal(data.mainEntityOfPage, data.url)
  assert.equal(data.image, 'https://candela.fyi/social-card.png')
  assert.equal(data.author.url, 'https://github.com/Rydersel')
  assert.equal(data.publisher.name, 'Candela')
  assert.equal(data.inLanguage, 'en')
})

test('rebaseNestedAssets climbs one directory per level of nesting', () => {
  const html = '<link rel="icon" href="./favicon.svg" /><img src="./assets/a.webp" />'
  assert.equal(rebaseNestedAssets(html, 2), '<link rel="icon" href="../../favicon.svg" /><img src="../../assets/a.webp" />')
})

const articleLd = '<script type="application/ld+json">[{"@type":"Article","headline":"h","description":"d","datePublished":"2026-09-02","dateModified":"2026-09-03","author":{"name":"a"},"image":"i","about":{"@type":"SoftwareApplication"}},{"@type":"BreadcrumbList","itemListElement":[]}]</script>'

function page(path, {
  kind,
  title = 'Page',
  ld = '',
  ogType = kind === 'article' ? 'article' : 'website',
  ogUrl = `https://candela.fyi${path}`,
} = {}) {
  return {
    path,
    kind,
    html: `<html><head><title>${title}</title><meta name="description" content="d" /><meta name="robots" content="index, follow" /><link rel="canonical" href="https://candela.fyi${path}" /><meta property="og:type" content="${ogType}" /><meta property="og:url" content="${ogUrl}" /><meta property="og:image" content="https://candela.fyi/social-card.png" /><meta name="twitter:card" content="summary_large_image" />${ld}</head><body><div id="root"><main><h1>${title}</h1></main></div></body></html>`,
  }
}

test('validatePageHtml checks each kind of page for what it must carry', () => {
  const article = articleLd
  assert.deepEqual(validatePageHtml(page('/guides/x/', { kind: 'article', ld: article }).html, { path: '/guides/x/', kind: 'article' }), [])
  assert.deepEqual(validatePageHtml(page('/privacy/', { kind: 'page' }).html, { path: '/privacy/', kind: 'page' }), [])

  const undated = article.replace('"dateModified":"2026-09-03",', '')
  assert.deepEqual(
    validatePageHtml(page('/guides/x/', { kind: 'article', ld: undated }).html, { path: '/guides/x/', kind: 'article' }),
    ['/guides/x/: Article structured data is missing dateModified'],
  )
  assert.deepEqual(
    validatePageHtml(page('/guides/x/', { kind: 'article' }).html, { path: '/guides/x/', kind: 'article' }),
    ['/guides/x/: structured data does not describe an Article'],
  )
  assert.deepEqual(
    validatePageHtml(page('/privacy/', { kind: 'page', ld: article }).html, { path: '/privacy/', kind: 'page' }),
    ['/privacy/: a page with no identity of its own must carry no structured data'],
  )
  assert.deepEqual(
    validatePageHtml(page('/guides/x/', { kind: 'article', ld: article }).html, { path: '/guides/y/', kind: 'article' }),
    ['/guides/y/: missing its canonical URL', '/guides/y/: missing its Open Graph URL'],
  )
})

// og:url and og:type are set by replacing the landing's exact strings, so a
// shell that stops matching leaves every page claiming to be the landing.
test('validatePageHtml refuses a page that shares the landing identity', () => {
  assert.deepEqual(
    validatePageHtml(page('/guides/x/', { kind: 'article', ld: articleLd, ogUrl: 'https://candela.fyi/' }).html, { path: '/guides/x/', kind: 'article' }),
    ['/guides/x/: missing its Open Graph URL'],
  )
  assert.deepEqual(
    validatePageHtml(page('/privacy/', { kind: 'page', ogUrl: 'https://candela.fyi/' }).html, { path: '/privacy/', kind: 'page' }),
    ['/privacy/: missing its Open Graph URL'],
  )
  assert.deepEqual(
    validatePageHtml(page('/guides/x/', { kind: 'article', ld: articleLd, ogType: 'website' }).html, { path: '/guides/x/', kind: 'article' }),
    ['/guides/x/: missing its article Open Graph type'],
  )
})

test('validatePageHtml requires an article to name its author and its subject', () => {
  const nameless = articleLd.replace('"author":{"name":"a"}', '"author":{"@type":"Person"}')
  assert.deepEqual(
    validatePageHtml(page('/guides/x/', { kind: 'article', ld: nameless }).html, { path: '/guides/x/', kind: 'article' }),
    ['/guides/x/: Article structured data is missing an author name'],
  )
  const subjectless = articleLd.replace(',"about":{"@type":"SoftwareApplication"}', '')
  assert.deepEqual(
    validatePageHtml(page('/guides/x/', { kind: 'article', ld: subjectless }).html, { path: '/guides/x/', kind: 'article' }),
    ['/guides/x/: Article structured data is not about a SoftwareApplication'],
  )
  const wrongSubject = articleLd.replace('"about":{"@type":"SoftwareApplication"}', '"about":{"@type":"Thing"}')
  assert.deepEqual(
    validatePageHtml(page('/guides/x/', { kind: 'article', ld: wrongSubject }).html, { path: '/guides/x/', kind: 'article' }),
    ['/guides/x/: Article structured data is not about a SoftwareApplication'],
  )
})

test('latestGuideUpdate dates the hub from the freshest guide it lists', () => {
  assert.equal(latestGuideUpdate([{ updated: '2026-09-02' }, { updated: '2026-09-11' }, { updated: '2026-08-30' }]), '2026-09-11')
  assert.equal(latestGuideUpdate([{ updated: '2026-09-02' }]), '2026-09-02')
  assert.equal(latestGuideUpdate([]), undefined)
})

test('validateSeoOutput requires every page in the sitemap', () => {
  const landing = page('/', { kind: 'landing', ld: '<script type="application/ld+json">{"@context":"https://schema.org","@type":"SoftwareApplication"}</script>' })
  const robots = 'User-agent: *\nAllow: /\nSitemap: https://candela.fyi/sitemap.xml\n'
  const pages = [page('/privacy/', { kind: 'page' }), page('/guides/', { kind: 'page' })]
  const complete = buildSitemap([{ path: '/' }, ...pages])
  assert.doesNotThrow(() => validateSeoOutput({ html: landing.html, robots, sitemap: complete, pages }))
  assert.throws(
    () => validateSeoOutput({ html: landing.html, robots, sitemap: buildSitemap([{ path: '/' }]), pages }),
    /sitemap\.xml does not list \/privacy\/[\s\S]*sitemap\.xml does not list \/guides\//,
  )
})
