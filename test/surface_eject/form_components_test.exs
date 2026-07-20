defmodule SurfaceEject.FormComponentsTest do
  use ExUnit.Case, async: true

  alias SurfaceEject.{Context, Profiles, Template}

  @moduledoc """
  Form-component conversion: tag-level rewrites onto the phx.new-style core components (`<.form>`, `<.input type=...>`, `<.label>`). The `<Field>` cluster collapse is Tier 2, until then, anything INSIDE a `<Field>` must stay flagged, not converted (a converted control would silently lose the field name Surface's context provided).
  """

  @ctx %Context{profile: Profiles.Bonfire.profile()}

  defp convert(tpl), do: Template.convert(tpl, @ctx)

  test "Form → .form with event-attr renames" do
    {out, _} = convert(~S(<Form for={@changeset} submit="save" change="validate">x</Form>))
    assert out == ~S(<.form for={@changeset} phx-submit="save" phx-change="validate">x</.form>)
  end

  test "Form opts: single expr becomes a root spread, keyword list gets brackets" do
    {out, _} = convert(~S(<Form for={@c} opts={@extra}>x</Form>))
    assert out == ~S(<.form for={@c} {@extra}>x</.form>)

    {out, _} = convert(~S(<Form for={@c} opts={autocomplete: "off", id: "x"}>x</Form>))
    assert out == ~S(<.form for={@c} {[autocomplete: "off", id: "x"]}>x</.form>)
  end

  test "standalone input controls → <.input type=...>" do
    {out, _} = convert(~S(<HiddenInput name="a" value={@v} />))
    assert out == ~S(<.input type="hidden" name="a" value={@v} />)

    {out, _} = convert(~S(<TextInput class="x" opts={placeholder: "p"} />))
    assert out == ~S(<.input type="text" class="x" {[placeholder: "p"]} />)

    {out, _} = convert(~S(<TextArea name="bio" />))
    assert out == ~S(<.input type="textarea" name="bio" />)
  end

  test "Select: selected → value; options pass through" do
    {out, _} = convert(~S(<Select options={@opts} selected={@sel} />))
    assert out == ~S(<.input type="select" options={@opts} value={@sel} />)
  end

  test "Select with children (OptionsForSelect) stays flagged" do
    tpl = ~S(<Select><OptionsForSelect options={@o} /></Select>)
    {out, logs} = convert(tpl)

    assert out == tpl
    assert Enum.any?(logs, &(&1.category == :surface_builtin))
  end

  test "standalone Label → <.label>" do
    {out, _} = convert(~S(<Label class="y">Name</Label>))
    assert out == ~S(<.label class="y">Name</.label>)
  end

  test "controls inside a Field cluster are NOT converted (Tier 2), only flagged" do
    tpl = ~S(<Field name={:foo}><Label>N</Label><TextInput /></Field>)
    {out, logs} = convert(tpl)

    assert out == tpl
    # Field itself + Label + TextInput all flagged
    assert Enum.count(logs, &(&1.category == :surface_builtin)) == 3
  end

  test "converted opts spread is not comma-list-flagged" do
    {_, logs} = convert(~S(<TextInput opts={placeholder: "p", autocomplete: "off"} />))
    refute Enum.any?(logs, &(&1.category == :attr_comma_list))
  end

  test "unmapped form builtins (ErrorTag, Inputs) still flag" do
    {out, logs} = convert(~S(<ErrorTag field={:name} />))
    assert out == ~S(<ErrorTag field={:name} />)
    assert Enum.any?(logs, &(&1.category == :surface_builtin))
  end

  describe "Link → <.link>" do
    test "to→href, opts spread, children pass (the corpus shape)" do
      {out, logs} =
        convert(
          ~S'<Link to={@url} class="btn" opts={@opts |> Keyword.merge(target: "_blank")}>x</Link>'
        )

      assert out ==
               ~S'<.link href={@url} class="btn" {@opts |> Keyword.merge(target: "_blank")}>x</.link>'

      refute Enum.any?(logs, &(&1.severity == :manual_required))
    end

    test "method/label/event props change semantics — flagged, not converted" do
      for src <- [
            ~S(<Link to="/x" method={:delete}>x</Link>),
            ~S(<Link to="/x" click="ev">x</Link>),
            ~S(<Link to="/x" label="x" />)
          ] do
        {out, logs} = convert(src)
        assert out == src
        assert Enum.any?(logs, &(&1.category == :surface_builtin))
      end
    end
  end

  describe "comma-list class attrs (css_class_helper)" do
    test "class= comma-list wraps in the helper with Surface semantics" do
      {out, logs} = convert(~S|<div class={"card", "max-w-#{@w}", "rounded-2xl": @r}>x</div>|)

      assert out == ~S|<div class={css_class(["card", "max-w-#{@w}", "rounded-2xl": @r])}>x</div>|
      refute Enum.any?(logs, &(&1.category == :attr_comma_list))
      assert Enum.any?(logs, &(&1.category == :css_class_wrapped))
    end

    test "*_class props wrap too (works on components — helper returns a string)" do
      {out, _} = convert(~S|<Card label_class={"a", "b-x": @c} />|)
      assert out =~ ~S|label_class={css_class(["a", "b-x": @c])}|
    end

    test "non-class comma attrs still flag" do
      {_, logs} = convert(~S|<div data-x={1, 2}>x</div>|)
      assert Enum.any?(logs, &(&1.category == :attr_comma_list))
    end

    test "without a configured helper the flag remains" do
      ctx = %Context{profile: %SurfaceEject.Profile{}}
      {out, logs} = Template.convert(~S|<div class={"a", "b-x": @c}>x</div>|, ctx)

      assert out == ~S|<div class={"a", "b-x": @c}>x</div>|
      assert Enum.any?(logs, &(&1.category == :attr_comma_list))
    end
  end
end