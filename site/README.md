# site

The marketing site: two static pages, one stylesheet, no build step and no dependencies.

```
site/
  index.html     the landing page
  pricing.html   Free forever, pay what you want
  style.css      the whole design
  img/           copied from ../docs/media by scripts/site-assets.sh
```

Open `index.html` in a browser to look at it, or serve the folder:

```bash
python3 -m http.server -d site 8000
```

## Deploying

It is deployed by Vercel from `main` with `site` as the root directory, so a merge to `main` is a deploy (the pull request gets a preview). It is plain static files, so anything else would host it too; two that need no configuration:

- **GitHub Pages** — Settings › Pages › Deploy from a branch, folder `/site`.
- **Vercel / Netlify** — point the project at this repository with `site` as the output directory and no build command.

The site is at https://www.notchmeter.com; both pages carry that host in their canonical and share URLs.

## Keeping the pictures current

The images are the app's own renders, not screenshots. Regenerate them and copy them across whenever the UI changes:

```bash
scripts/build.sh
.build/release/Notchmeter --render-assets docs/media
scripts/site-assets.sh
```

## What the pages promise

The download button links at the `Notchmeter.dmg` of the latest GitHub release, so it serves whichever release is
current (v0.1.0 since 2026-09-05), and the Homebrew line names the tap. The figures on the pages (energy, resident
size, poll cadence, what is and is not read) are the README's; change them there first and here second, because a
number on this page that the README cannot back is the one defect the README's own energy section exists to rule out.
