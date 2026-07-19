defmodule SurfaceEject.Ex.Sigils do
  @moduledoc """
  Locates `~F` sigils in Elixir source (the same regex family Surface's own
  `mix surface.convert` uses), converts each template body through
  `SurfaceEject.Template.convert/2`, and renames the sigil to `~H`.

  Accepted limitation (same as upstream): a `~F` inside a string literal
  would match — with dry-run diffs this is auditable; real occurrences are
  rare and flagged by review.
  """

  alias SurfaceEject.{Context, Template}

  @doc "Returns `{converted_source, logs}`."
  def convert(source, %Context{} = ctx) do
    {source, logs} =
      Enum.reduce(sigil_rules(), {source, []}, fn {regex, rebuild}, {src, logs} ->
        convert_matches(src, regex, rebuild, ctx, logs)
      end)

    {source, Enum.reverse(logs)}
  end

  defp sigil_rules do
    [
      {~r/~F"""(.*?)"""/s, fn code -> {~s(~H"""), code, ~s(""")} end},
      {~r/~F"([^"].*?)"/s, fn code -> {~s(~H"), code, ~s(")} end},
      {~r/~F\[(.*?)\]/s, fn code -> {"~H[", code, "]"} end},
      {~r/~F\((.*?)\)/s, fn code -> {"~H(", code, ")"} end},
      {~r/~F\{(.*?)\}/s, fn code -> {"~H{", code, "}"} end}
    ]
  end

  defp convert_matches(source, regex, rebuild, ctx, logs) do
    # collect logs via the process dictionary of this reduction — Regex.replace
    # callbacks can't thread an accumulator, so gather then merge
    holder = make_ref()
    Process.put(holder, logs)

    out =
      Regex.replace(regex, source, fn _match, code ->
        {converted, new_logs} = Template.convert(code, ctx)
        Process.put(holder, Enum.reverse(new_logs) ++ Process.get(holder))
        {open, _code, close} = rebuild.(code)
        open <> converted <> close
      end)

    {out, Process.delete(holder)}
  end
end
