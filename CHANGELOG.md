# Changelog

## 0.2.0 - 2026-10-04

- Relax the `opentelemetry_telemetry` dependency from `~> 1.0.0` to `~> 1.0`, allowing all 1.x releases.

## 0.1.0 - 2026-10-01

- Initial release of OpenTelemetry tracing for Exq jobs, using messaging semantic conventions 1.44.0.
- Record job exceptions and mark failed jobs with error status and `error.type`.
