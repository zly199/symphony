defmodule SymphonyElixir.PromptBuilder do
  @moduledoc """
  Builds agent prompts from normalized tracker work item data.
  """

  alias SymphonyElixir.{Config, ResumeState, Workflow}

  @render_opts [strict_variables: true, strict_filters: true]

  @spec build_prompt(SymphonyElixir.Tracker.Issue.t(), keyword()) :: String.t()
  def build_prompt(issue, opts \\ []) do
    template =
      Workflow.current()
      |> prompt_template!()
      |> parse_template!()

    template
    |> Solid.render!(
      %{
        "attempt" => Keyword.get(opts, :attempt),
        "phase" => opts |> Keyword.get(:phase, :analysis) |> to_string(),
        "resume" => opts |> Keyword.get(:resume, ResumeState.empty()) |> to_solid_map(),
        "feedback" => opts |> Keyword.get(:feedback, []) |> to_feedback(),
        "issue" => issue |> Map.from_struct() |> to_solid_map()
      },
      @render_opts
    )
    |> IO.iodata_to_binary()
  end

  defp prompt_template!({:ok, %{prompt_template: prompt}}), do: default_prompt(prompt)

  defp prompt_template!({:error, reason}) do
    raise RuntimeError, "workflow_unavailable: #{inspect(reason)}"
  end

  defp parse_template!(prompt) when is_binary(prompt) do
    Solid.parse!(prompt)
  rescue
    error ->
      reraise %RuntimeError{
                message: "template_parse_error: #{Exception.message(error)} template=#{inspect(prompt)}"
              },
              __STACKTRACE__
  end

  # Templates need a count they can branch on: a Liquid `{% if %}` treats an
  # empty list as true, so the list alone cannot gate the feedback section.
  defp to_feedback(notes) when is_list(notes) do
    %{
      "count" => length(notes),
      "pending_count" => Enum.count(notes, &is_nil(Map.get(&1, :delivered_at))),
      "notes" => Enum.map(notes, &feedback_note/1)
    }
  end

  defp to_feedback(_notes), do: to_feedback([])

  defp feedback_note(note) when is_map(note) do
    %{
      "note" => Map.get(note, :note),
      "requested_at" => Map.get(note, :requested_at),
      "requested_by" => Map.get(note, :requested_by),
      "delivered" => not is_nil(Map.get(note, :delivered_at))
    }
  end

  defp to_solid_map(map) when is_map(map) do
    Map.new(map, fn {key, value} -> {to_string(key), to_solid_value(value)} end)
  end

  defp to_solid_value(%DateTime{} = value), do: DateTime.to_iso8601(value)
  defp to_solid_value(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp to_solid_value(%Date{} = value), do: Date.to_iso8601(value)
  defp to_solid_value(%Time{} = value), do: Time.to_iso8601(value)
  defp to_solid_value(%_{} = value), do: value |> Map.from_struct() |> to_solid_map()
  defp to_solid_value(value) when is_map(value), do: to_solid_map(value)
  defp to_solid_value(value) when is_list(value), do: Enum.map(value, &to_solid_value/1)
  defp to_solid_value(value), do: value

  defp default_prompt(prompt) when is_binary(prompt) do
    if String.trim(prompt) == "" do
      Config.workflow_prompt()
    else
      prompt
    end
  end
end
