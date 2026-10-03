defmodule OpentelemetryExq.MiddlewareTest do
  use ExUnit.Case, async: false

  require Record
  require OpenTelemetry.Tracer, as: Tracer

  @moduletag capture_log: true

  Record.defrecordp(:span, Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl"))

  Record.defrecordp(
    :event,
    Record.extract(:event, from_lib: "opentelemetry/include/otel_span.hrl")
  )

  defmodule Worker do
    def perform("success"), do: :ok
    def perform("error"), do: raise("failed")
    def perform("exit"), do: exit({:shutdown, "variable reason"})

    def perform("retry") do
      attempt = Agent.get_and_update(__MODULE__, fn count -> {count, count + 1} end)
      if attempt == 0, do: raise("retry once"), else: :ok
    end
  end

  defmodule OtherWorker do
    def perform, do: :ok
  end

  defmodule KilledWorker do
    def perform, do: Process.exit(self(), :kill)
  end

  defmodule WaitingWorker do
    def perform do
      send(OpentelemetryExq.MiddlewareTest.Receiver, {:waiting, self()})

      receive do
        :finish -> :ok
      end
    end
  end

  defmodule ImmediateBackoff do
    @behaviour Exq.Backoff.Behaviour

    @impl true
    def offset(_job), do: 0
  end

  setup_all do
    url = Application.fetch_env!(:exq, :url)

    case Redix.start_link(url, sync_connect: true) do
      {:ok, redis} ->
        assert Redix.command(redis, ["PING"]) == {:ok, "PONG"}
        GenServer.stop(redis)

      {:error, reason} ->
        raise "Redis is unavailable: #{inspect(reason)}. Run docker compose up -d --wait."
    end

    :ok
  end

  setup do
    enqueue_middleware = Application.fetch_env!(:exq, :enqueue_middleware)
    Application.put_env(:exq, :enqueue_middleware, [])
    on_exit(fn -> Application.put_env(:exq, :enqueue_middleware, enqueue_middleware) end)

    # OpenTelemetry's built-in test exporter sends completed spans to this process.
    :ok = :otel_simple_processor.set_exporter(:otel_exporter_pid, self())
    namespace = "opentelemetry_exq_test:#{UUID.uuid4()}"
    url = Application.fetch_env!(:exq, :url)

    on_exit(fn ->
      # ExUnit stops the supervised Exq instance before this callback runs.
      {:ok, redis} = Redix.start_link(url, sync_connect: true)
      {:ok, keys} = Redix.command(redis, ["KEYS", "#{namespace}:*"])
      if keys != [], do: Redix.command!(redis, ["DEL" | keys])
      GenServer.stop(redis)
    end)

    start_supervised!(
      {Exq,
       name: __MODULE__,
       namespace: namespace,
       queues: ["default", "mailers"],
       concurrency: 1,
       poll_timeout: 10,
       scheduler_poll_timeout: 10,
       redis_options: [sync_connect: true]}
    )

    :ok
  end

  test "exports current messaging attributes for a real job" do
    jid = enqueue("default", Worker, ["success"])

    assert_receive {:span, exported}, 5_000
    assert span(exported, :name) == "process default"
    assert span(exported, :kind) == :consumer
    assert span(exported, :parent_span_id) == :undefined
    assert :otel_links.list(span(exported, :links)) == []
    assert span(exported, :end_time) >= span(exported, :start_time)
    assert :otel_events.list(span(exported, :events)) == []

    attributes = :otel_attributes.map(span(exported, :attributes))
    {enqueued_at, attributes} = Map.pop(attributes, "messaging.exq.enqueued_at")
    assert {:ok, timestamp, 0} = DateTime.from_iso8601(enqueued_at)
    assert DateTime.to_iso8601(timestamp) == enqueued_at

    assert attributes == %{
             "messaging.system" => "exq",
             "messaging.destination.name" => "default",
             "messaging.operation.name" => "process",
             "messaging.operation.type" => "process",
             "messaging.message.id" => jid,
             "messaging.exq.class" => worker_class(Worker),
             "messaging.exq.retry_count" => 0
           }
  end

  test "uses the queue rather than the job class in span names" do
    jid = enqueue("mailers", OtherWorker, [])

    assert_receive {:span, exported}, 5_000
    assert span(exported, :name) == "process mailers"
    attributes = :otel_attributes.map(span(exported, :attributes))
    assert attributes["messaging.destination.name"] == "mailers"
    assert attributes["messaging.exq.class"] == worker_class(OtherWorker)
    assert attributes["messaging.message.id"] == jid
    refute Map.has_key?(attributes, "error.type")
  end

  test "records exceptions raised by a real worker" do
    jid = enqueue("default", Worker, ["error"])

    assert_receive {:span, exported}, 5_000
    attributes = :otel_attributes.map(span(exported, :attributes))
    assert attributes["messaging.message.id"] == jid
    assert attributes["error.type"] == "Elixir.RuntimeError"
    assert span(exported, :status) == OpenTelemetry.status(:error, "")
    assert [exception] = :otel_events.list(span(exported, :events))
    assert event(exception, :name) == "exception"

    exception_attributes = :otel_attributes.map(event(exception, :attributes))
    assert exception_attributes["exception.type"] == "Elixir.RuntimeError"
    assert exception_attributes["exception.message"] == "failed"
    assert exception_attributes["exception.stacktrace"] =~ "perform/1"
  end

  test "uses a low-cardinality fallback when a real worker exits" do
    jid = enqueue("default", Worker, ["exit"])

    assert_receive {:span, exported}, 5_000
    attributes = :otel_attributes.map(span(exported, :attributes))
    assert attributes["messaging.message.id"] == jid
    assert attributes["error.type"] == "_OTHER"
    assert span(exported, :status) == OpenTelemetry.status(:error, "")
  end

  test "finishes the job span when the worker Task is hard-killed" do
    jid = enqueue("default", KilledWorker, [])

    assert_receive {:span, exported}, 5_000
    attributes = :otel_attributes.map(span(exported, :attributes))
    assert attributes["messaging.message.id"] == jid
    assert attributes["error.type"] == "_OTHER"
    assert span(exported, :status) == OpenTelemetry.status(:error, "")
    assert :otel_events.list(span(exported, :events)) == []
    refute_receive {:span, _}
  end

  test "finishes the job span when a running job is cancelled" do
    Process.register(self(), __MODULE__.Receiver)
    jid = enqueue("default", WaitingWorker, [])

    assert_receive {:waiting, task}, 5_000
    {:links, [worker]} = Process.info(task, :links)
    Exq.Worker.Server.cancel(worker)

    assert_receive {:span, exported}, 5_000
    attributes = :otel_attributes.map(span(exported, :attributes))
    assert attributes["messaging.message.id"] == jid
    assert attributes["error.type"] == "_OTHER"
    assert span(exported, :status) == OpenTelemetry.status(:error, "")
    refute_receive {:span, _}
  end

  test "finishing a job restores the lifecycle process's previous context" do
    Tracer.with_span "existing context" do
      ctx = OpenTelemetry.Ctx.get_current()

      job = %Exq.Support.Job{
        jid: "context",
        queue: "default",
        class: worker_class(OtherWorker),
        enqueued_at: System.system_time(:millisecond) / 1000
      }

      pipeline =
        OpentelemetryExq.Middleware.before_work(%Exq.Middleware.Pipeline{assigns: %{job: job}})

      assert Tracer.current_span_ctx() == pipeline.assigns.otel_span
      assert OpentelemetryExq.Middleware.after_processed_work(pipeline) == pipeline
      assert OpenTelemetry.Ctx.get_current() == ctx
    end

    assert_receive {:span, job}, 5_000
    assert span(job, :name) == "process default"
    assert_receive {:span, parent}, 5_000
    assert span(parent, :name) == "existing context"
  end

  test "exports a separate span when Exq retries a failed job" do
    start_supervised!(%{
      id: Worker,
      start: {Agent, :start_link, [fn -> 0 end, [name: Worker]]}
    })

    jid = enqueue("default", Worker, ["retry"], max_retries: 1)

    assert_receive {:span, failed}, 5_000
    assert_receive {:span, retried}, 5_000
    failed_attributes = :otel_attributes.map(span(failed, :attributes))
    retried_attributes = :otel_attributes.map(span(retried, :attributes))

    assert failed_attributes["messaging.message.id"] == jid
    assert retried_attributes["messaging.message.id"] == jid
    assert failed_attributes["messaging.exq.retry_count"] == 0
    assert retried_attributes["messaging.exq.retry_count"] == 1
    assert span(failed, :status) == OpenTelemetry.status(:error, "")
    refute Map.has_key?(retried_attributes, "error.type")
    assert :otel_events.list(span(retried, :events)) == []
    refute span(failed, :span_id) == span(retried, :span_id)
    assert Agent.get(Worker, & &1) == 2
  end

  defp enqueue(queue, worker, args, options \\ [max_retries: 0]) do
    {:ok, jid} = Exq.enqueue(__MODULE__, queue, worker, args, options)
    jid
  end

  defp worker_class(module) do
    module |> Atom.to_string() |> String.trim_leading("Elixir.")
  end
end
