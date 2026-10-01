{:ok, _} = Application.ensure_all_started(:opentelemetry)
{:ok, _} = Application.ensure_all_started(:opentelemetry_telemetry)

ExUnit.start()
