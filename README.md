# SurfaceEject

`mix surface.eject` migrates a codebase from [Surface](https://surface-ui.org) to plain Phoenix LiveView/HEEx, with reviewable diffs and byte-for-byte preservation of everything the converter doesn't need to touch.

Surface pioneered much of what became LiveView's component model (`attr`/`slot`/HEEx itself absorbed its ideas), and modern HEEx can express most Surface templates directly, e.g. `:if`/`:for`/`:let` attrs are identical syntax, slot entries carry over, `{expr}` interpolation matches. What remains is mechanical: block syntax (`{#if}` → `<%= if %>`), comments, `<#slot>`, event directives, declarations, and component call sites. SurfaceEject does exactly that, and flags everything it can't do safely instead of guessing.

## How it converts

**Templates** (`.sface` and inline `~F` sigils) are tokenized with **Surface's own tokenizer** and rewritten by position-driven source splicing, untouched source survives byte-for-byte, so diffs stay reviewable even across hundreds of files. Transforms:

- `{#if}/{#elseif}/{#else}/{#unless}` → `<%= if %>` forms (elseif desugars to nested ifs); `{#case}/{#match}` → `<%= case %>` clauses; `{#for}` → `<%= for %>`, with for-else wrapped in an `Enum.empty?` guard (non-assign subjects flagged for double evaluation)
- `{!-- comments --}` → `<%!-- comments --%>`; `{...@spread}` → `{@spread}`; `:on-*` → `phx-*`; `:hook` → `phx-hook` (flagged for hook-registration review)
- `<#slot>` element forms → `{render_slot(...)}`, with fallback children becoming an if/else wrap
- `:if=`/`:for=`/`:let=` pass through unchanged — they're already valid HEEx
- Component call sites (using a project-wide scan of component types and aliases): function components → `<Module.render ...>` (modules keep their `render/1`), live components → `<.live_component module={Module} ...>` (callers passing named slot entries are flagged — `<.live_component>` can't receive them), dynamic-dispatch wrappers get a configurable suffix, Surface built-ins are flagged
- Unknown directives are removed with a TODO comment and a `:manual_required` flag, never silently emitted as invalid HEEx

**Elixir files**: `~F` → `~H` (bodies converted through the template pass), direct `use Surface.Component/LiveComponent/LiveView` → the `Phoenix` counterpart, and (mode-dependent) `prop` → `attr` with type mapping, `slot default` → `slot :inner_block` (`arg:` dropped; those semantics live in the caller's `:let`), `data` flagged. Declaration conversion only happens for declaration groups adjacent to a 1-arity def (dangling `attr` lines don't compile); everything else is flagged, not guessed.

Every decision is logged (`%SurfaceEject.LogEntry{}`: severity, category, file, line) for the conversion report.

## Profiles

The core is project-agnostic; policy lives in `SurfaceEject.Profile`:

- `declarations: :attr | :compat` — convert declarations, or leave them for a compat macro layer
- `web_macros` / `use_atom_map` / `use_like_macros` — resolve and rewrite `use MyWeb, :atom`-style component declarations (so converted modules compile through your post-Surface macro stack while unconverted ones keep the Surface stack, incremental migration with both coexisting)
- `dynamic_dispatch` — call-site suffix rules for your dynamic-render wrappers
- `aliases` — statically-known aliases your web macros provide (e.g. Surface form components)

`Profile.bonfire/0` ships as a worked example (the [Bonfire](https://bonfirenetworks.org) migration this tool was extracted from); pair it with [surf_context](https://github.com/bonfire-networks/surf_context) if your templates use Surface contexts, `@__context__` reads then carry over verbatim with zero call-site plumbing.

## Usage

```elixir
# mix.exs (dev-only)
{:surface_eject, "~> 0.1.0", only: :dev, runtime: false}
```

```sh
mix surface.eject --profile bonfire --path lib --dry-run   # review the diff first, always
mix surface.eject --profile bonfire --path lib             # apply
```

Igniter-powered: all changes compose into one reviewable diff with confirmation; `.sface` files are renamed to `.heex` in the same pass.

## Guarantees & testing

The test suite is layered: per-rule unit tests, **golden fixtures** (byte-exact expected outputs for real-world components), an **HEEx compile smoke** (converted output must compile and render against stub components), a **render-equivalence harness** (the same component compiled as original Surface AND as converted plain LV, rendered with identical assigns, Floki-normalized DOM compared — covering if/else, for/for-else, defaults, and slot semantics), and Igniter virtual-project integration.

One known, flagged divergence (`:default_slot_fallback`, pinned by a test): a **default**-slot `<#slot>fallback</#slot>` only renders its fallback for self-closing callers after conversion — HEEx gives every non-self-closing caller a non-empty `@inner_block`, even for whitespace-only or named-slots-only bodies, where Surface rendered the fallback. Named-slot fallbacks convert exactly.

## Status

Template + `.ex` + call-site conversion and the mix task are implemented and tested. Deferred (flagged, not converted): hooks migration to colocated hooks, scoped-CSS migration, config/mix.exs patching, the conversion report file, aggressive curly-brace transforms. MacroComponents, `<Context>`, and legacy `{{ }}` syntax are flagged if encountered.
