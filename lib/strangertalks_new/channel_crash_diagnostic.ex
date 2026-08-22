defmodule StrangertalksNew.ChannelCrashDiagnostic do
  @moduledoc """
  Content-blind translation for unhandled Phoenix Channel process crashes.

  Phoenix Channel processes carry Conversation topics, socket identities, assigns,
  and the last inbound payload in the default OTP GenServer termination report.
  This translator keeps the failure class and source locations while preventing
  that product state from reaching Logger handlers.
  """

  @behaviour Logger.Translator

  @impl true
  def translate(
        _minimum_level,
        _level,
        :report,
        {:logger,
         %{
           label: {:gen_server, :terminate},
           process_label: {Phoenix.Channel, _channel, _topic},
           reason: reason
         }}
      ) do
    {kind, failure_class, stacktrace} = safe_failure(reason)

    {:ok,
     [
       "Phoenix Channel process crashed",
       "\nFailure kind: ",
       kind,
       "\nFailure class: ",
       failure_class,
       safe_stacktrace(stacktrace)
     ]}
  end

  def translate(_minimum_level, _level, _kind, _message), do: :none

  defp safe_failure({kind, reason, stacktrace})
       when kind in [:error, :exit, :throw] and is_list(stacktrace) do
    {Atom.to_string(kind), safe_failure_class(reason), stacktrace}
  end

  defp safe_failure({reason, stacktrace}) when is_list(stacktrace) do
    {"error", safe_failure_class(reason), stacktrace}
  end

  defp safe_failure(reason), do: {"exit", safe_failure_class(reason), []}

  defp safe_failure_class(%{__struct__: module}) when is_atom(module), do: inspect(module)
  defp safe_failure_class(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp safe_failure_class(_reason), do: "unhandled_failure"

  defp safe_stacktrace([]), do: "\nStack/location: unavailable"

  defp safe_stacktrace(stacktrace) do
    frames =
      stacktrace
      |> Enum.take(8)
      |> Enum.map(&safe_stack_frame/1)

    ["\nStack/location:", frames]
  end

  defp safe_stack_frame({module, function, args_or_arity, location})
       when is_atom(module) and is_atom(function) and is_list(location) do
    arity = if is_list(args_or_arity), do: length(args_or_arity), else: args_or_arity
    file = location |> Keyword.get(:file) |> safe_file()
    line = location |> Keyword.get(:line) |> safe_line()

    [
      "\n    ",
      inspect(module),
      ".",
      Atom.to_string(function),
      "/",
      to_string(arity),
      " (",
      file,
      line,
      ")"
    ]
  end

  defp safe_stack_frame(_frame), do: "\n    unknown source location"

  defp safe_file(nil), do: "unknown"
  defp safe_file(file), do: file |> to_string() |> Path.basename()

  defp safe_line(nil), do: ""
  defp safe_line(line) when is_integer(line), do: ":#{line}"
  defp safe_line(_line), do: ""
end
