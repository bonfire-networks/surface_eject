defmodule SurfaceEject.TemplateTransformsTest do
  use ExUnit.Case, async: true

  alias SurfaceEject.{Context, Template}

  defp convert(source, ctx \\ %Context{}) do
    {out, _logs} = Template.convert(source, ctx)
    out
  end

  defp convert_logs(source, ctx \\ %Context{}) do
    {_out, logs} = Template.convert(source, ctx)
    logs
  end

  describe "control-flow blocks" do
    test "if" do
      assert convert("{#if @x}A{/if}") == "<%= if @x do %>A<% end %>"
    end

    test "if/else" do
      assert convert("{#if @x}A{#else}B{/if}") == "<%= if @x do %>A<% else %>B<% end %>"
    end

    test "elseif chain desugars to nested ifs with matching ends" do
      assert convert("{#if @a}A{#elseif @b}B{#elseif @c}C{#else}D{/if}") ==
               "<%= if @a do %>A<% else %><%= if @b do %>B<% else %><%= if @c do %>C<% else %>D<% end %><% end %><% end %>"
    end

    test "unless" do
      assert convert("{#unless @x}A{/unless}") == "<%= if !(@x) do %>A<% end %>"
    end

    test "case/match" do
      assert convert("{#case @s}{#match :a}A{#match _}B{/case}") ==
               "<%= case @s do %><% :a -> %>A<% _ -> %>B<% end %>"
    end

    test "case with private comment before first match" do
      assert convert("{#case @s}{!-- c --}{#match _}A{/case}") ==
               "<%= case @s do %><%!-- c --%><% _ -> %>A<% end %>"
    end

    test "for" do
      assert convert("{#for x <- @xs}I{/for}") == "<%= for x <- @xs do %>I<% end %>"
    end

    test "for with else wraps in Enum.empty? guard" do
      assert convert("{#for x <- @xs}I{#else}E{/for}") ==
               "<%= if !Enum.empty?(@xs) do %><%= for x <- @xs do %>I<% end %><% else %>E<% end %>"
    end

    test "for-else with non-assign subject is flagged for double evaluation" do
      logs = convert_logs("{#for x <- fun(@a)}I{#else}E{/for}")
      assert Enum.any?(logs, &(&1.category == :for_else_double_eval))
    end

    test "nested blocks" do
      assert convert("{#if @a}{#for x <- @xs}I{/for}{#else}B{/if}") ==
               "<%= if @a do %><%= for x <- @xs do %>I<% end %><% else %>B<% end %>"
    end

    test "multi-line block expression preserved verbatim" do
      assert convert("{#if @a ||\n    @b}X{/if}") == "<%= if @a ||\n    @b do %>X<% end %>"
    end
  end

  describe "comments" do
    test "private comments become EEx comments" do
      assert convert("{!-- hi --}") == "<%!-- hi --%>"
    end

    test "HTML comments untouched" do
      assert convert("<!-- <.child /> -->") == "<!-- <.child /> -->"
    end
  end

  describe "directives" do
    test ":on-* becomes phx-*" do
      assert convert(~S(<div :on-click={@ev}>x</div>)) == ~S(<div phx-click={@ev}>x</div>)
      assert convert(~S(<div :on-click="evt">x</div>)) == ~S(<div phx-click="evt">x</div>)

      assert convert(~S(<div :on-window-keydown="k">x</div>)) ==
               ~S(<div phx-window-keydown="k">x</div>)
    end

    test ":hook without a known module renames and flags (can't compute the registered name)" do
      assert convert(~S(<div :hook="Name">x</div>)) == ~S(<div phx-hook="Name">x</div>)

      assert Enum.any?(
               convert_logs(~S(<div :hook="Name">x</div>)),
               &(&1.category == :hook and &1.severity == :manual_required)
             )
    end

    test ":hook with a known module emits Surface's exact registered name (Module#hook)" do
      ctx = %SurfaceEject.Context{
        profile: SurfaceEject.Profiles.Bonfire.profile(),
        module: "My.LazyImage"
      }

      # named hook
      {out, logs} = SurfaceEject.Template.convert(~S(<div :hook="Name">x</div>), ctx)
      assert out == ~S(<div phx-hook="My.LazyImage#Name">x</div>)
      refute Enum.any?(logs, &(&1.severity == :manual_required))
      assert Enum.any?(logs, &(&1.category == :hook and &1.severity == :info))

      # bare :hook = the "default" export
      {out, _} = SurfaceEject.Template.convert(~S(<div :hook>x</div>), ctx)
      assert out == ~S(<div phx-hook="My.LazyImage#default">x</div>)

      # expr form ({name, from: Mod}) stays flagged
      {out, logs} =
        SurfaceEject.Template.convert(~S(<div :hook={"X", from: Other.Mod}>x</div>), ctx)

      assert out =~ "phx-hook"
      assert Enum.any?(logs, &(&1.severity == :manual_required))
      _ = out
    end

    test "root spread {...expr} becomes {expr}" do
      assert convert(~S(<div {...@opts}>x</div>)) == ~S(<div {@opts}>x</div>)
    end

    test ":if/:for/:let attrs pass through (valid HEEx)" do
      src = ~S(<div :if={@x} :for={y <- @ys}>{y}</div>)
      assert convert(src) == src
    end

    test "alpine_bind: :attr on an HTML tag becomes x-bind:attr (Alpine shorthand longhand)" do
      # leading-colon attrs are rejected by HEEx on tags; x-bind: is the
      # identical Alpine longhand
      ctx = %SurfaceEject.Context{profile: SurfaceEject.Profiles.Bonfire.profile()}

      {out, logs} = SurfaceEject.Template.convert(~S(<div :class="open && 'a'">y</div>), ctx)
      assert out == ~S(<div x-bind:class="open && 'a'">y</div>)
      assert Enum.any?(logs, &(&1.category == :alpine_bind))

      {out, _} =
        SurfaceEject.Template.convert(~S(<button :aria-expanded="open">y</button>), ctx)

      assert out == ~S(<button x-bind:aria-expanded="open">y</button>)

      # on a COMPONENT the attr is not a DOM bind — keep remove+flag
      {out, logs} = SurfaceEject.Template.convert(~S(<Card :class="x" />), ctx)
      refute out =~ ~S(<Card :class)
      assert Enum.any?(logs, &(&1.category == :unknown_directive))
    end

    test "unknown directive is removed with a TODO comment and flagged" do
      out = convert(~S(<div :show={@x}>y</div>))
      assert out =~ "TODO"
      # the directive is gone from the tag (the TODO comment may mention it)
      refute out =~ "<div :show"
      assert out =~ "<div>y</div>"

      assert Enum.any?(
               convert_logs(~S(<div :show={@x}>y</div>)),
               &(&1.severity == :manual_required)
             )
    end
  end

  describe "slots" do
    test "self-closing default slot" do
      assert convert("<#slot />") == "{render_slot(@inner_block)}"
    end

    test "self-closing named slot ref" do
      assert convert("<#slot {@header} />") == "{render_slot(@header)}"
    end

    test "named slot with fallback children" do
      assert convert("<#slot {@side}>F</#slot>") ==
               "<%= if @side && @side != [] do %>{render_slot(@side)}<% else %>F<% end %>"
    end

    test "default slot with fallback children" do
      assert convert("<#slot>F</#slot>") ==
               "<%= if @inner_block && @inner_block != [] do %>{render_slot(@inner_block)}<% else %>F<% end %>"
    end
  end

  describe "unicode positions" do
    test "multibyte chars before markers don't shift spans" do
      assert convert("🔥🔥 café {#if @x}A{/if}") == "🔥🔥 café <%= if @x do %>A<% end %>"

      assert convert(~S(<div title="🔥" :on-click={@e}>x</div>)) ==
               ~S(<div title="🔥" phx-click={@e}>x</div>)
    end
  end

  describe "passthrough" do
    test "plain HTML, expressions, Alpine attrs untouched" do
      src = ~S(<div x-data="{show: true}" x-cloak class={@c}>{@x} text</div>)
      assert convert(src) == src
    end

    test "component tags untouched in M1 (unknown to empty type map) and logged" do
      src = ~S(<Some.Module.Tag a={@x} />)
      assert convert(src) == src
      assert Enum.any?(convert_logs(src), &(&1.category == :unknown_component))
    end
  end
end
