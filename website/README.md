# DevHQ website

The landing page and docs for DevHQ. Built with [Astro](https://astro.build),
deployed to GitHub Pages.

## Develop

```sh
npm install
npm run dev      # http://localhost:4321/
```

## Build

```sh
npm run build    # outputs to dist/
npm run preview  # serve the build locally
```

## Configuration

The site is served on the custom domain `https://devhq.app` at the root, so
`astro.config.mjs` sets `base: "/"`. `public/CNAME` pins the domain on GitHub
Pages. Override the canonical URL per build with `SITE_URL` if needed.

## Deploy

`.github/workflows/deploy.yml` builds this directory and publishes to GitHub
Pages on every push to `main` that touches `website/`. One-time setup: repo
**Settings → Pages → Source: GitHub Actions**.

## Structure

```
src/
  components/   Nav, Footer, Workspace mock, CopyCommand
  layouts/      Base (shell) and Docs (sidebar + prose)
  pages/        index.astro and docs/*.md
  lib/          url() base helper, docs nav
  styles/       global.css design tokens
```

Add a docs page: create `src/pages/docs/<slug>.md` with the `Docs` layout, then
register it in `src/lib/docs.ts`.
