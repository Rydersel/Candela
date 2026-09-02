import { readFileSync } from 'node:fs'
import { mkdir, readFile, rm, writeFile } from 'node:fs/promises'
import { pathToFileURL } from 'node:url'
import { JSDOM } from 'jsdom'
import TurndownService from 'turndown'

const canonicalUrl = 'https://candela.fyi/'

function yamlScalar(value) {
  return /^https?:\/\/[^\s]+$/.test(value) || /^[\w./ -]+$/.test(value)
    ? value
    : JSON.stringify(value)
}

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

const privacyDescription = "How Candela's first-party website analytics work, what they do not collect, and how to opt out."

export function privacyMetadata(html) {
  return html
    .replace(/<title>[^<]*<\/title>/, '<title>Privacy | Candela</title>')
    .replace(/<meta name="description" content="[^"]*"\s*\/>/, `<meta name="description" content="${privacyDescription}" />`)
    .replace('<link rel="canonical" href="https://candela.fyi/" />', '<link rel="canonical" href="https://candela.fyi/privacy/" />')
    .replace('<meta property="og:url" content="https://candela.fyi/" />', '<meta property="og:url" content="https://candela.fyi/privacy/" />')
    .replace(/<meta property="og:title" content="[^"]*"\s*\/>/, '<meta property="og:title" content="Privacy | Candela" />')
    .replace(/<meta name="twitter:title" content="[^"]*"\s*\/>/, '<meta name="twitter:title" content="Privacy | Candela" />')
    .replace(/<meta property="og:description" content="[^"]*"\s*\/>/, `<meta property="og:description" content="${privacyDescription}" />`)
    .replace(/<meta name="twitter:description" content="[^"]*"\s*\/>/, `<meta name="twitter:description" content="${privacyDescription}" />`)
    // The app's structured data describes the landing page; a disclosure
    // page claiming to be the SoftwareApplication would be a duplicate.
    .replace(/\s*<script type="application\/ld\+json">[\s\S]*?<\/script>/, '')
}

export function rebaseNestedAssets(html) {
  return html
    .replaceAll('="./assets/', '="../assets/')
    .replaceAll(', ./assets/', ', ../assets/')
    .replaceAll('href="./favicon.svg"', 'href="../favicon.svg"')
}

export function validateSeoOutput({ html, robots, sitemap }) {
  const issues = []

  if (!/<div id="root">[\s\S]*?<h1(?:\s|>)/i.test(html)) {
    issues.push('Production HTML is missing a pre-rendered h1')
  }
  if (!html.includes(`<link rel="canonical" href="${canonicalUrl}"`)) {
    issues.push('Production HTML is missing the canonical landing URL')
  }
  if (!/<meta name="description" content="[^"]+"\s*\/>/i.test(html)) {
    issues.push('Production HTML is missing its search description')
  }
  if (!/<meta name="robots" content="index, follow"\s*\/>/i.test(html)) {
    issues.push('Production HTML is missing explicit index and follow directives')
  }
  if (!html.includes('<meta property="og:image" content="https://candela.fyi/social-card.png"')) {
    issues.push('Production HTML is missing an absolute Open Graph image')
  }
  if (!html.includes('<meta name="twitter:card" content="summary_large_image"')) {
    issues.push('Production HTML is missing its large Twitter card')
  }

  const structuredData = html.match(
    /<script type="application\/ld\+json">([\s\S]*?)<\/script>/i,
  )
  try {
    const data = JSON.parse(structuredData?.[1] ?? '')
    if (data['@context'] !== 'https://schema.org' || data['@type'] !== 'SoftwareApplication') {
      issues.push('Structured data does not describe a SoftwareApplication')
    }
  } catch {
    issues.push('Production HTML is missing valid JSON-LD structured data')
  }

  if (!/^User-agent: \*$/m.test(robots) || !/^Allow: \/$/m.test(robots)) {
    issues.push('robots.txt does not allow the public landing page')
  }
  if (!/^Sitemap: https:\/\/candela\.fyi\/sitemap\.xml$/m.test(robots)) {
    issues.push('robots.txt does not advertise the canonical sitemap')
  }
  if (!sitemap.includes(`<loc>${canonicalUrl}</loc>`)) {
    issues.push('sitemap.xml does not contain the canonical landing URL')
  }

  if (issues.length > 0) throw new Error(`SEO output invalid:\n- ${issues.join('\n- ')}`)
}

export async function prerender({ siteRoot = new URL('../', import.meta.url) } = {}) {
  const dist = new URL('dist/', siteRoot)
  const server = new URL('dist-ssr/entry-server.js', siteRoot)
  const [{ render }, rawShell, robots, sitemap] = await Promise.all([
    import(pathToFileURL(server.pathname).href),
    readFile(new URL('index.html', dist), 'utf8'),
    readFile(new URL('robots.txt', dist), 'utf8'),
    readFile(new URL('sitemap.xml', dist), 'utf8'),
  ])
  const shell = inlineStylesheet(rawShell, (href) => readFileSync(new URL(href, dist), 'utf8'))
  const html = injectAppMarkup(shell, render('/'))
  const privacyHtml = rebaseNestedAssets(privacyMetadata(injectAppMarkup(shell, render('/privacy/'))))
  const markdown = htmlToAgentMarkdown(html)

  validateSeoOutput({ html, robots, sitemap })
  await mkdir(new URL('privacy/', dist), { recursive: true })
  await Promise.all([
    writeFile(new URL('index.html', dist), html),
    writeFile(new URL('index.md', dist), markdown),
    writeFile(new URL('privacy/index.html', dist), privacyHtml),
  ])
  await rm(new URL('dist-ssr/', siteRoot), { recursive: true, force: true })
}

const entry = process.argv[1] ? pathToFileURL(process.argv[1]).href : ''
if (import.meta.url === entry) {
  await prerender()
}
