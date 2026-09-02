import { renderToString } from 'react-dom/server'
import App from './App'
import type { Guide } from './guides'

// Re-exported for the prerender, which builds the guides hub's Markdown twin
// and cannot import the TypeScript source directly.
export { guides as guidesCopy } from './content/copy'

export function render(pathname = '/', guides: Guide[] = []) {
  return renderToString(<App pathname={pathname} guides={guides} />)
}
