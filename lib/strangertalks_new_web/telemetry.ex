defmodule StrangertalksNewWeb.Telemetry do
  use Supervisor
  import Telemetry.Metrics

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children = [
      # Telemetry poller will execute the given period measurements
      # every 10_000ms. Learn more here: https://telemetry-metrics.hexdocs.pm
      {:telemetry_poller, measurements: periodic_measurements(), period: 10_000}
      # Add reporters as children of your supervision tree.
      # {Telemetry.Metrics.ConsoleReporter, metrics: metrics()}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  def metrics do
    [
      # Phoenix Metrics
      summary("phoenix.endpoint.start.system_time",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.endpoint.stop.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.start.system_time",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.exception.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.router_dispatch.stop.duration",
        tags: [:route],
        unit: {:native, :millisecond}
      ),
      summary("phoenix.socket_connected.duration",
        unit: {:native, :millisecond}
      ),
      sum("phoenix.socket_drain.count"),
      summary("phoenix.channel_joined.duration",
        unit: {:native, :millisecond}
      ),
      summary("phoenix.channel_handled_in.duration",
        tags: [:event],
        unit: {:native, :millisecond}
      ),

      # Database Metrics
      summary("strangertalks_new.repo.query.total_time",
        unit: {:native, :millisecond},
        description: "The sum of the other measurements"
      ),
      summary("strangertalks_new.repo.query.decode_time",
        unit: {:native, :millisecond},
        description: "The time spent decoding the data received from the database"
      ),
      summary("strangertalks_new.repo.query.query_time",
        unit: {:native, :millisecond},
        description: "The time spent executing the query"
      ),
      summary("strangertalks_new.repo.query.queue_time",
        unit: {:native, :millisecond},
        description: "The time spent waiting for a database connection"
      ),
      summary("strangertalks_new.repo.query.idle_time",
        unit: {:native, :millisecond},
        description:
          "The time the connection spent waiting before being checked out for the query"
      ),

      # Domain lifecycle metrics
      sum("strangertalks_new.queue.joined.count",
        tags: [:door_type]
      ),
      sum("strangertalks_new.queue.left.count",
        tags: [:door_type, :leave_reason]
      ),
      sum("strangertalks_new.match.created.count",
        tags: [:door_type]
      ),
      sum("strangertalks_new.conversation.created.count",
        tags: [:conversation_status, :door_type]
      ),
      sum("strangertalks_new.conversation.transitioned.count",
        tags: [:from_status, :to_status, :lifecycle_event]
      ),
      sum("strangertalks_new.terminal.request_accepted.count",
        tags: [:terminal_status, :lifecycle_event]
      ),
      sum("strangertalks_new.terminal.durable_commit.count",
        tags: [:terminal_status, :lifecycle_event]
      ),
      sum("strangertalks_new.terminal.client_notification.count",
        tags: [:terminal_reason, :notification_path]
      ),
      sum("strangertalks_new.terminal.runtime_cleanup.count",
        tags: [:terminal_reason, :cleanup_path]
      ),
      sum("strangertalks_new.terminal.persistence_failed.count",
        tags: [:terminal_status, :lifecycle_event, :reason_code]
      ),
      sum("strangertalks_new.terminal.authority_disagreement.count",
        tags: [:durable_status, :runtime_status, :detection_path]
      ),
      sum("strangertalks_new.terminal.stale_action_rejected.count",
        tags: [:terminal_action, :canonical_ending]
      ),
      sum("strangertalks_new.terminal.runtime_cleanup_failed.count",
        tags: [:cleanup_path, :reason_code]
      ),
      sum("strangertalks_new.message.accepted.count",
        tags: [:message_type, :delivery_status]
      ),
      sum("strangertalks_new.message.delivered.count",
        tags: [:message_type]
      ),
      sum("strangertalks_new.message.failed.count",
        tags: [:message_type]
      ),
      sum("strangertalks_new.timeline.synchronized.count",
        tags: [:sync_status]
      ),
      sum("strangertalks_new.recovery.orphan_resolved.count",
        tags: [:recovery_kind]
      ),
      sum("strangertalks_new.reply_target.found.count"),
      sum("strangertalks_new.reply_target.evicted.count"),
      sum("strangertalks_new.reply_target.check_failed.count",
        tags: [:reason_code]
      ),
      sum("strangertalks_new.reaction_mutation.applied.count"),
      sum("strangertalks_new.reaction_mutation.idempotent.count"),
      sum("strangertalks_new.reaction_stale.revision.count"),
      sum("strangertalks_new.reaction_target.absent_from_authority.count"),
      sum("strangertalks_new.reaction_mutation.check_failed.count",
        tags: [:reason_code]
      ),

      # Domain failure metrics
      sum("strangertalks_new.queue.join.failed.count",
        tags: [:reason_code]
      ),
      sum("strangertalks_new.conversation.join.failed.count",
        tags: [:reason_code]
      ),
      sum("strangertalks_new.message.accept.failed.count",
        tags: [:reason_code, :message_type]
      ),
      sum("strangertalks_new.message.ack.failed.count",
        tags: [:reason_code, :message_type]
      ),
      sum("strangertalks_new.timeline.sync.failed.count",
        tags: [:reason_code]
      ),
      sum("strangertalks_new.recovery.failed.count",
        tags: [:reason_code, :recovery_kind]
      ),
      sum("strangertalks_new.reconnection.failed.count",
        tags: [:reason_code, :operation]
      ),
      sum("strangertalks_new.invariant.check.failed.count",
        tags: [:reason_code, :operation]
      ),

      # Domain latency metrics. Raw monotonic native durations are converted to milliseconds.
      distribution("strangertalks_new.queue.residence.duration",
        tags: [:door_type, :leave_reason],
        unit: {:native, :millisecond}
      ),
      distribution("strangertalks_new.match.operation.duration",
        tags: [:result, :match_kind],
        unit: {:native, :millisecond}
      ),
      distribution("strangertalks_new.message.accept.duration",
        tags: [:message_type, :result],
        unit: {:native, :millisecond}
      ),
      distribution("strangertalks_new.message.terminal.duration",
        tags: [:message_type, :outcome],
        unit: {:native, :millisecond}
      ),
      distribution("strangertalks_new.timeline.synchronized.duration",
        tags: [:sync_status],
        unit: {:native, :millisecond}
      ),

      # Application runtime health gauges
      last_value("strangertalks_new.runtime.health.process_count"),
      last_value("strangertalks_new.runtime.health.process_limit"),
      last_value("strangertalks_new.conversation_runtime.health.server_count"),
      last_value("strangertalks_new.conversation_runtime.health.total_memory_bytes",
        unit: :byte
      ),
      last_value("strangertalks_new.conversation_runtime.health.max_memory_bytes",
        unit: :byte
      ),
      last_value("strangertalks_new.conversation_runtime.health.average_memory_bytes",
        unit: :byte
      ),
      last_value("strangertalks_new.conversation_runtime.health.total_message_queue_len"),
      last_value("strangertalks_new.conversation_runtime.health.max_message_queue_len"),
      last_value("strangertalks_new.conversation_runtime.health.average_message_queue_len"),
      last_value("strangertalks_new.conversation_runtime.health.servers_with_nonzero_mailbox"),

      # VM Metrics
      summary("vm.memory.total", unit: {:byte, :kilobyte}),
      summary("vm.total_run_queue_lengths.total"),
      summary("vm.total_run_queue_lengths.cpu"),
      summary("vm.total_run_queue_lengths.io")
    ]
  end

  defp periodic_measurements do
    [
      {__MODULE__, :measure_runtime_health, []},
      {__MODULE__, :measure_conversation_runtime_health, []}
    ]
  end

  @doc false
  def measure_runtime_health do
    StrangertalksNew.Telemetry.execute(
      [:runtime, :health],
      %{
        process_count: :erlang.system_info(:process_count),
        process_limit: :erlang.system_info(:process_limit)
      }
    )
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  @doc false
  def measure_conversation_runtime_health do
    samples =
      StrangertalksNew.ConversationDynamicSupervisor
      |> DynamicSupervisor.which_children()
      |> Enum.reduce([], fn
        {_child_id, pid, _type, _modules}, acc when is_pid(pid) ->
          case Process.info(pid, [:memory, :message_queue_len]) do
            info when is_list(info) ->
              memory = Keyword.get(info, :memory)
              mailbox = Keyword.get(info, :message_queue_len)

              if is_integer(memory) and is_integer(mailbox),
                do: [{memory, mailbox} | acc],
                else: acc

            nil ->
              acc
          end
        _child, acc ->
          acc
      end)

    {total_memory, max_memory, total_mailbox, max_mailbox, nonzero_mailboxes} =
      Enum.reduce(samples, {0, 0, 0, 0, 0}, fn {memory, mailbox},
                                               {memory_total, memory_max, mailbox_total,
                                                mailbox_max, nonzero_count} ->
        {
          memory_total + memory,
          max(memory_max, memory),
          mailbox_total + mailbox,
          max(mailbox_max, mailbox),
          nonzero_count + if(mailbox > 0, do: 1, else: 0)
        }
      end)

    server_count = length(samples)

    StrangertalksNew.Telemetry.execute(
      [:conversation_runtime, :health],
      %{
        server_count: server_count,
        total_memory_bytes: total_memory,
        max_memory_bytes: max_memory,
        average_memory_bytes: safe_average(total_memory, server_count),
        total_message_queue_len: total_mailbox,
        max_message_queue_len: max_mailbox,
        average_message_queue_len: safe_average(total_mailbox, server_count),
        servers_with_nonzero_mailbox: nonzero_mailboxes
      }
    )
  rescue
    _error -> :ok
  catch
    _kind, _reason -> :ok
  end

  defp safe_average(_total, 0), do: 0
  defp safe_average(total, count), do: total / count
end
