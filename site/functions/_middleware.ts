type Context = {
  request: Request
  next: () => Promise<Response>
  env: {
    ASSETS: {
      fetch(request: Request): Promise<Response>
    }
  }
}

function acceptsMarkdown(value: string | null) {
  if (!value) return false
  return value.split(',').some((range) => {
    const [mediaType, ...parameters] = range.trim().toLowerCase().split(';')
    if (mediaType !== 'text/markdown') return false
    const quality = parameters
      .map((parameter) => parameter.trim())
      .find((parameter) => parameter.startsWith('q='))
    return quality ? Number(quality.slice(2)) > 0 : true
  })
}

function withAcceptVary(headers: Headers) {
  const vary = headers.get('vary')
  const values = vary?.split(',').map((value) => value.trim()) ?? []
  if (!values.some((value) => value.toLowerCase() === 'accept')) values.push('Accept')
  headers.set('vary', values.join(', '))
}

async function htmlResponse(context: Context) {
  const response = await context.next()
  const headers = new Headers(response.headers)
  withAcceptVary(headers)
  return new Response(response.body, {
    headers,
    status: response.status,
    statusText: response.statusText,
  })
}

export const onRequest = async (context: Context) => {
  const url = new URL(context.request.url)
  if (url.pathname !== '/') return context.next()
  if (!acceptsMarkdown(context.request.headers.get('accept'))) return htmlResponse(context)

  let asset: Response
  let markdown: string
  try {
    const markdownUrl = new URL('/index.md', url)
    asset = await context.env.ASSETS.fetch(new Request(markdownUrl, {
      headers: { accept: 'text/plain' },
    }))
    if (!asset.ok) return htmlResponse(context)
    markdown = await asset.text()
  } catch {
    return htmlResponse(context)
  }

  const headers = new Headers(asset.headers)
  headers.set('content-type', 'text/markdown; charset=utf-8')
  headers.set('x-markdown-tokens', String(Math.ceil(markdown.length / 4)))
  withAcceptVary(headers)

  return new Response(markdown, {
    headers,
    status: asset.status,
    statusText: asset.statusText,
  })
}
