defmodule SurfaceEject.FieldClustersTest do
  use ExUnit.Case, async: true

  alias SurfaceEject.{Context, Profiles, Template}

  @moduledoc """
  Structure-preserving Field conversion. Surface's `<Field>` renders a `<div class=...>` and passes its `name` to child controls via context, so the faithful transform keeps the markup: `Field` → `<div>`, child controls convert with an explicit `field={form[:name]}` binding, and the enclosing `<.form>` gains `:let={form}` (or reuses its existing `:let` var). Fields with no in-template enclosing `<Form>` (component boundaries) stay flagged.
  """

  @ctx %Context{profile: Profiles.Bonfire.profile()}

  defp convert(tpl), do: Template.convert(tpl, @ctx)

  test "happy path: Field → div, control gains field=, form gains :let" do
    tpl =
      ~S|<Form for={@c} submit="s"><Field class="fc" name={:title}><Label>T</Label><TextInput class="i" /></Field></Form>|

    {out, logs} = convert(tpl)

    assert out ==
             ~S|<.form :let={form} for={@c} phx-submit="s"><div class="fc"><.label>T</.label><.input type="text" field={form[:title]} class="i" /></div></.form>|

    refute Enum.any?(logs, &(&1.severity == :manual_required))
  end

  test "string field name + wrapper markup between control and Field" do
    tpl =
      ~S|<Form for={@c}><Field name="max_uses"><Label class="label">L</Label><div class="w"><Select options={@o} /></div></Field></Form>|

    {out, _} = convert(tpl)

    assert out ==
             ~S|<.form :let={form} for={@c}><div><.label class="label">L</.label><div class="w"><.input type="select" field={form["max_uses"]} options={@o} /></div></div></.form>|
  end

  test "Form with an existing :let reuses its var" do
    tpl = ~S|<Form for={@c} :let={f}><Field name={:x}><TextInput /></Field></Form>|

    {out, _} = convert(tpl)

    assert out == ~S|<.form for={@c} :let={f}><div><.input type="text" field={f[:x]} /></div></.form>|
  end

  test "Field without an enclosing Form stays flagged (component boundary)" do
    tpl = ~S|<Field name={:x}><Label>N</Label><TextInput /></Field>|
    {out, logs} = convert(tpl)

    assert out == tpl
    assert Enum.count(logs, &(&1.category == :surface_builtin)) == 3
  end

  test "ErrorTag inside a convertible Field is dropped (.input renders errors)" do
    tpl = ~S|<Form for={@c}><Field name={:x}><TextInput /><ErrorTag class="e" /></Field></Form>|
    {out, logs} = convert(tpl)

    assert out ==
             ~S|<.form :let={form} for={@c}><div><.input type="text" field={form[:x]} /></div></.form>|

    assert Enum.any?(logs, &(&1.category == :error_tag_dropped))
  end

  test "custom components inside a Field are left to their own conversion" do
    tpl = ~S|<Form for={@c}><Field name={:x}><WriteEditor field_name="a" /></Field></Form>|
    {out, _} = convert(tpl)

    assert out ==
             ~S|<.form :let={form} for={@c}><div><WriteEditor field_name="a" /></div></.form>|
  end

  test "Inputs → <.inputs_for>, nested Fields bind the nested form (Tier 3)" do
    tpl =
      ~S|<Form for={@c}><Inputs for={:post_content}><Field name={:html_body}><TextArea /></Field></Inputs></Form>|

    {out, logs} = convert(tpl)

    assert out ==
             ~S|<.form :let={form} for={@c}><.inputs_for :let={nested_form} field={form[:post_content]}><div><.input type="textarea" field={nested_form[:html_body]} /></div></.inputs_for></.form>|

    refute Enum.any?(logs, &(&1.severity == :manual_required))
  end

  test "sibling Inputs each convert (nested_form scopes per block)" do
    tpl =
      ~S|<Form for={@c}><Inputs for={:profile}><Field name={:name}><TextInput /></Field></Inputs><Inputs for={:character}><Field name={:username}><TextInput /></Field></Inputs></Form>|

    {out, _} = convert(tpl)

    assert out ==
             ~S|<.form :let={form} for={@c}><.inputs_for :let={nested_form} field={form[:profile]}><div><.input type="text" field={nested_form[:name]} /></div></.inputs_for><.inputs_for :let={nested_form} field={form[:character]}><div><.input type="text" field={nested_form[:username]} /></div></.inputs_for></.form>|
  end

  test "Inputs without an enclosing Form stays flagged (children opaque)" do
    tpl = ~S|<Inputs for={:profile}><Field name={:name}><TextInput /></Field></Inputs>|
    {out, logs} = convert(tpl)

    assert out == tpl
    assert Enum.count(logs, &(&1.category == :surface_builtin)) == 3
  end

  test "Field without a name attr stays flagged" do
    tpl = ~S|<Form for={@c}><Field class="x"><TextInput /></Field></Form>|
    {out, logs} = convert(tpl)

    assert out =~ "<Field class=\"x\">"
    assert out =~ "<TextInput />"
    assert Enum.any?(logs, &(&1.category == :surface_builtin))
  end
end