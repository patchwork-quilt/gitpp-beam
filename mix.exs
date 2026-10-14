defmodule GitppBeam.MixProject do
  use Mix.Project

  def project do
    [
      app: :gitpp_beam,
      version: "0.1.0",
      elixir: "~> 1.17",
      start_permanent: false,
      deps: []
    ]
  end

  def application do
    [extra_applications: [:crypto]]
  end
end
