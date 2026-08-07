# Candela landing page

One-page site for Candela, built with Vite + React + TypeScript.
Design spec: `docs/superpowers/specs/2026-08-06-candela-site-design.md`.

```sh
npm install
npm run dev       # local dev with HMR
npm run build     # static output in dist/, deployable anywhere (base is './')
npm run preview   # serve the production build locally
```

Constraints (from the spec): dark-only, macOS dark-mode palette, system font
stack, runtime deps are react/react-dom only, and the built page must make
no external requests.
