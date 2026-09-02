// Built by the prerender for the SSR entry; the client never receives one.
export type Guide = {
  slug: string
  path: string
  title: string
  description: string
  published: string
  updated: string
  checkedOn?: string
  image?: string
  hero?: { src: string; width: number; height: number }
  html: string
}

// A frontmatter date is a calendar day, not an instant. Parsed and printed as
// UTC so the day never shifts with the build machine's zone.
export function formatGuideDate(iso: string) {
  return new Date(`${iso}T00:00:00Z`).toLocaleDateString('en-US', {
    year: 'numeric',
    month: 'long',
    day: 'numeric',
    timeZone: 'UTC',
  })
}
