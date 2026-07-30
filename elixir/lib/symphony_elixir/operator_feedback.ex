defmodule SymphonyElixir.OperatorFeedback do
  @moduledoc """
  Records the operator's written corrections to a work item, at whichever gate it
  is parked.

  Approval is only half of a gate. Work that is wrong needs a way back into the
  flow, and the correction has to reach the next Codex run instead of staying in
  the operator's head, so notes are persisted beside the approvals and rendered
  into the next prompt. Every gate uses this one channel — a rejected analysis, a
  review that found a problem in the merge request, a summary that needs
  rewriting — which is why a note carries the `phase` it was written against: the
  prompt renders "fix the document" and "fix the implementation" differently, and
  only the phase tells them apart.

  Each note keeps the run that consumed it visible through `delivered_at`, which
  is what lets the dashboard distinguish feedback still waiting for a run from
  feedback an agent has already seen.
  """

  require Logger

  alias SymphonyElixir.StateFile

  @file_name "operator_feedback.json"

  # A note is operator prose, not a document: enough room to describe what is
  # wrong, bounded so a paste accident cannot crowd out the prompt itself.
  @max_note_length 4_000

  # Older notes stay as standing requirements, but only the recent ones are worth
  # replaying to the agent every run.
  @max_notes 20

  @phases ["analysis", "implementation", "summary"]

  @type note :: %{
          note: String.t(),
          phase: String.t(),
          identifier: String.t() | nil,
          requested_at: String.t(),
          requested_by: String.t() | nil,
          delivered_at: String.t() | nil
        }

  @doc "Returns `issue_id`'s notes, oldest first."
  @spec notes(String.t() | nil) :: [note()]
  def notes(issue_id) when is_binary(issue_id) do
    load() |> Map.get(issue_id, [])
  end

  def notes(_issue_id), do: []

  @doc "Returns the notes for `issue_id` that no agent run has consumed yet."
  @spec pending(String.t() | nil) :: [note()]
  def pending(issue_id), do: issue_id |> notes() |> Enum.filter(&is_nil(&1.delivered_at))

  @doc "Returns true when `issue_id` carries feedback no run has consumed yet."
  @spec pending?(String.t() | nil) :: boolean()
  def pending?(issue_id), do: pending(issue_id) != []

  @doc """
  Appends `text` as feedback on `issue_id`.

  `:phase` names the work the note is about, so the next prompt can say what to
  rewrite. Blank text is rejected rather than stored: an empty note would send the
  ticket back for another pass without telling the agent what to change.
  """
  @spec add(String.t(), String.t() | nil, keyword()) :: {:ok, note()} | {:error, term()}
  def add(issue_id, text, opts \\ []) when is_binary(issue_id) do
    case normalize_note(text) do
      {:ok, text} ->
        note = %{
          "note" => text,
          "phase" => normalize_phase(Keyword.get(opts, :phase)),
          "identifier" => Keyword.get(opts, :identifier),
          "requested_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
          "requested_by" => Keyword.get(opts, :requested_by, "dashboard"),
          "delivered_at" => nil
        }

        stored = load_raw() |> Map.get(issue_id, []) |> Kernel.++([note]) |> Enum.take(-@max_notes)

        case put(issue_id, stored) do
          :ok ->
            Logger.info("Recorded operator feedback issue_id=#{issue_id} identifier=#{inspect(note["identifier"])} phase=#{note["phase"]} notes=#{length(stored)}")

            {:ok, decode_note(note)}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Stamps `issue_id`'s pending notes as delivered to an agent run.

  Called once the run that carries them in its prompt has started, so the
  dashboard stops advertising them as unanswered.
  """
  @spec mark_delivered(String.t() | nil) :: :ok | {:error, term()}
  def mark_delivered(issue_id) when is_binary(issue_id) do
    delivered_at = DateTime.utc_now() |> DateTime.to_iso8601()

    case load_raw() |> Map.get(issue_id, []) do
      [] ->
        :ok

      stored ->
        {marked, count} =
          Enum.map_reduce(stored, 0, fn
            %{"delivered_at" => nil} = note, count -> {Map.put(note, "delivered_at", delivered_at), count + 1}
            note, count -> {note, count}
          end)

        if count == 0 do
          :ok
        else
          Logger.info("Marked operator feedback as delivered issue_id=#{issue_id} notes=#{count}")

          put(issue_id, marked)
        end
    end
  end

  def mark_delivered(_issue_id), do: :ok

  @doc "Drops every note recorded for `issue_id`."
  @spec clear(String.t()) :: :ok | {:error, term()}
  def clear(issue_id) when is_binary(issue_id) do
    StateFile.write_map(@file_name, Map.delete(load_raw(), issue_id))
  end

  @doc false
  @spec path() :: Path.t()
  def path, do: StateFile.path(@file_name)

  defp normalize_note(text) when is_binary(text) do
    case String.trim(text) do
      "" -> {:error, :empty_note}
      trimmed -> {:ok, String.slice(trimmed, 0, @max_note_length)}
    end
  end

  defp normalize_note(_text), do: {:error, :empty_note}

  # Analysis is the phase every ticket passes through, so it is what an
  # unlabelled note — including one written by an older Symphony — belongs to.
  defp normalize_phase(phase) when is_atom(phase) and not is_nil(phase),
    do: normalize_phase(Atom.to_string(phase))

  defp normalize_phase(phase) when phase in @phases, do: phase
  defp normalize_phase(_phase), do: "analysis"

  defp put(issue_id, notes) do
    StateFile.write_map(@file_name, Map.put(load_raw(), issue_id, notes))
  end

  defp load do
    Map.new(load_raw(), fn {issue_id, notes} -> {issue_id, Enum.map(notes, &decode_note/1)} end)
  end

  defp load_raw do
    @file_name
    |> StateFile.read_map()
    |> Map.new(fn {issue_id, notes} -> {issue_id, List.wrap(notes)} end)
  end

  defp decode_note(note) when is_map(note) do
    %{
      note: note["note"] || note[:note],
      phase: normalize_phase(note["phase"] || note[:phase]),
      identifier: note["identifier"] || note[:identifier],
      requested_at: note["requested_at"] || note[:requested_at],
      requested_by: note["requested_by"] || note[:requested_by],
      delivered_at: note["delivered_at"] || note[:delivered_at]
    }
  end
end
