# OpenCode plugins (future)

This repo reserves space for OpenCode plugins under [`.opencode/plugins/`](../.opencode/plugins/).

## How plugins load

Per [OpenCode plugins documentation](https://opencode.ai/docs/plugins/):

1. **Local files** — Place `.js` or `.ts` files in:
   - **Project:** `.opencode/plugins/` (this repo)
   - **Global:** `~/.config/opencode/plugins/`

2. **npm packages** — Add package names to the `plugin` array in `opencode.json` / `opencode.jsonc`:

   ```json
   {
     "plugin": ["@my-org/custom-plugin"]
   }
   ```

   OpenCode installs npm plugins with **Bun** at startup and caches them under `~/.cache/opencode/node_modules/`.

3. **Dependencies for local plugins** — Add a `package.json` next to your config (see upstream docs) so `bun install` can resolve imports.

## Load order

1. Global config (`~/.config/opencode/opencode.json`)
2. Project config (`opencode.json`)
3. Global plugin dir (`~/.config/opencode/plugins/`)
4. Project plugin dir (`.opencode/plugins/`)

## Suggested layout for this repo

| Path | Purpose |
|------|---------|
| `.opencode/plugins/` | Drop local plugin modules here |
| `config/opencode.jsonc` | Add `"plugin": [...]` when you adopt npm plugins |

## Types and examples

- Import types: `import type { Plugin } from "@opencode-ai/plugin"`
- See [plugins docs](https://opencode.ai/docs/plugins/) for hooks (`tool.execute.before`, `session.*`, etc.)

When you add your first plugin, ensure Bun is available if you use npm-listed plugins, or keep plugins as plain local TS/JS files.
