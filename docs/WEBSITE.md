# GitHub Pages website

The static website lives in `website/`; it has no backend, tracking, or runtime build dependency. It includes English/Chinese project copy, an engine compatibility table, illustrated guides, a language switch, and release links.

## Preview locally

```sh
python3 -m http.server 8765 --directory website --bind 127.0.0.1
```

Open `http://127.0.0.1:8765`. Stop the preview when finished.

## Publish

After the prepared project has been committed to `etongle/ModelDock`:

1. Open **Repository → Settings → Pages**.
2. Set **Source** to **GitHub Actions**.
3. Run **Publish documentation website**, or push a change to `website/` on `main`.
4. Check the workflow deployment result. The intended address is `https://etongle.github.io/ModelDock/`; it is not a verified live address until deployment succeeds.

The workflow has read access to source and only the Pages/id-token permissions needed to deploy. The published artifact contains `website/`, not the repository root, development artifacts, application configuration or model files.

## Update content

- `website/index.html`: page structure, accessible navigation and screenshots.
- `website/site.css`: responsive styling.
- `website/site.js`: English/Chinese copy and language/tab behavior.
- `docs/USER_GUIDE*.md`: source guides.
- `website/guide*.html`: rendered static guides.
- `website/assets/`: logo and selected sanitized documentation screenshots.

Regenerate guide HTML with `python3 Tools/build_website_guides.py` (requires the Python `Markdown` package). Ordinary visitors only receive static HTML/CSS/JS. Recheck all links and screenshots after renaming UI actions.

Screenshots must use isolated demonstration data. Never publish a personal state directory, access token, client configuration, logs containing secrets, or real user paths.
