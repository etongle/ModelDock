# Contributing to ModelDock

Contributions are made under this project's PolyForm Noncommercial 1.0.0 terms. Review LICENSE and required notices before submitting changes. Respect the separate licenses of bundled dependencies, engines and model weights.

## Local development

Build on Apple Silicon with Xcode Command Line Tools. Follow README for the portable Python runtime. Do not commit `build/`, `dist/`, `artifacts/`, model weights, tokens, native client settings, or personal state.

## Localization

The interface supports `en`, `zh-Hans`, `fr`, and `pt`; English is the first-launch default. `Resources/Localization/*.json` share the same source-message keys. The source key is a stable presentation message, not a translated storage identifier.

- Use `L10n.text(...)` at a UI boundary for owned labels, dynamic status text and error messages.
- Keep model/API IDs, CLI flags, file paths, raw engine logs and persisted enum values stable.
- Preserve numbered placeholders exactly, including their repeated occurrences. Translations may reorder them.
- Add translations to every catalog. `Tools/extract_localization.py` lists source messages; `Tools/review_localization.py` applies reviewed terminology. Generated translations are drafts and need review.
- Run `ModelDock.app/Contents/MacOS/ModelManager --localization-checks --check-dir <isolated-folder>`.
- Check long French/Portuguese labels at the minimum window size, live language switching, and language persistence.

To make documentation screenshots, use the `--documentation-ui` capture mode with a fresh `--state-dir`, `--capture-dir`, `--passive-test`, and `--capture-only`. This mode uses demonstration data and never starts a real model or writes a user's client configuration. Preserve the demonstration-data captions in public documentation.

## Website

The website is buildless HTML/CSS/JS. Edit both languages in `website/site.js`; keep relative URLs compatible with GitHub Pages under `/ModelDock/`. Respect keyboard tabs, visible focus, reduced motion and mobile layouts. Render source guides with `Tools/build_website_guides.py` when updating the Markdown guides.
