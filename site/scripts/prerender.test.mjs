import assert from 'node:assert/strict'
import { readFile } from 'node:fs/promises'
import test from 'node:test'
import { htmlToAgentMarkdown, inlineStylesheet, injectAppMarkup, privacyMetadata, validateSeoOutput } from './prerender.mjs'

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

test('source crawler files advertise the canonical landing page', async () => {
  const [robots, sitemap] = await Promise.all([
    readFile(new URL('public/robots.txt', root), 'utf8'),
    readFile(new URL('public/sitemap.xml', root), 'utf8'),
  ])

  assert.match(robots, /^User-agent: \*$/m)
  assert.match(robots, /^Sitemap: https:\/\/candela\.fyi\/sitemap\.xml$/m)
  assert.match(sitemap, /<loc>https:\/\/candela\.fyi\/<\/loc>/)
  assert.match(sitemap, /<loc>https:\/\/candela\.fyi\/privacy\/<\/loc>/)
})

test('privacyMetadata gives the public disclosure its own canonical identity', () => {
  const shell = '<title>Landing</title><meta name="description" content="Landing description" /><link rel="canonical" href="https://candela.fyi/" /><meta property="og:url" content="https://candela.fyi/" />'
  const result = privacyMetadata(shell)
  assert.match(result, /<title>Privacy \| Candela<\/title>/)
  assert.match(result, /content="How Candela's first-party website analytics work, what they do not collect, and how to opt out\."/)
  assert.match(result, /rel="canonical" href="https:\/\/candela\.fyi\/privacy\/"/)
  assert.match(result, /property="og:url" content="https:\/\/candela\.fyi\/privacy\/"/)
})

test('inlineStylesheet replaces the built stylesheet link with its contents', () => {
  const shell = '<head><link rel="stylesheet" crossorigin href="./assets/index-abc.css"></head>'
  const out = inlineStylesheet(shell, (href) => (href === './assets/index-abc.css' ? 'body{margin:0}' : null))
  assert.equal(out, '<head><style>body{margin:0}</style></head>')
  assert.equal(inlineStylesheet(shell, () => null), shell)
})
