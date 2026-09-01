import { readFile, rm, writeFile } from 'node:fs/promises'
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
  const portableMarkup = markup.replaceAll('="/assets/', '="./assets/')
  return shell.replace(rootPattern, `<div id="root">${portableMarkup}</div>`)
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
  const [{ render }, shell, robots, sitemap] = await Promise.all([
    import(pathToFileURL(server.pathname).href),
    readFile(new URL('index.html', dist), 'utf8'),
    readFile(new URL('robots.txt', dist), 'utf8'),
    readFile(new URL('sitemap.xml', dist), 'utf8'),
  ])
  const html = injectAppMarkup(shell, render())
  const markdown = htmlToAgentMarkdown(html)

  validateSeoOutput({ html, robots, sitemap })
  await Promise.all([
    writeFile(new URL('index.html', dist), html),
    writeFile(new URL('index.md', dist), markdown),
  ])
  await rm(new URL('dist-ssr/', siteRoot), { recursive: true, force: true })
}

const entry = process.argv[1] ? pathToFileURL(process.argv[1]).href : ''
if (import.meta.url === entry) {
  await prerender()
}
