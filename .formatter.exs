# Used by "mix format"
[
  # NOTE: test/fixtures deliberately excluded — fixture files must stay
  # byte-identical to their copied originals (golden tests are exact)
  inputs: [
    "{mix,.formatter}.exs",
    "{config,lib}/**/*.{ex,exs}",
    "test/*.exs",
    "test/surface_eject/**/*.exs",
    "test/support/**/*.ex"
  ]
]
