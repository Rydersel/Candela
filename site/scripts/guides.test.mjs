import assert from 'node:assert/strict'
import { mkdir, mkdtemp, rm, writeFile } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { pathToFileURL } from 'node:url'
import test from 'node:test'
import { guideAgentMarkdown, guidesIndexMarkdown, headingId, llmsText, loadCaptures, loadGuides, parseFrontmatter, renderGuideBody } from './guides.mjs'

const source = `---
title: How to prevent OLED burn-in on a Mac
description: "What wears, what macOS offers, and where software fills the gap."
published: 2026-09-02
updated: 2026-09-03
checkedOn: macOS 26
order: 10
---

An OLED panel wears where bright, unchanging content sits.

## What actually wears

The menu bar.
`

test('parseFrontmatter reads the block, unquotes strings and defaults the order', () => {
  const { frontmatter, body } = parseFrontmatter(source)
  assert.equal(frontmatter.title, 'How to prevent OLED burn-in on a Mac')
  assert.equal(frontmatter.description, 'What wears, what macOS offers, and where software fills the gap.')
  assert.equal(frontmatter.published, '2026-09-02')
  assert.equal(frontmatter.updated, '2026-09-03')
  assert.equal(frontmatter.checkedOn, 'macOS 26')
  assert.equal(frontmatter.order, 10)
  assert.match(body, /^\nAn OLED panel wears/)

  const { frontmatter: defaulted } = parseFrontmatter(source.replace('order: 10\n', ''))
  assert.equal(defaulted.order, 100)
})

test('parseFrontmatter refuses a guide that cannot be published honestly', () => {
  assert.throws(() => parseFrontmatter('No frontmatter here'), /missing its frontmatter/)
  assert.doesNotThrow(() => parseFrontmatter(source.replace('checkedOn: macOS 26\n', '')))
  assert.throws(() => parseFrontmatter(source.replace('updated: 2026-09-03', 'updated: yesterday')), /updated must be YYYY-MM-DD/)
  assert.throws(() => parseFrontmatter(source.replace('updated: 2026-09-03', 'updated: 2026-13-01')), /updated is not a real calendar date/)
  assert.throws(() => parseFrontmatter(source.replace('updated: 2026-09-03', 'updated: 2026-09-31')), /updated is not a real calendar date/)
  // Also earlier than published: proves the calendar check runs before the ordering one.
  assert.throws(() => parseFrontmatter(source.replace('updated: 2026-09-03', 'updated: 2026-02-30')), /updated is not a real calendar date/)
  assert.throws(() => parseFrontmatter(source.replace('updated: 2026-09-03', 'updated: 2026-09-01')), /before its published date/)
  assert.throws(() => parseFrontmatter(source.replace('order: 10', 'order: first')), /order must be an integer/)
})

test('headingId makes a stable anchor from rendered heading HTML', () => {
  assert.equal(headingId('What actually wears'), 'what-actually-wears')
  assert.equal(headingId('DDC/CI in one paragraph'), 'ddc-ci-in-one-paragraph')
  assert.equal(headingId('Use <code>defaults write</code> &amp; friends'), 'use-defaults-write-friends')
})

test('renderGuideBody adds ids to headings and refuses a second h1', () => {
  const html = renderGuideBody('## What actually wears\n\nThe **menu bar**.\n\n### Sidebars\n\n- one\n- two\n')
  assert.match(html, /<h2 id="what-actually-wears">What actually wears<\/h2>/)
  assert.match(html, /<h3 id="sidebars">Sidebars<\/h3>/)
  assert.match(html, /<strong>menu bar<\/strong>/)
  assert.match(html, /<ul>\s*<li>one<\/li>/)
  assert.throws(() => renderGuideBody('# A title of its own\n\nBody.'), /level-1 heading/)
  assert.throws(() => renderGuideBody('> # Nested title\n'), /level-1 heading/)
  assert.throws(() => renderGuideBody('- # Nested title\n'), /level-1 heading/)
  assert.throws(() => renderGuideBody('<h1>Raw title</h1>\n'), /level-1 heading/)
  assert.doesNotThrow(() => renderGuideBody('```sh\n# a shell comment is not a heading\n```\n'))
})

test('loadGuides reads a directory, derives slugs and sorts by order then title', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'candela-guides-'))
  try {
    await writeFile(join(dir, 'zeta-second.md'), source.replace('order: 10', 'order: 20').replace('OLED burn-in', 'Zeta'))
    await writeFile(join(dir, 'alpha-first.md'), source)
    await writeFile(join(dir, 'notes.txt'), 'ignored')
    const guides = await loadGuides(pathToFileURL(`${dir}/`))
    assert.deepEqual(guides.map((guide) => guide.slug), ['alpha-first', 'zeta-second'])
    assert.equal(guides[0].path, '/guides/alpha-first/')
    assert.match(guides[0].html, /<h2 id="what-actually-wears">/)
    assert.match(guides[0].body, /An OLED panel wears/)

    await writeFile(join(dir, 'Not A Slug.md'), source)
    await assert.rejects(loadGuides(pathToFileURL(`${dir}/`)), /not a URL slug/)
  } finally {
    await rm(dir, { recursive: true, force: true })
  }
})

test('loadGuides returns nothing for a directory that does not exist yet', async () => {
  assert.deepEqual(await loadGuides(pathToFileURL('/nonexistent/candela-guides/')), [])
})

test('guideAgentMarkdown carries the same three frontmatter keys as the landing twin', () => {
  const { frontmatter, body } = parseFrontmatter(source)
  const markdown = guideAgentMarkdown({ ...frontmatter, slug: 'oled-burn-in-mac', path: '/guides/oled-burn-in-mac/', body })
  assert.match(markdown, /^---\ntitle: How to prevent OLED burn-in on a Mac\ndescription: "What wears, what macOS offers, and where software fills the gap\."\nimage: https:\/\/candela\.fyi\/social-card\.png\n---\n\n# How to prevent OLED burn-in on a Mac\n\nAn OLED panel wears/)
  assert.doesNotMatch(markdown, /checkedOn|order:/)
  assert.match(markdown, /\n## More guides\n\n- \[All the guides\]\(\/guides\/\)\n$/)

  const sibling = { ...frontmatter, slug: 'other-guide', path: '/guides/other-guide/', title: 'Another guide', body }
  const linked = guideAgentMarkdown({ ...frontmatter, slug: 'oled-burn-in-mac', path: '/guides/oled-burn-in-mac/', body }, [sibling, { ...frontmatter, slug: 'oled-burn-in-mac', path: '/guides/oled-burn-in-mac/', body }])
  assert.match(linked, /- \[All the guides\]\(\/guides\/\)\n- \[Another guide\]\(\/guides\/other-guide\/\)\n$/)
  assert.doesNotMatch(linked, /\[How to prevent OLED burn-in on a Mac\]\(/)
})

const indexGuides = [
  { title: 'First guide', path: '/guides/first/', description: 'What the first one answers.' },
  { title: 'Second guide', path: '/guides/second/', description: 'What the second one answers.' },
]

const indexOptions = {
  title: 'Guides | Candela',
  description: 'Guides to looking after a display on a Mac.',
  heading: 'Guides',
  lead: 'What wears a panel, and how to check one.',
}

test('guidesIndexMarkdown links every guide, in the order it was given', () => {
  const markdown = guidesIndexMarkdown(indexGuides, indexOptions)
  assert.match(
    markdown,
    /^---\ntitle: "Guides \| Candela"\ndescription: Guides to looking after a display on a Mac\.\nimage: https:\/\/candela\.fyi\/social-card\.png\n---\n\n# Guides\n\nWhat wears a panel, and how to check one\.\n\n/,
  )
  assert.match(
    markdown,
    /\n- \[First guide\]\(\/guides\/first\/\)\n  What the first one answers\.\n- \[Second guide\]\(\/guides\/second\/\)\n  What the second one answers\.\n$/,
  )
  assert.doesNotMatch(markdown, /<\/?[a-z]/i)

  const reversed = guidesIndexMarkdown([...indexGuides].reverse(), indexOptions)
  assert.match(reversed, /\[Second guide\][\s\S]*\[First guide\]/)
})

test('guidesIndexMarkdown holds the lead and the h1 the page shows', () => {
  const markdown = guidesIndexMarkdown([], indexOptions)
  assert.match(markdown, /# Guides\n\nWhat wears a panel, and how to check one\.\n$/)
})

test('renderGuideBody turns a listed image into a figure with its size and caption, and refuses an unlisted one', () => {
  const captures = { '/guides/img/heat-map.webp': { width: 672, height: 680 } }
  const html = renderGuideBody('Intro.\n\n![A map, brightest top left](/guides/img/heat-map.webp "One display after 189 hours & counting")\n\nAfter.\n', captures)
  assert.match(html, /<p>Intro\.<\/p>\n<figure class="guide-figure"><img src="\/guides\/img\/heat-map\.webp" alt="A map, brightest top left" width="672" height="680" loading="lazy" decoding="async" \/><figcaption>One display after 189 hours &amp; counting<\/figcaption><\/figure>\n<p>After\.<\/p>/)
  assert.doesNotMatch(html, /<p><figure|<\/figure><\/p>/)
  assert.throws(() => renderGuideBody('![alt](/guides/img/missing.webp)', captures), /not in the captures manifest: \/guides\/img\/missing\.webp/)
  assert.throws(() => renderGuideBody('![alt](https://example.com/x.png)', captures), /not in the captures manifest/)
})

test('loadCaptures reads the manifest and insists every file exists under public', async () => {
  const root = await mkdtemp(join(tmpdir(), 'candela-captures-'))
  try {
    await mkdir(join(root, 'src/content/guides'), { recursive: true })
    await mkdir(join(root, 'public/guides/img'), { recursive: true })
    await writeFile(join(root, 'public/guides/img/a.webp'), 'x')
    const manifest = join(root, 'src/content/guides/captures.json')
    await writeFile(manifest, JSON.stringify({ '/guides/img/a.webp': { width: 10, height: 20 } }))
    assert.deepEqual(await loadCaptures(pathToFileURL(`${root}/`)), { '/guides/img/a.webp': { width: 10, height: 20 } })

    await writeFile(manifest, JSON.stringify({ '/guides/img/b.webp': { width: 10, height: 20 } }))
    await assert.rejects(loadCaptures(pathToFileURL(`${root}/`)), /ENOENT/)
    await writeFile(manifest, JSON.stringify({ '/elsewhere/a.webp': { width: 10, height: 20 } }))
    await assert.rejects(loadCaptures(pathToFileURL(`${root}/`)), /must live under/)
    await writeFile(manifest, JSON.stringify({ '/guides/img/a.webp': { width: '10', height: 20 } }))
    await assert.rejects(loadCaptures(pathToFileURL(`${root}/`)), /integer width and height/)
  } finally {
    await rm(root, { recursive: true, force: true })
  }
})

test('guideAgentMarkdown makes guide image paths absolute for readers away from the site', () => {
  const { frontmatter } = parseFrontmatter(source)
  const markdown = guideAgentMarkdown({ ...frontmatter, slug: 's', path: '/guides/s/', body: 'See ![alt](/guides/img/heat-map.webp "cap").' })
  assert.match(markdown, /!\[alt\]\(https:\/\/candela\.fyi\/guides\/img\/heat-map\.webp "cap"\)/)
})

test('loadGuides resolves an optional hero image through the manifest and refuses an unlisted one', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'candela-hero-'))
  try {
    const captures = { '/guides/img/header.svg': { width: 1400, height: 600 } }
    await writeFile(join(dir, 'with-hero.md'), source.replace('order: 10\n', 'order: 10\nhero: /guides/img/header.svg\n'))
    await writeFile(join(dir, 'plain.md'), source.replace('order: 10', 'order: 20').replace('OLED burn-in', 'Plain'))
    const guides = await loadGuides(pathToFileURL(`${dir}/`), { captures })
    assert.deepEqual(guides[0].hero, { src: '/guides/img/header.svg', width: 1400, height: 600 })
    assert.equal(guides[1].hero, undefined)

    await writeFile(join(dir, 'with-hero.md'), source.replace('order: 10\n', 'order: 10\nhero: /guides/img/nope.svg\n'))
    await assert.rejects(loadGuides(pathToFileURL(`${dir}/`), { captures }), /hero is not in the captures manifest/)
  } finally {
    await rm(dir, { recursive: true, force: true })
  }
})

test('loadGuides serves an optional social image absolute and refuses an unlisted one', async () => {
  const dir = await mkdtemp(join(tmpdir(), 'candela-image-'))
  try {
    const captures = { '/guides/img/social.png': { width: 1200, height: 630 } }
    await writeFile(join(dir, 'a.md'), source.replace('order: 10\n', 'order: 10\nimage: /guides/img/social.png\n'))
    const [guide] = await loadGuides(pathToFileURL(`${dir}/`), { captures })
    assert.equal(guide.image, 'https://candela.fyi/guides/img/social.png')
    assert.match(guideAgentMarkdown(guide), /^---\ntitle: [^\n]*\ndescription: [^\n]*\nimage: https:\/\/candela\.fyi\/guides\/img\/social\.png\n---/)
    await writeFile(join(dir, 'a.md'), source.replace('order: 10\n', 'order: 10\nimage: /guides/img/nope.png\n'))
    await assert.rejects(loadGuides(pathToFileURL(`${dir}/`), { captures }), /image is not in the captures manifest/)
  } finally {
    await rm(dir, { recursive: true, force: true })
  }
})

test('llmsText lists every guide with an absolute link and its description', () => {
  const text = llmsText([
    { title: 'A', path: '/guides/a/', description: 'About a.' },
    { title: 'B', path: '/guides/b/', description: 'About b.' },
  ], { lead: 'The lead.' })
  assert.match(text, /^# Candela\n\n> The lead\.\n\n## Guides\n\n- \[A\]\(https:\/\/candela\.fyi\/guides\/a\/\): About a\.\n- \[B\]\(https:\/\/candela\.fyi\/guides\/b\/\): About b\.\n/)
})
