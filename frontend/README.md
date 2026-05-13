# brook-site

Landing page for [Brook](https://github.com/Fatumayattani/brook) — a Uniswap v4 hook for predictable, paycheck-style LP yield.

## Stack

Vite + React. No TypeScript, no Tailwind, no framework — just clean React with hand-rolled CSS. Deploys to Netlify with zero config.

## Develop locally

```bash
npm install
npm run dev
```

Then open http://localhost:5173.

## Build

```bash
npm run build
```

Output goes to `dist/`. The `netlify.toml` already points there.

## Deploy

Pushed to GitHub, connected to Netlify, auto-deploys on every push to main.

## Email signup

The form is wired for **Netlify Forms** via the `data-netlify="true"` attribute on the form element. Once deployed, Netlify will detect the form automatically and start collecting submissions to the dashboard. No backend needed.

For local development the form just shows a success state without actually submitting anywhere.

## Roadmap

- [x] PR #1 — Initial landing page (this)
- [ ] Add a small "how it works" animated SVG diagram
- [ ] Add chart preview (lumpy vs smooth yield) once contract is deployed to testnet
- [ ] Wire to deployed contract for live demo (Demo Day prep)

## License

MIT
