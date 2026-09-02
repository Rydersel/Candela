import { readFileSync } from 'node:fs'
import { mkdir, readFile, rm, writeFile } from 'node:fs/promises'
import { pathToFileURL } from 'node:url'
import { JSDOM } from 'jsdom'
import TurndownService from 'turndown'
import { guideAgentMarkdown, guidesIndexMarkdown, llmsText, loadCaptures, loadGuides, siteUrl, yamlScalar } from './guides.mjs'

const canonicalUrl = `${siteUrl}/`

export function htmlToAgentMarkdown(html) {
  const { document } = new JSDOM(html).window
  const main = document.querySelector('main')
  if (!main) throw new Error('Production HTML is missing <main> for agent Markdown')

  for (const visual of main.querySelectorAll('[role="img"][aria-label]')) {
    const description = document.createElement('p')
    description.textContent = visual.getAttribute('aria-label')
    visual.replaceWith(description)
  }
  for (const element of main.querySelectorAll('nav, [aria-hidden="true"], img[alt=""], button[disabled]')) {
    element.remove()
  }
  for (const button of main.querySelectorAll('button')) {
    const text = button.textContent?.trim()
    if (!text) {
      button.remove()
      continue
    }
    const paragraph = document.createElement('p')
    paragraph.textContent = text
    button.replaceWith(paragraph)
  }

  const title =
    document.querySelector('meta[name="title"]')?.getAttribute('content') ??
    document.querySelector('meta[property="og:title"]')?.getAttribute('content') ??
    document.title
  const description =
    document.querySelector('meta[name="description"]')?.getAttribute('content') ??
    document.querySelector('meta[property="og:description"]')?.getAttribute('content')
  const image = document.querySelector('meta[property="og:image"]')?.getAttribute('content')
  const frontmatter = [
    title && `title: ${yamlScalar(title)}`,
    description && `description: ${yamlScalar(description)}`,
    image && `image: ${yamlScalar(image)}`,
  ].filter(Boolean)

  const turndown = new TurndownService({
    bulletListMarker: '-',
    codeBlockStyle: 'fenced',
    headingStyle: 'atx',
  })
  const body = turndown.turndown(main).replace(/\n{3,}/g, '\n\n').trim()
  const metadata = frontmatter.length > 0 ? `---\n${frontmatter.join('\n')}\n---\n\n` : ''
  return `${metadata}${body}\n`
}

export function injectAppMarkup(shell, markup) {
  const rootPattern = /<div id="root"><\/div>/
  if (!rootPattern.test(shell)) throw new Error('Production shell is missing an empty #root')
  // Both the attribute start and the comma-separated candidates of a srcset.
  const portableMarkup = markup.replaceAll('="/assets/', '="./assets/').replaceAll(', /assets/', ', ./assets/')
  return shell.replace(rootPattern, `<div id="root">${portableMarkup}</div>`)
}

// The one stylesheet is small enough to ship inside the document. Fetched
// separately it is the only render-blocking request on the page, and on a slow
// link that round trip is the whole gap between the HTML arriving and the
// first paint.
export function inlineStylesheet(html, readCss) {
  return html.replace(/<link rel="stylesheet"[^>]*href="([^"]+)"[^>]*>/, (tag, href) => {
    const css = readCss(href)
    if (css == null) return tag
    // A url() inside the stylesheet was relative to the stylesheet's own
    // directory; inlined into a page it would resolve against the page instead.
    const dir = href.replace(/^\.\//, '/').replace(/[^/]*$/, '')
    return `<style>${css.replace(/url\(\.\//g, `url(${dir}`)}</style>`
  })
}

function escapeAttribute(value) {
  return value.replaceAll('&', '&amp;').replaceAll('"', '&quot;').replaceAll('<', '&lt;').replaceAll('>', '&gt;')
}

// A page with no structured data of its own drops the landing's, so no nested
// page claims to be the SoftwareApplication.
export function pageMetadata(html, { title, description, path, ogType = 'website', jsonLd = null, image = null, imageAlt = null, published = null, updated = null }) {
  const url = `${siteUrl}${path}`
  const safeTitle = escapeAttribute(title)
  const safeDescription = escapeAttribute(description)
  // A literal </script> inside the JSON would end the element early.
  const structuredData = jsonLd
    ? `\n    <script type="application/ld+json">${JSON.stringify(jsonLd).replaceAll('</', '<\\/')}</script>`
    : ''
  return html
    .replace(/<title>[^<]*<\/title>/, () => `<title>${safeTitle}</title>`)
    .replace(/<meta name="description" content="[^"]*"\s*\/>/, () => `<meta name="description" content="${safeDescription}" />`)
    .replace(`<link rel="canonical" href="${canonicalUrl}" />`, () => `<link rel="canonical" href="${url}" />`)
    .replace('<meta property="og:type" content="website" />', () => `<meta property="og:type" content="${ogType}" />${published ? `\n    <meta property="article:published_time" content="${published}" />\n    <meta property="article:modified_time" content="${updated ?? published}" />` : ''}`)
    .replace(/<meta property="og:image" content="[^"]*"\s*\/>/, (tag) => image ? `<meta property="og:image" content="${image}" />` : tag)
    .replace(/<meta property="og:image:alt" content="[^"]*"\s*\/>/, (tag) => imageAlt ? `<meta property="og:image:alt" content="${escapeAttribute(imageAlt)}" />` : tag)
    .replace(/<meta name="twitter:image" content="[^"]*"\s*\/>/, (tag) => image ? `<meta name="twitter:image" content="${image}" />` : tag)
    .replace(/<meta name="twitter:image:alt" content="[^"]*"\s*\/>/, (tag) => imageAlt ? `<meta name="twitter:image:alt" content="${escapeAttribute(imageAlt)}" />` : tag)
    .replace(`<meta property="og:url" content="${canonicalUrl}" />`, () => `<meta property="og:url" content="${url}" />`)
    .replace(/<meta property="og:title" content="[^"]*"\s*\/>/, () => `<meta property="og:title" content="${safeTitle}" />`)
    .replace(/<meta name="twitter:title" content="[^"]*"\s*\/>/, () => `<meta name="twitter:title" content="${safeTitle}" />`)
    .replace(/<meta property="og:description" content="[^"]*"\s*\/>/, () => `<meta property="og:description" content="${safeDescription}" />`)
    .replace(/<meta name="twitter:description" content="[^"]*"\s*\/>/, () => `<meta name="twitter:description" content="${safeDescription}" />`)
    // A function replacement throughout: a $ in a title, a description or the
    // JSON would otherwise be read as a capture-group reference.
    .replace(/\s*<script type="application\/ld\+json">[\s\S]*?<\/script>/, () => structuredData)
}

const privacyDescription = "How Candela's first-party website analytics work, what they do not collect, and how to opt out."

export function privacyMetadata(html) {
  return pageMetadata(html, { title: 'Privacy | Candela', description: privacyDescription, path: '/privacy/' })
}

const termsDescription = "The terms for candela.fyi, the Candela downloads and the app's update feed, in plain words: who publishes Candela, what the MIT license covers, and what to expect from a tool that adjusts display hardware."

export function termsMetadata(html) {
  return pageMetadata(html, { title: 'Terms | Candela', description: termsDescription, path: '/terms/' })
}

const guidesIndexTitle = 'Guides | Candela'
const guidesIndexDescription = 'Guides to looking after a display on a Mac: what wears a panel, how to check one for defects, and how to get the controls macOS leaves out.'

export function guidesIndexMetadata(html) {
  return pageMetadata(html, { title: guidesIndexTitle, description: guidesIndexDescription, path: '/guides/' })
}

export function breadcrumbJsonLd(guide) {
  return {
    '@context': 'https://schema.org',
    '@type': 'BreadcrumbList',
    itemListElement: [
      { '@type': 'ListItem', position: 1, name: 'Candela', item: canonicalUrl },
      { '@type': 'ListItem', position: 2, name: 'Guides', item: `${siteUrl}/guides/` },
      { '@type': 'ListItem', position: 3, name: guide.title, item: `${siteUrl}${guide.path}` },
    ],
  }
}

export function articleJsonLd(guide) {
  const url = `${siteUrl}${guide.path}`
  return {
    '@context': 'https://schema.org',
    '@type': 'Article',
    headline: guide.title,
    description: guide.description,
    url,
    mainEntityOfPage: url,
    image: guide.image ?? `${siteUrl}/social-card.png`,
    datePublished: guide.published,
    dateModified: guide.updated,
    inLanguage: 'en',
    author: { '@type': 'Person', name: 'Ryder Selikow', url: 'https://github.com/Rydersel' },
    publisher: { '@type': 'Organization', name: 'Candela', url: canonicalUrl },
    about: {
      '@type': 'SoftwareApplication',
      name: 'Candela',
      url: canonicalUrl,
      operatingSystem: 'macOS 14 or later',
      applicationCategory: 'UtilitiesApplication',
    },
  }
}

export function guideMetadata(html, guide) {
  return pageMetadata(html, {
    title: `${guide.title} | Candela`,
    description: guide.description,
    path: guide.path,
    ogType: 'article',
    jsonLd: [articleJsonLd(guide), breadcrumbJsonLd(guide)],
    image: guide.image ?? null,
    imageAlt: guide.image ? guide.title : null,
    published: guide.published,
    updated: guide.updated,
  })
}

export function rebaseNestedAssets(html, depth = 1) {
  const up = '../'.repeat(depth)
  return html
    .replaceAll('="./assets/', `="${up}assets/`)
    .replaceAll(', ./assets/', `, ${up}assets/`)
    .replaceAll('href="./favicon.svg"', `href="${up}favicon.svg"`)
}

// Undefined with no guides, so the sitemap omits the hub's lastmod instead of
// inventing one.
export function latestGuideUpdate(guides) {
  return guides.map((guide) => guide.updated).sort().at(-1)
}

export function buildSitemap(pages) {
  const entries = pages.map(({ path, lastmod }) => {
    const lines = [`    <loc>${siteUrl}${path}</loc>`]
    if (lastmod) lines.push(`    <lastmod>${lastmod}</lastmod>`)
    return `  <url>\n${lines.join('\n')}\n  </url>`
  })
  return `<?xml version="1.0" encoding="UTF-8"?>\n<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">\n${entries.join('\n')}\n</urlset>\n`
}

function structuredData(html) {
  const match = html.match(/<script type="application\/ld\+json">([\s\S]*?)<\/script>/i)
  if (!match) return null
  try {
    const parsed = JSON.parse(match[1])
    return Array.isArray(parsed) ? parsed : [parsed]
  } catch {
    return undefined
  }
}

export function validatePageHtml(html, { path, kind }) {
  const issues = []
  const url = `${siteUrl}${path}`
  if (!/<div id="root">[\s\S]*?<h1(?:\s|>)/i.test(html)) issues.push(`${path}: missing a pre-rendered h1`)
  if (!html.includes(`<link rel="canonical" href="${url}"`)) issues.push(`${path}: missing its canonical URL`)
  // Both og tags are set by replacing the landing's exact strings, so a shell
  // that stops matching leaves every nested page sharing the landing identity.
  if (!html.includes(`<meta property="og:url" content="${url}"`)) issues.push(`${path}: missing its Open Graph URL`)
  if (!/<meta name="description" content="[^"]+"\s*\/>/i.test(html)) issues.push(`${path}: missing its search description`)
  if (!/<meta name="robots" content="index, follow"\s*\/>/i.test(html)) issues.push(`${path}: missing explicit index and follow directives`)
  if (!new RegExp(`<meta property="og:image" content="${siteUrl}/[^"]+"`).test(html)) issues.push(`${path}: missing an absolute Open Graph image`)
  if (!html.includes('<meta name="twitter:card" content="summary_large_image"')) issues.push(`${path}: missing its large Twitter card`)

  const entries = structuredData(html)
  const data = entries ? entries.find((entry) => entry['@type'] === (kind === 'landing' ? 'SoftwareApplication' : 'Article')) : entries
  if (kind === 'landing') {
    if (!data || data['@context'] !== 'https://schema.org') {
      issues.push(`${path}: structured data does not describe a SoftwareApplication`)
    }
  } else if (kind === 'article') {
    if (!html.includes('<meta property="og:type" content="article"')) {
      issues.push(`${path}: missing its article Open Graph type`)
    }
    if (!data) {
      issues.push(`${path}: structured data does not describe an Article`)
    } else {
      if (!entries.some((entry) => entry['@type'] === 'BreadcrumbList')) issues.push(`${path}: Article structured data has no BreadcrumbList beside it`)
      for (const key of ['headline', 'description', 'datePublished', 'dateModified', 'image']) {
        if (!data[key]) issues.push(`${path}: Article structured data is missing ${key}`)
      }
      if (!data.author?.name) issues.push(`${path}: Article structured data is missing an author name`)
      if (data.about?.['@type'] !== 'SoftwareApplication') {
        issues.push(`${path}: Article structured data is not about a SoftwareApplication`)
      }
    }
  } else if (entries !== null) {
    issues.push(`${path}: a page with no identity of its own must carry no structured data`)
  }
  return issues
}

export function validateSeoOutput({ html, robots, sitemap, pages = [] }) {
  const issues = [
    ...validatePageHtml(html, { path: '/', kind: 'landing' }),
    ...pages.flatMap((page) => validatePageHtml(page.html, page)),
  ]
  if (!/^User-agent: \*$/m.test(robots) || !/^Allow: \/$/m.test(robots)) {
    issues.push('robots.txt does not allow the public landing page')
  }
  if (!/^Sitemap: https:\/\/candela\.fyi\/sitemap\.xml$/m.test(robots)) {
    issues.push('robots.txt does not advertise the canonical sitemap')
  }
  for (const path of ['/', ...pages.map((page) => page.path)]) {
    if (!sitemap.includes(`<loc>${siteUrl}${path}</loc>`)) issues.push(`sitemap.xml does not list ${path}`)
  }
  if (issues.length > 0) throw new Error(`SEO output invalid:\n- ${issues.join('\n- ')}`)
}

export async function prerender({ siteRoot = new URL('../', import.meta.url) } = {}) {
  const dist = new URL('dist/', siteRoot)
  const server = new URL('dist-ssr/entry-server.js', siteRoot)
  const [{ render, guidesCopy }, rawShell, robots, guides] = await Promise.all([
    import(pathToFileURL(server.pathname).href),
    readFile(new URL('index.html', dist), 'utf8'),
    readFile(new URL('robots.txt', dist), 'utf8'),
    loadCaptures(siteRoot).then((captures) => loadGuides(new URL('src/content/guides/', siteRoot), { captures })),
  ])
  const shell = inlineStylesheet(rawShell, (href) => readFileSync(new URL(href, dist), 'utf8'))
  const html = injectAppMarkup(shell, render('/', guides))
  const markdown = htmlToAgentMarkdown(html)

  const indexHtml = rebaseNestedAssets(guidesIndexMetadata(injectAppMarkup(shell, render('/guides/', guides))), 1)
  const pages = [
    {
      path: '/privacy/',
      kind: 'page',
      html: rebaseNestedAssets(privacyMetadata(injectAppMarkup(shell, render('/privacy/', guides))), 1),
    },
    {
      path: '/terms/',
      kind: 'page',
      html: rebaseNestedAssets(termsMetadata(injectAppMarkup(shell, render('/terms/', guides))), 1),
    },
    {
      path: '/guides/',
      kind: 'page',
      lastmod: latestGuideUpdate(guides),
      html: indexHtml,
      markdown: guidesIndexMarkdown(guides, {
        title: guidesIndexTitle,
        description: guidesIndexDescription,
        heading: guidesCopy.h1,
        lead: guidesCopy.lead,
      }),
    },
    ...guides.map((guide) => ({
      path: guide.path,
      kind: 'article',
      lastmod: guide.updated,
      html: rebaseNestedAssets(guideMetadata(injectAppMarkup(shell, render(guide.path, guides)), guide), 2),
      markdown: guideAgentMarkdown(guide, guides),
    })),
  ]
  const sitemap = buildSitemap([{ path: '/' }, ...pages])

  validateSeoOutput({ html, robots, sitemap, pages })

  await Promise.all(pages.map((page) => mkdir(new URL(`.${page.path}`, dist), { recursive: true })))
  await Promise.all([
    writeFile(new URL('index.html', dist), html),
    writeFile(new URL('index.md', dist), markdown),
    writeFile(new URL('sitemap.xml', dist), sitemap),
    writeFile(new URL('llms.txt', dist), llmsText(guides, { lead: guidesCopy.lead })),
    ...pages.flatMap((page) => [
      writeFile(new URL(`.${page.path}index.html`, dist), page.html),
      ...(page.markdown ? [writeFile(new URL(`.${page.path}index.md`, dist), page.markdown)] : []),
    ]),
  ])
  await rm(new URL('dist-ssr/', siteRoot), { recursive: true, force: true })
}

const entry = process.argv[1] ? pathToFileURL(process.argv[1]).href : ''
if (import.meta.url === entry) {
  await prerender()
}
