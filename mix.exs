defmodule SurfaceEject.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/bonfire-networks/surface_eject"

  def project do
    [
      app: :surface_eject,
      version: @version,
      elixir: "~> 1.15",
      elixirc_paths: elixirc_paths(Mix.env()),
      test_ignore_filters: [~r{test/fixtures/}],
      start_permanent: Mix.env() == :prod,
      escript: [main_module: SurfaceEject.CLI],
      deps: deps(),
      description: description(),
      package: package(),
      name: "SurfaceEject",
      source_url: @source_url,
      docs: [main: "readme", extras: ["README.md"]]
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp deps do
    [
      # tokenizer used by the vendored splicer (optional at runtime for
      # projects that already ejected — the mix task requires it)
      {:surface, "~> 0.12", optional: true},
      {:phoenix_live_view, "~> 1.0"},
      {:igniter, "~> 0.8"},
      {:sourceror, "~> 1.12"},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false},
      # render-equivalence harness (DOM normalization)
      {:floki, ">= 0.30.0", only: :test}
    ]
  end

  defp description do
    "mix surface.eject — migrate a codebase from Surface to plain Phoenix LiveView/HEEx. Token-splicing template conversion (byte-for-byte preservation of untouched source), Sourceror-based module surgery, Igniter-powered dry-run diffs, profile-driven policy."
  end

  defp package do
    [
      licenses: ["MPL-2.0"],
      links: %{"GitHub" => @source_url}
    ]
  end
end
