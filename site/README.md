# Candela landing page

One-page site for Candela, built with Vite + React + TypeScript.
Design spec: `docs/superpowers/specs/2026-08-28-site-redesign-design.md`.

```sh
npm install
npm run dev       # local dev with HMR
npm test          # interaction and accessibility regression tests
npm run build     # static output in dist/, deployable anywhere (base is './')
npm run preview   # serve the production build locally
```

Constraints as shipped: near-black token theme (`src/theme.css` holds the
palette and type scale every component derives from), runtime deps are
react/react-dom only, and the built page makes no external requests.
`scripts/check-copy.sh` gates em dashes and leftover placeholder assets;
`functions/download.ts` is the Pages Function behind the download button.
