# Candela landing page

Candela's landing and Privacy pages, built with Vite + React + TypeScript and
hosted on Cloudflare Pages.
Design spec: `docs/superpowers/specs/2026-08-28-site-redesign-design.md`.

```sh
npm install
npm run dev       # local dev with HMR
npm test          # interaction and accessibility regression tests
npm run build     # static output in dist/, deployable anywhere (base is './')
npm run preview   # serve the production build locally
npm run analytics:report -- --days 7
npm run analytics:report -- --days 30 --format csv
```

`scripts/check-copy.sh` gates em dashes and leftover placeholder assets.
`functions/` contains the narrow Pages Function surface for Markdown content
negotiation, the anonymous 24-hour analytics funnel, and fixed release/GitHub
redirects. `migrations/` is the D1 schema. `analytics-worker/` finalizes
seven-day pseudonymous records into thresholded anonymous rollups.

## Cloudflare setup

The Pages and Worker configurations are checked in as `wrangler.jsonc` and
`analytics-worker/wrangler.jsonc`. Production and preview bind separate D1
databases as `ANALYTICS_DB`.

Set these secrets without committing them:

```sh
npx wrangler pages secret put ANALYTICS_SIGNING_KEY --project-name candela-site
npx wrangler pages secret put RELEASE_DOWNLOAD_URL --project-name candela-site
```

The signing value must be a freshly generated high-entropy secret. Production
and preview must not share it. The release URL must match the current enclosure
in `public/appcast.xml` before Download is enabled.

Apply and deploy from this `site/` directory. Running the Pages deploy from the
repository root omits `site/functions` and silently produces a static-only
deployment.

```sh
npm run d1:migrate:local
npm run d1:migrate:remote
npx wrangler deploy --config analytics-worker/wrangler.jsonc
npm run build
npx wrangler pages deploy dist --project-name candela-site --branch main
```

The public Cloudflare Web Analytics token is provided to the build as
`VITE_CLOUDFLARE_WEB_ANALYTICS_TOKEN`. The browser bootstrap inserts the beacon
only when `candela_analytics=off` is absent.

The report command requires a separate read-only token in
`CLOUDFLARE_API_TOKEN` plus `CLOUDFLARE_ACCOUNT_ID` and
`CANDELA_ANALYTICS_DATABASE_ID`. It never prints those values.

## Release verification

- Pages deployment metadata reports `uses_functions: true`.
- `curl -H 'Accept: text/markdown' https://candela.fyi/` returns Markdown.
- `/privacy/` describes both analytics systems and exposes the opt-out.
- `/github?placement=hero` redirects to the fixed repository URL.
- Videos and hashed assets bypass Functions and preserve immutable caching and
  byte-range responses.
- The appcast enclosure and `RELEASE_DOWNLOAD_URL` identify the same archive.
