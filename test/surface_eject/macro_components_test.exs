defmodule SurfaceEject.MacroComponentsTest do
  use ExUnit.Case, async: true

  alias SurfaceEject.{Context, Profiles, Template}

  @moduledoc """
  MacroComponents (`<#Tag>`) are Surface-only syntax — invalid HEEx. Mapped ones (profile `macro_components`) convert to a plain component with attr-rule rewrites (values are always literals: MacroComponent props are `static: true`); unmapped ones are flagged `:manual_required` instead of passing through as silently-broken output.
  """

  @ctx %Context{profile: Profiles.Bonfire.profile()}

  defp convert(tpl), do: Template.convert(tpl, @ctx)

  test "#Icon iconify= → Iconify.iconify icon=" do
    {out, _} = convert(~S(<#Icon iconify="ph:check" class="w-4 h-4" />))
    assert out == ~S(<Iconify.iconify icon="ph:check" class="w-4 h-4" />)
  end

  test "#Icon solid=/outline= shorthands expand to heroicons names" do
    {out, _} = convert(~S(<#Icon solid="user" class="w-6" />))
    assert out == ~S(<Iconify.iconify icon="heroicons:user-solid" class="w-6" />)

    {out, _} = convert(~S(<#Icon outline="user" />))
    assert out == ~S(<Iconify.iconify icon="heroicons:user" />)
  end

  test "dynamic class expr passes through untouched" do
    {out, _} = convert(~S(<#Icon iconify="ph:x" class={@class} />))
    assert out == ~S(<Iconify.iconify icon="ph:x" class={@class} />)
  end

  test "mapped macro with a close tag renames both sides" do
    {out, _} = convert(~S(<#Icon iconify="ph:x"></#Icon>))
    assert out == ~S(<Iconify.iconify icon="ph:x"></Iconify.iconify>)
  end

  test "unmapped macro components are flagged, not silently emitted" do
    tpl = ~S(<#Markdown>*hi*</#Markdown>)
    {out, logs} = convert(tpl)

    assert out == tpl

    assert Enum.any?(
             logs,
             &(&1.category == :macro_component and &1.severity == :manual_required)
           )
  end
end