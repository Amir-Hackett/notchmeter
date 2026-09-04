# site

The marketing site: two static pages, one stylesheet, no build step and no dependencies.

```
site/
  index.html     the landing page
  pricing.html   Free forever / Teams
  style.css      the whole design
  img/           copied from ../docs/media by scripts/site-assets.sh
```

Open `index.html` in a browser to look at it, or serve the folder:

```bash
python3 -m http.server -d site 8000
```

## Deploying

It is plain static files, so anything will host it. Two that need no configuration:

- **GitHub Pages** — Settings › Pages › Deploy from a branch, folder `/site`.
- **Vercel / Netlify** — point the project at this repository with `site` as the output directory and no build command.

`notchmeter.app` is the preferred domain (see the Domain section of [docs/roadmap.md](../docs/roadmap.md)); until it is registered the repository URL is the address everywhere.

## Keeping the pictures current

The images are the app's own renders, not screenshots. Regenerate them and copy them across whenever the UI changes:

```bash
scripts/build.sh
.build/release/Notchmeter --render-assets docs/media
scripts/site-assets.sh
```

## Before it goes live

Two placeholders are deliberate and both are marked in the source:

1. **The Teams waitlist form** in `pricing.html` posts nowhere. Point its `action` at a form endpoint — Formspree, Buttondown, Tally, a Cloudflare Worker, whatever you already use — or delete the form and keep the `mailto:` line under it.
2. **`hello@notchmeter.app`** is not a real mailbox yet. Change it to one that is.

Also worth a look before launch: the download button links at the `Notchmeter.dmg` of the latest GitHub release, which does not exist until v0.1.0 is published. The README's Install section says the same thing and carries the same caveat.
