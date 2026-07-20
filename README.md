# SurfaceEject

Migrates a codebase from [Surface](https://surface-ui.org) to plain Phoenix LiveView/HEEx, with reviewable diffs and byte-for-byte preservation of everything the converter doesn't need to touch. Run it as a mix task (`mix surface.eject`, Igniter-powered) or as a standalone escript that needs no dependency on the target project.

Surface pioneered much of what became LiveView's component model (`attr`/`slot`/HEEx itself absorbed its ideas), and modern HEEx can express most Surface templates directly, e.g. `:if`/`:for`/`:let` attrs are identical syntax, slot entries carry over, `{expr}` interpolation matches. What remains is mechanical: block syntax (`{#if}` → `<%= if %>`), comments, `<#slot>`, event directives, declarations, and component call sites. SurfaceEject does exactly that, and flags everything it can't do safely instead of guessing.

## How it converts

**Templates** (`.sface` and inline `~F` sigils) are tokenized with **Surface's own tokenizer** and rewritten by position-driven source splicing, untouched source survives byte-for-byte, so diffs stay reviewable even across hundreds of files. Transforms:

- `{#if}/{#elseif}/{#else}/{#unless}` → `<%= if %>` forms (elseif desugars to nested ifs); `{#case}/{#match}` → `<%= case %>` clauses; `{#for}` → `<%= for %>`, with for-else wrapped in an `Enum.empty?` guard (non-assign subjects flagged for double evaluation)
- `{!-- comments --}` → `<%!-- comments --%>`; `{...@spread}` → `{@spread}`; `:on-*` → `phx-*`; `:hook` → `phx-hook` with Surface's exact registered name (`Module.Name#hook`, bare `:hook` = `#default`) so existing collected hooks keep working
- `<#slot>` element forms → `{render_slot(...)}`, with fallback children becoming an if/else wrap
- `:if=`/`:for=`/`:let=` pass through unchanged — they're already valid HEEx
- Component call sites (using a project-wide scan of component types and aliases): function components → `<Module.render ...>` (modules keep their `render/1`), live components → `<.live_component module={Module} ...>`, dynamic-dispatch wrappers get a configurable suffix. Callers passing named slot entries to a live component (`<.live_component>` can't receive them) rename to a function-component entry point when the profile maps one (`live_component_slot_entrypoints: %{"My.ModalLive" => "open_modal"}`, a one-liner on the module that forwards assigns, slots included, into `<.live_component>`); unmapped ones are flagged
- Unknown directives are removed with a TODO comment and a `:manual_required` flag, never silently emitted as invalid HEEx

- Surface's comma-list class sugar (`class={"card", "rounded": @rounded}`) is invalid HEEx (parses as a *tuple*) which wraps into a runtime helper with identical `:css_class` semantics when the profile sets `css_class_helper` (`class={css_class(["card", "rounded": @rounded])}`; applies to `class` and `*_class` attrs); without a helper, or on non-class attrs, it's flagged `:manual_required`. `SurfaceEject.Runtime.css_class/1` ships as the reference implementation. Vendor it (copy the ~20 lines into a module your templates import, since surface_eject is normally dev-only) or point the profile at it directly if you keep the dep at runtime
- Surface **contexts** need no conversion at all when paired with [surf_context](https://github.com/bonfire-networks/surf_context): it re-threads the `__context__` assign through every component call site at compile time, so `@__context__` reads in converted templates keep working verbatim. Add `use SurfContext` to your web macros and the ejected code never notices Surface's context machinery left
- Alpine's bind shorthand (`:class=`, `:aria-*=` — HEEx rejects leading-colon attrs, Surface passed them through) renames to the identical `x-bind:` longhand on HTML tags when the profile sets `alpine_bind: true`; Alpine's `@event=` shorthand is already valid HEEx and passes through
- **Built-in components** (profile `builtin_components`): `<Form>` → `<.form>` (`submit`/`change` → `phx-submit`/`phx-change`, `opts={...}` → a root spread), input controls → `<.input type="...">` (`selected` → `value`), `<Label>` → `<.label>`, `<Link>` → `<.link>` (`to` → `href`; `method`/`label`/event props carry Surface semantics and flag instead). **`<Field>` converts structure-preservingly**: Surface's `Field` rendered as `<div class=...>` and passed its `name` to children via context, so the converter creates a `<div>` and gives child controls an explicit `field={form[:name]}`, `<ErrorTag>` is dropped (`.input` renders errors), and the enclosing `<.form>` gains `:let={form}` (an existing simple `:let` var is reused). Wrapper markup, `Field` classes, and custom components inside all survive untouched. `<Inputs for={:assoc}>` converts to Phoenix's own `<.inputs_for :let={nested_form} field={form[:assoc]}>` (Surface's `Inputs` was already a wrapper around it), with Fields inside binding the nested form. Fields/Inputs with no in-template enclosing `<Form>` (component boundaries) and `<FieldContext>` stay flagged
- **MacroComponents** (`<#Tag>` — invalid HEEx): mapped ones (profile `macro_components`) convert with static attr rewrites (e.g. uses of iconify_ex's `<#Icon>` → `<Iconify.iconify icon=...>`, `solid="user"` → `icon="heroicons:user-solid"`); unmapped ones are flagged instead of passing through as broken output

**Elixir files**: `~F` → `~H` (bodies converted through the template pass), direct `use Surface.Component/LiveComponent/LiveView` → the `Phoenix` counterpart, and (mode-dependent) `prop` → `attr` with type mapping, `slot default` → `slot :inner_block` (`arg:` dropped; those semantics live in the caller's `:let`), `@doc` lines preceding a declaration folded into its `doc:` option (Surface's macros consumed `@doc`; Phoenix's don't — left alone they'd stack up and wrongly document `render/1`), `data` flagged. Declaration conversion only happens for declaration groups adjacent to a 1-arity def (dangling `attr` lines don't compile); everything else is flagged, not guessed.

Every decision is logged (`%SurfaceEject.LogEntry{}`: severity, category, file, line) for the conversion report.

## Profiles

The core is project-agnostic; policy lives in the `%SurfaceEject.Profile{}` struct:

- `declarations: :attr | :compat` — convert declarations, or leave them for a compat macro layer
- `web_macros` / `use_atom_map` / `use_like_macros` — resolve and rewrite `use MyWeb, :atom`-style component declarations (so converted modules compile through your post-Surface macro stack while unconverted ones keep the Surface stack, incremental migration with both coexisting)
- `dynamic_dispatch` — call-site suffix rules for your dynamic-render wrappers
- `aliases` — statically-known aliases your web macros provide (e.g. Surface form components)

Built-ins live under `SurfaceEject.Profiles.*`, each exposing `profile/0`:

- `SurfaceEject.Profiles.Default` (`--profile default`, the fallback) matches a stock `mix surface.init` project: `:attr` declarations, the `surface_live_view` web-macro atom the installer patches in, and Surface's own component library as known aliases. Tested against the actual files `surface.init --demo` generates.
- `SurfaceEject.Profiles.Bonfire` (`--profile bonfire`) is a worked real-world example (the [Bonfire](https://bonfirenetworks.org) migration this tool was extracted from); pair it with [surf_context](https://github.com/bonfire-networks/surf_context) if your templates use Surface contexts, `@__context__` reads then carry over verbatim with zero call-site plumbing.

To supply your own: with the mix task, pass a module from your project exposing `profile/0` (`--profile MyApp.EjectProfile`); with the escript, pass a path to a `.exs` file whose last expression is a `%SurfaceEject.Profile{}` (`--profile ./eject_profile.exs`).

## Usage

### As a mix task (Igniter)

```elixir
# mix.exs (dev-only)
{:surface_eject, "~> 0.1.0", only: :dev, runtime: false}
```

```sh
mix surface.eject --profile bonfire --path lib --dry-run   # review the diff first, always
mix surface.eject --profile bonfire --path lib             # apply
```

Igniter-powered: all changes compose into one reviewable diff with confirmation; `.sface` files are renamed to `.heex` in the same pass, and a `SURFACE_EJECT_REPORT.md` is added to the diff.

### As an escript (no dependency on the target)

```sh
mix escript.build
./surface_eject --profile bonfire --path ../my_app/lib            # dry run (default): read-only, prints the report
./surface_eject --profile bonfire --path ../my_app/lib --apply    # write + rename; review with git diff + SURFACE_EJECT_REPORT.md
```

The **report** (`SurfaceEject.Reporter`): errors and manual-review items with locations up top, info as counts, changed-file list — the artifact to read alongside `git diff` when applying. The dry run prints it to stdout (still writing nothing); `--report PATH` saves it even on a dry run; `--apply` writes it plus a per-file `.surface_eject_status.json` into the target for tracking incremental migration.

Both frontends are thin shells over the same `SurfaceEject.Runner.plan/2` pipeline, which is pure source-text transformation (the project scan parses sources, it never loads the target's modules), so the escript doesn't compile or even load the target project, and a dry run writes nothing. One malformed file does not kill a run: it's flagged as an error, left unchanged, and the rest of the plan proceeds.

### File selection (both frontends)

Everything matching `<path>/**/*.{ex,sface}` is planned; `.heex` output is never re-picked-up, and re-running on converted files is a byte-exact no-op. `deps`, `_build`, and `node_modules` segments are always excluded; `--exclude <segment>` (repeatable) adds more. `--scan-path <root>` (repeatable) adds trees that are *scanned* for component types/aliases but not converted, so you can convert a single app of an umbrella or poncho project while still resolving components defined in the others (`--path extensions/foo --scan-path extensions`).

### Colocated hooks (`hooks-index` subcommand)

Surface's compiler collected colocated `*.hooks.js` files into a namespaced `hooks/index.js` — from Surface modules only, so converted modules silently drop out. `./surface_eject hooks-index --path extensions --out assets/hooks` regenerates the same artifact (byte-compatible format, module-named copies) from a plain file glob, keeping hooks working for converted and unconverted modules throughout the migration. Run it after any Surface compile. Migrating to LiveView's colocated `<script :type={ColocatedHook}>` can then happen per component, later, optionally.

### Which frontend?

The mix task gives you Igniter's interactive per-file diff and confirmation before anything is written, and composes with other Igniter tasks, at the price of adding the dep and compiling the host project just to boot. The escript needs no dep, never compiles the target, and its dry run cannot write, but has no interactive diff: review is `--apply` on a clean tree + `git diff`. Rule of thumb: single standard Phoenix app with the dep added temporarily → mix task; multi-repo/poncho trees or when you don't want the dep in your lockfile → escript.

## Guarantees & testing

The test suite is layered: per-rule unit tests, **golden fixtures** (byte-exact expected outputs for real-world components, plus the files `mix surface.init --demo` generates), an **HEEx compile smoke** (converted output must compile and render against stub components), a **render-equivalence harness** (the same component compiled as original Surface AND as converted plain LV, rendered with identical assigns, Floki-normalized DOM compared — covering if/else, for/for-else, defaults, and slot semantics), a **Surface-interop harness** (an *unconverted* `~F` caller rendering a *converted* component through the dotted tag, attrs/defaults/default-slot/named-slot entries all crossing, so incremental migration order is unconstrained), **idempotency** (re-running on converted output is a byte-exact no-op), **crash isolation**, **dry-run write-nothing**, and Igniter virtual-project integration.

One known, flagged divergence (`:default_slot_fallback`, pinned by a test): a **default**-slot `<#slot>fallback</#slot>` only renders its fallback for self-closing callers after conversion — HEEx gives every non-self-closing caller a non-empty `@inner_block`, even for whitespace-only or named-slots-only bodies, where Surface rendered the fallback. Named-slot fallbacks convert exactly.

## Status

Template + `.ex` + call-site conversion, the mix task, and the escript CLI are implemented and tested. Deferred (flagged, not converted): hooks migration to colocated hooks, scoped-CSS migration (inline `<style>` passes through but loses Surface's scoping), config/mix.exs patching, the conversion report file, auto-rewriting comma-list attrs. MacroComponents, `<Context>`, and legacy `{{ }}` syntax are flagged if encountered.
