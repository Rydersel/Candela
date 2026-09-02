import { access, readdir, readFile } from 'node:fs/promises'
import { Marked } from 'marked'

export const siteUrl = 'https://candela.fyi'

export function yamlScalar(value) {
  return /^https?:\/\/[^\s]+$/.test(value) || /^[\w./ -]+$/.test(value)
    ? value
    : JSON.stringify(value)
}

const requiredKeys = ['title', 'description', 'published', 'updated']
const isoDate = /^\d{4}-\d{2}-\d{2}$/

export function parseFrontmatter(source) {
  const match = source.match(/^---\n([\s\S]*?)\n---\n/)
  if (!match) throw new Error('Guide is missing its frontmatter block')
  const frontmatter = {}
  for (const line of match[1].split('\n')) {
    if (!line.trim()) continue
    const separator = line.indexOf(':')
    if (separator === -1) throw new Error(`Frontmatter line is not "key: value": ${line}`)
    const key = line.slice(0, separator).trim()
    let value = line.slice(separator + 1).trim()
    if (value.startsWith('"') && value.endsWith('"')) value = JSON.parse(value)
    frontmatter[key] = value
  }
  for (const key of requiredKeys) {
    if (!frontmatter[key]) throw new Error(`Guide frontmatter is missing ${key}`)
  }
  for (const key of ['published', 'updated']) {
    const value = frontmatter[key]
    if (!isoDate.test(value)) throw new Error(`Guide ${key} must be YYYY-MM-DD, got ${value}`)
    // The regex passes 2026-13-01 and 2026-02-30; the first prints "Invalid Date",
    // the second rolls to March 2nd and no longer matches the datetime attribute.
    const parsed = new Date(`${value}T00:00:00Z`)
    if (Number.isNaN(parsed.getTime()) || parsed.toISOString().slice(0, 10) !== value) {
      throw new Error(`Guide ${key} is not a real calendar date: ${value}`)
    }
  }
  if (frontmatter.updated < frontmatter.published) throw new Error('Guide updated date is before its published date')
  frontmatter.order = frontmatter.order === undefined ? 100 : Number(frontmatter.order)
  if (!Number.isInteger(frontmatter.order)) throw new Error('Guide order must be an integer')
  return { frontmatter, body: source.slice(match[0].length) }
}

export function headingId(html) {
  return html
    .replace(/<[^>]+>/g, '')
    .replace(/&[a-z#0-9]+;/gi, '')
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '')
}

function escapeAttribute(value) {
  return value.replaceAll('&', '&amp;').replaceAll('"', '&quot;').replaceAll('<', '&lt;').replaceAll('>', '&gt;')
}

// Heading ids come from the renderer, not an extension, so the anchor rule lives in one place.
// Image sizes come from the captures manifest so the page does not shift while a picture loads.
function engineFor(captures) {
  return new Marked({
    gfm: true,
    renderer: {
      heading({ tokens, depth }) {
        const text = this.parser.parseInline(tokens)
        return `<h${depth} id="${headingId(text)}">${text}</h${depth}>\n`
      },
      // An image-only paragraph is unwrapped: a <p> cannot contain a <figure>.
      paragraph({ tokens }) {
        if (tokens.length === 1 && tokens[0].type === 'image') return this.parser.parseInline(tokens)
        return `<p>${this.parser.parseInline(tokens)}</p>\n`
      },
      image({ href, title, text }) {
        const capture = captures[href]
        if (!capture) throw new Error(`Guide image is not in the captures manifest: ${href}`)
        const caption = title ? `<figcaption>${escapeAttribute(title)}</figcaption>` : ''
        return `<figure class="guide-figure"><img src="${href}" alt="${text}" width="${capture.width}" height="${capture.height}" loading="lazy" decoding="async" />${caption}</figure>\n`
      },
    },
  })
}

// Checked on the HTML, not the token list: an h1 inside a blockquote, a list
// item or raw markup never shows up in a walk over the top-level tokens.
export function renderGuideBody(markdown, captures = {}) {
  const html = engineFor(captures).parse(markdown)
  if (/<h1[\s>]/i.test(html)) {
    throw new Error('Guide body must not contain a level-1 heading; the frontmatter title is the h1')
  }
  return html
}

const slugPattern = /^[a-z0-9]+(?:-[a-z0-9]+)*$/

export async function loadCaptures(siteRoot) {
  const manifest = JSON.parse(await readFile(new URL('src/content/guides/captures.json', siteRoot), 'utf8'))
  for (const [path, capture] of Object.entries(manifest)) {
    if (!path.startsWith('/guides/img/')) throw new Error(`Capture path must live under /guides/img/: ${path}`)
    if (!Number.isInteger(capture.width) || !Number.isInteger(capture.height)) throw new Error(`Capture needs integer width and height: ${path}`)
    await access(new URL(`public${path}`, siteRoot))
  }
  return manifest
}

export async function loadGuides(dir, { captures = {} } = {}) {
  let names
  try {
    names = await readdir(dir)
  } catch (error) {
    if (error.code === 'ENOENT') return []
    throw error
  }
  const guides = []
  for (const name of names.filter((entry) => entry.endsWith('.md')).sort()) {
    const slug = name.slice(0, -'.md'.length)
    if (!slugPattern.test(slug)) throw new Error(`Guide file name is not a URL slug: ${name}`)
    const { frontmatter, body } = parseFrontmatter(await readFile(new URL(name, dir), 'utf8'))
    let hero
    if (frontmatter.hero) {
      const capture = captures[frontmatter.hero]
      if (!capture) throw new Error(`Guide hero is not in the captures manifest: ${frontmatter.hero}`)
      hero = { src: frontmatter.hero, width: capture.width, height: capture.height }
    }
    // Absolute: other sites and the twin's readers fetch it from outside the site.
    let image
    if (frontmatter.image) {
      if (!captures[frontmatter.image]) throw new Error(`Guide image is not in the captures manifest: ${frontmatter.image}`)
      image = `${siteUrl}${frontmatter.image}`
    }
    guides.push({ slug, path: `/guides/${slug}/`, ...frontmatter, hero, image, body, html: renderGuideBody(body, captures) })
  }
  return guides.sort((a, b) => a.order - b.order || a.title.localeCompare(b.title))
}

// The twin an agent reads is the source, not a round trip through the HTML:
// the closing card and the navigation are the page's, not the guide's.
export function guideAgentMarkdown(guide, guides = []) {
  const frontmatter = [
    `title: ${yamlScalar(guide.title)}`,
    `description: ${yamlScalar(guide.description)}`,
    `image: ${guide.image ?? `${siteUrl}/social-card.png`}`,
  ]
  // Same links as the page's More guides block, so an agent reader can move between guides.
  const more = ['- [All the guides](/guides/)', ...guides
    .filter((entry) => entry.slug !== guide.slug)
    .map((entry) => `- [${entry.title}](${entry.path})`)]
  // Site-relative image paths become absolute: the twin is read away from the site.
  const body = guide.body.trim().replaceAll('](/guides/img/', `](${siteUrl}/guides/img/`)
  return `---\n${frontmatter.join('\n')}\n---\n\n# ${guide.title}\n\n${body}\n\n## More guides\n\n${more.join('\n')}\n`
}

// A plain index for AI crawlers that look for one at the site root.
export function llmsText(guides, { lead }) {
  const lines = ['# Candela', '', `> ${lead}`, '', '## Guides', '']
  for (const guide of guides) lines.push(`- [${guide.title}](${siteUrl}${guide.path}): ${guide.description}`)
  lines.push('', '## Site', '', `- [Home](${siteUrl}/): the landing page`, `- [Privacy](${siteUrl}/privacy/): the website analytics disclosure`)
  return `${lines.join('\n')}\n`
}

// Built from the guide list, not the rendered page: a card's anchor wraps block
// content, which no Markdown link can hold, so the round trip dropped every link.
export function guidesIndexMarkdown(guides, { title, description, heading, lead }) {
  const frontmatter = [
    `title: ${yamlScalar(title)}`,
    `description: ${yamlScalar(description)}`,
    `image: ${siteUrl}/social-card.png`,
  ]
  const entries = guides.map((guide) => `- [${guide.title}](${guide.path})\n  ${guide.description}`)
  const list = entries.length > 0 ? `\n${entries.join('\n')}\n` : ''
  return `---\n${frontmatter.join('\n')}\n---\n\n# ${heading}\n\n${lead.trim()}\n${list}`
}
