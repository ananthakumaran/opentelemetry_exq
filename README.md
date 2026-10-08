# OpentelemetryExq

[![Hex](https://img.shields.io/hexpm/v/opentelemetry_exq.svg)](https://hex.pm/packages/opentelemetry_exq)
[![HexDocs](https://img.shields.io/badge/HexDocs-documentation-blue.svg)](https://hexdocs.pm/opentelemetry_exq)

OpenTelemetry tracing for Exq jobs. Creates spans for enqueue calls and job execution, propagating trace context from enqueueing to workers.

## Setup

Add the dependencies to `mix.exs` and run `mix deps.get`:

```elixir
defp deps do
  [
    {:opentelemetry_exq, "~> 0.3.0"},
    {:opentelemetry, "~> 1.0"},
    {:opentelemetry_exporter, "~> 1.0"}
  ]
end
```

Keep your existing worker middleware and add `OpentelemetryExq.Middleware` after `Exq.Middleware.Job`. Configure `OpentelemetryExq.EnqueueMiddleware` in the caller-side enqueue chain:

```elixir
import Config

config :exq,
  middleware: [
    Exq.Middleware.Stats,
    Exq.Middleware.Job,
    Exq.Middleware.Manager,
    Exq.Middleware.Unique,
    Exq.Middleware.Logger,
    OpentelemetryExq.Middleware
  ],
  enqueue_middleware: [OpentelemetryExq.EnqueueMiddleware]
```

## Span relationships

Choose how the job span relates to the propagated enqueue span with the `:span_relationship` application setting:

- `:link` (default): start a new trace and link to the enqueue span.
- `:child`: make the job span a child of the enqueue span in the same trace.
- `:none`: start a new trace without linking to the enqueue span.

For example, in `config/config.exs`:

```elixir
config :opentelemetry_exq, span_relationship: :child
```

## Development

```sh
docker compose up -d
mix deps.get
mix test --cover
```
