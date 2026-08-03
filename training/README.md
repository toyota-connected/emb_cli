# emb training deck

Marp source for the `emb` developer-training slides — a hands-on onboarding deck
covering install, workspace provisioning, build/bundle, cross-compiling, the
reproducible/offline story, and how ivi-homescreen's CI uses `emb`.

| File | Purpose |
|---|---|
| `emb-training.md` | The deck source ([Marp](https://marp.app) Markdown) |
| `emb.css` | The `emb` slide theme (dark, accent-blue) |
| `emb-training.html` | A self-contained HTML render (present in a browser) — **built by CI, not checked in** |

## Render

Requires [Marp CLI](https://github.com/marp-team/marp-cli) — no install needed
with `npx`:

```sh
# PowerPoint — import into Google Slides via File > Import slides
npx @marp-team/marp-cli emb-training.md --theme emb.css --allow-local-files -o emb-training.pptx

# Self-contained HTML (regenerates emb-training.html)
npx @marp-team/marp-cli emb-training.md --theme emb.css --allow-local-files -o emb-training.html
```

Neither render is checked in. The `training` workflow builds the HTML on every
change under `training/` and uploads it as a build artifact, so the source is
the only thing to review and the render always matches the commit it came from.
Download it from the workflow run, or produce either format locally with the
commands above.

The HTML used to be committed, and drifted: the checked-in render went three
weeks and two source changes stale, because regenerating it needs a Node
toolchain a Dart contributor has no other reason to install. Building it in CI
removes that failure mode rather than relying on remembering.
