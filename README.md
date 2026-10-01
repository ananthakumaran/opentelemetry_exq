# OpentelemetryExq

OpenTelemetry tracing for Exq jobs.

## Setup

Add the dependencies to `mix.exs` and run `mix deps.get`:

```elixir
defp deps do
  [
    {:opentelemetry_exq, "~> 0.1.0"},
    {:opentelemetry, "~> 1.0"},
    {:opentelemetry_exporter, "~> 1.0"}
  ]
end
```

In `config/config.exs`, add the telemetry middleware alongside Exq's default
middleware:

```elixir
import Config

config :exq,
  middleware: [
    Exq.Middleware.Stats,
    Exq.Middleware.Job,
    Exq.Middleware.Manager,
    Exq.Middleware.Logger,
    Exq.Middleware.Telemetry
  ]
```

Call `OpentelemetryExq.setup/0` during application startup:

```elixir
defmodule MyApp.Application do
  use Application

  @impl true
  def start(_type, _args) do
    :ok = OpentelemetryExq.setup()

    children = [
      # Your existing application children
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: MyApp.Supervisor)
  end
end
```

Keep your existing Exq Redis/queue settings and OpenTelemetry exporter
configuration. Each processed job will now produce a span.
