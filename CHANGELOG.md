# Changelog

## Unreleased

- Replace telemetry handlers and `setup/0,1` with worker middleware and application configuration.
- Trace enqueue operations and propagate context through job metadata.
- Store and extract propagation headers exclusively under `trace_propagation_headers`.
- Attach context inside worker Tasks so worker-created spans are children of the job span.
- Configure job span relationships with `:link` (default), `:child`, or `:none`.
- Remove unused `telemetry`, `opentelemetry_telemetry`, and test-only `opentelemetry_exporter` dependencies.
- Use `opentelemetry_semantic_conventions` constants for standard messaging and error attribute keys.
- Add worker code attributes, queue latency in milliseconds, and serialized argument size without recording argument contents.

## 0.2.0 - 2026-10-04

- Relax the `opentelemetry_telemetry` dependency from `~> 1.0.0` to `~> 1.0`, allowing all 1.x releases.

## 0.1.0 - 2026-10-01

- Initial release of OpenTelemetry tracing for Exq jobs, using messaging semantic conventions 1.44.0.
- Record job exceptions and mark failed jobs with error status and `error.type`.
