defmodule OpentelemetryExq.MixProject do
  use Mix.Project

  @version "0.2.0"
  @source_url "https://github.com/ananthakumaran/opentelemetry_exq"

  def project do
    [
      app: :opentelemetry_exq,
      version: @version,
      description: "OpenTelemetry tracing for Exq jobs",
      source_url: @source_url,
      package: [
        licenses: ["MIT"],
        links: %{"GitHub" => @source_url},
        files: ~w(lib mix.exs .formatter.exs README.md CHANGELOG.md LICENSE)
      ],
      docs: [
        main: "readme",
        extras: ["README.md", "CHANGELOG.md"],
        source_ref: "v#{@version}"
      ],
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      test_coverage: [summary: [threshold: 100]],
      deps: deps()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      extra_applications: [:logger]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:exq, "~> 0.25.0"},
      {:opentelemetry_api, "~> 1.0"},
      {:opentelemetry_semantic_conventions, "~> 1.27"},
      {:opentelemetry, "~> 1.0", only: [:test]},
      {:jason, "~> 1.0", only: :test},
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false}
    ]
  end
end
