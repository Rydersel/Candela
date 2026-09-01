import { renderToString } from 'react-dom/server'
import App from './App'

export function render(pathname = '/') {
  return renderToString(<App pathname={pathname} />)
}
