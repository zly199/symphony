defmodule SymphonyElixir.Codex.DynamicTool do
  @moduledoc """
  Dispatches client-side tool calls to Symphony and the configured tracker adapter.
  """

  alias SymphonyElixir.{DispatchGate, Tracker}

  @review_handoff_tool "symphony_handoff_for_review"
  @review_handoff_spec %{
    "name" => @review_handoff_tool,
    "description" => "Hand completed implementation to the operator for review. Call only after CI is terminal-successful and every required local review and quality gate has passed.",
    "inputSchema" => %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["summary"],
      "properties" => %{
        "summary" => %{
          "type" => "string",
          "description" => "Concise evidence that CI and required review gates passed."
        }
      }
    }
  }

  @spec execute(String.t() | nil, term(), map(), keyword()) :: map()
  def execute(@review_handoff_tool, arguments, _binding, opts) do
    execute_review_handoff(arguments, Keyword.get(opts, :issue))
  end

  def execute(tool, arguments, binding, opts) do
    Tracker.execute_bound_agent_tool(binding, tool, arguments, opts)
  end

  @spec bind() :: map()
  def bind do
    Tracker.bind_agent_tools()
    |> Map.update!(:tool_specs, &(&1 ++ [@review_handoff_spec]))
  end

  defp execute_review_handoff(%{"summary" => summary}, %{id: issue_id} = issue)
       when is_binary(summary) and is_binary(issue_id) do
    if String.trim(summary) == "" do
      failure_response("summary must be a non-empty string")
    else
      case DispatchGate.handoff_for_review(issue_id,
             identifier: Map.get(issue, :identifier),
             updated_by: "agent-review-handoff"
           ) do
        {:ok, _record} ->
          success_response(%{
            "issueId" => issue_id,
            "status" => "review",
            "summary" => String.trim(summary)
          })

        {:error, reason} ->
          failure_response("failed to persist review handoff", reason)
      end
    end
  end

  defp execute_review_handoff(_arguments, _issue) do
    failure_response("symphony_handoff_for_review expects an issue and a non-empty summary")
  end

  defp success_response(payload), do: dynamic_tool_response(true, payload)

  defp failure_response(message, reason \\ nil),
    do:
      dynamic_tool_response(false, %{
        "error" => %{"message" => message, "reason" => inspect(reason)}
      })

  defp dynamic_tool_response(success, payload) do
    output = Jason.encode!(payload)

    %{
      "success" => success,
      "output" => output,
      "contentItems" => [%{"type" => "inputText", "text" => output}]
    }
  end
end
