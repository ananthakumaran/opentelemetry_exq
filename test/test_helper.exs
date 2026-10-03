{:ok, _} = Application.ensure_all_started(:opentelemetry)

ExUnit.start()
