defmodule SymphonyElixir.Codex.DynamicTool do
  @moduledoc """
  Dispatches client-side tool calls to Symphony and the configured tracker adapter.
  """

  alias SymphonyElixir.{AgentRunner, Artifact, DispatchGate, Tracker}

  @review_handoff_tool "symphony_handoff_for_review"
  @publish_artifact_tool "symphony_publish_artifact"

  @publish_artifact_spec %{
    "name" => @publish_artifact_tool,
    "description" =>
      "Publish this phase's deliverable to the Symphony dashboard, where the operator reads it before deciding whether to let the ticket move on. Every gate shows the artifact next to its approve button, so a phase that ends without one asks a human to approve something they cannot see. Publishing again replaces the previous version.",
    "inputSchema" => %{
      "type" => "object",
      "additionalProperties" => false,
      "required" => ["title", "body"],
      "properties" => %{
        "title" => %{
          "type" => "string",
          "description" => "Short headline for the artifact, shown in the dashboard link."
        },
        "format" => %{
          "type" => "string",
          "enum" => ["markdown", "html", "text"],
          "description" => "How to render the body. Defaults to markdown."
        },
        "body" => %{
          "type" => "string",
          "description" => "The deliverable itself, in full. Self-contained: the operator reads only this, so include the evidence rather than pointing at files they would have to open."
        }
      }
    }
  }

  @review_handoff_spec %{
    "name" => @review_handoff_tool,
    "description" =>
      "Hand completed work to the operator for review. Call only after CI is terminal-successful, every required local review and quality gate has passed, and this phase's artifact is published with symphony_publish_artifact. This is how a ticket ends: the operator decides what happens next, and merging the merge request is theirs to do by hand — never merge it yourself.",
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
  def execute(@publish_artifact_tool, arguments, _binding, opts) do
    execute_publish_artifact(arguments, Keyword.get(opts, :issue))
  end

  def execute(@review_handoff_tool, arguments, _binding, opts) do
    execute_review_handoff(arguments, Keyword.get(opts, :issue))
  end

  def execute(tool, arguments, binding, opts) do
    Tracker.execute_bound_agent_tool(binding, tool, arguments, opts)
  end

  @spec bind() :: map()
  def bind do
    Tracker.bind_agent_tools()
    |> Map.update!(:tool_specs, &(&1 ++ [@publish_artifact_spec, @review_handoff_spec]))
  end

  # The phase is read from the approval record rather than taken as an argument:
  # it is the same source that decided what this run was asked to do, so an
  # artifact cannot be filed against a phase the agent is not actually in.
  defp execute_publish_artifact(arguments, %{id: issue_id} = issue)
       when is_map(arguments) and is_binary(issue_id) do
    phase = AgentRunner.phase_for(issue)

    attrs = %{
      identifier: Map.get(issue, :identifier),
      title: Map.get(arguments, "title"),
      format: Map.get(arguments, "format"),
      body: Map.get(arguments, "body"),
      published_by: "agent"
    }

    case Artifact.put(issue_id, phase, attrs) do
      {:ok, artifact} ->
        success_response(%{
          "issueId" => issue_id,
          "phase" => artifact.phase,
          "title" => artifact.title,
          "format" => artifact.format,
          "bytes" => artifact.bytes,
          "publishedAt" => artifact.published_at
        })

      {:error, :empty_body} ->
        failure_response("body must be the full deliverable, not an empty string")

      {:error, :body_too_large} ->
        failure_response("body is too large to publish; trim it to the evidence the operator needs")

      {:error, :unknown_format} ->
        failure_response("format must be one of markdown, html, or text")

      {:error, reason} ->
        failure_response("failed to publish the artifact", reason)
    end
  end

  defp execute_publish_artifact(_arguments, _issue) do
    failure_response("symphony_publish_artifact expects an issue, a title, and a non-empty body")
  end

  defp execute_review_handoff(%{"summary" => summary}, %{id: issue_id} = issue)
       when is_binary(summary) and is_binary(issue_id) do
    phase = AgentRunner.phase_for(issue)

    cond do
      String.trim(summary) == "" ->
        failure_response("summary must be a non-empty string")

      # Handing off without a deliverable is what leaves the operator approving a
      # status line, so the gate refuses to close until there is something to read.
      not Artifact.exists?(issue_id, phase) ->
        failure_response("publish this phase's artifact with symphony_publish_artifact before handing off for review (phase: #{phase})")

      true ->
        record_review_handoff(issue_id, issue, summary, phase)
    end
  end

  defp execute_review_handoff(_arguments, _issue) do
    failure_response("symphony_handoff_for_review expects an issue and a non-empty summary")
  end

  defp record_review_handoff(issue_id, issue, summary, phase) do
    case DispatchGate.handoff_for_review(issue_id,
           identifier: Map.get(issue, :identifier),
           updated_by: "agent-review-handoff"
         ) do
      {:ok, _record} ->
        success_response(%{
          "issueId" => issue_id,
          "status" => "review",
          "phase" => to_string(phase),
          "summary" => String.trim(summary)
        })

      {:error, reason} ->
        failure_response("failed to persist review handoff", reason)
    end
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
