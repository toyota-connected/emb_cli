# emb training deck

Marp source for the `emb` developer-training slides — a hands-on onboarding deck
covering install, workspace provisioning, build/bundle, cross-compiling, the
reproducible/offline story, and how ivi-homescreen's CI uses `emb`.

| File | Purpose |
|---|---|
| `emb-training.md` | The deck source ([Marp](https://marp.app) Markdown) |
| `emb.css` | The `emb` slide theme (dark, accent-blue) |
| `emb-training.html` | A self-contained HTML render (present in a browser) |

## Render

Requires [Marp CLI](https://github.com/marp-team/marp-cli) — no install needed
with `npx`:

```sh
# PowerPoint — import into Google Slides via File > Import slides
npx @marp-team/marp-cli emb-training.md --theme emb.css --allow-local-files -o emb-training.pptx

# Self-contained HTML (regenerates emb-training.html)
npx @marp-team/marp-cli emb-training.md --theme emb.css --allow-local-files -o emb-training.html
```

The generated `.pptx` is not checked in — render it locally from the source.
