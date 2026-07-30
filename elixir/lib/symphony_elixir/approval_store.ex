defmodule SymphonyElixir.ApprovalStore do
  @moduledoc """
  Records the operator decisions that move a work item from one phase to the next.

  Two gates live here. The analysis approval moves a ticket into implementation;
  the review approval, taken after CI is green and the merge request exists, moves
  it into the summary phase that writes the merge-request description. Both are
  human decisions, so they must survive an orchestrator restart that in-memory
  state would lose. The store is a small JSON file rewritten atomically; traffic
  is one read per dispatch and one write per decision, so a plain module beats a
  supervised process here.
  """

  require Logger

  alias SymphonyElixir.StateFile

  @file_name "approvals.json"

  @type record :: %{
          issue_id: String.t(),
          identifier: String.t() | nil,
          approved_at: String.t(),
          approved_by: String.t() | nil,
          review_approved_at: String.t() | nil,
          review_approved_by: String.t() | nil
        }

  @doc "Returns true when `issue_id` has been approved for implementation."
  @spec approved?(String.t() | nil) :: boolean()
  def approved?(issue_id) when is_binary(issue_id), do: Map.has_key?(load(), issue_id)
  def approved?(_issue_id), do: false

  @doc """
  Returns true when the operator has signed off on `issue_id`'s implementation
  review, which is what releases the merge-request summary phase.
  """
  @spec review_approved?(String.t() | nil) :: boolean()
  def review_approved?(issue_id) when is_binary(issue_id) do
    case Map.get(load(), issue_id) do
      %{review_approved_at: approved_at} when is_binary(approved_at) -> true
      _ -> false
    end
  end

  def review_approved?(_issue_id), do: false

  @doc """
  Returns the ids whose review the operator has signed off on.

  The dashboard needs this answer for every row it renders, and one read beats one
  read per row.
  """
  @spec review_approved_ids() :: MapSet.t(String.t())
  def review_approved_ids do
    load()
    |> Enum.flat_map(fn
      {issue_id, %{review_approved_at: approved_at}} when is_binary(approved_at) -> [issue_id]
      _ -> []
    end)
    |> MapSet.new()
  end

  @doc "Returns the approval record for `issue_id`, or nil."
  @spec fetch(String.t() | nil) :: record() | nil
  def fetch(issue_id) when is_binary(issue_id), do: Map.get(load(), issue_id)
  def fetch(_issue_id), do: nil

  @doc "Records approval for `issue_id`. Re-approving refreshes the record."
  @spec approve(String.t(), keyword()) :: {:ok, record()} | {:error, term()}
  def approve(issue_id, opts \\ []) when is_binary(issue_id) do
    record = %{
      "issue_id" => issue_id,
      "identifier" => Keyword.get(opts, :identifier),
      "approved_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "approved_by" => Keyword.get(opts, :approved_by, "dashboard"),
      "review_approved_at" => nil,
      "review_approved_by" => nil
    }

    case load() |> Map.put(issue_id, record) |> store() do
      :ok ->
        Logger.info("Recorded analysis approval issue_id=#{issue_id} identifier=#{inspect(record["identifier"])}")

        {:ok, atomize(record)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Records the operator's sign-off on `issue_id`'s implementation review.

  Kept on the same record as the analysis approval, because a review approval
  without one would describe an item that never reached implementation. An item
  reviewed before it was ever approved gets both stamps at once rather than a
  record the phase logic cannot read.
  """
  @spec approve_review(String.t(), keyword()) :: {:ok, record()} | {:error, term()}
  def approve_review(issue_id, opts \\ []) when is_binary(issue_id) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()
    approvals = load()
    existing = Map.get(approvals, issue_id, %{})

    record =
      %{
        "issue_id" => issue_id,
        "identifier" => Keyword.get(opts, :identifier) || Map.get(existing, :identifier),
        "approved_at" => Map.get(existing, :approved_at) || now,
        "approved_by" => Map.get(existing, :approved_by) || Keyword.get(opts, :approved_by, "dashboard"),
        "review_approved_at" => now,
        "review_approved_by" => Keyword.get(opts, :approved_by, "dashboard")
      }

    case approvals |> Map.put(issue_id, record) |> store() do
      :ok ->
        Logger.info("Recorded review approval issue_id=#{issue_id} identifier=#{inspect(record["identifier"])}")

        {:ok, atomize(record)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Drops the approval for `issue_id` so the next run returns to analysis."
  @spec revoke(String.t()) :: :ok | {:error, term()}
  def revoke(issue_id) when is_binary(issue_id) do
    load() |> Map.delete(issue_id) |> store()
  end

  @doc """
  Drops only the review sign-off for `issue_id`, leaving the analysis approval in
  place so the next run goes back to implementation rather than back to analysis.
  """
  @spec revoke_review(String.t()) :: :ok | {:error, term()}
  def revoke_review(issue_id) when is_binary(issue_id) do
    approvals = load()

    case Map.get(approvals, issue_id) do
      nil ->
        :ok

      record ->
        approvals
        |> Map.put(issue_id, %{record | review_approved_at: nil, review_approved_by: nil})
        |> store()
    end
  end

  @doc false
  @spec path() :: Path.t()
  def path, do: StateFile.path(@file_name)

  defp load do
    @file_name
    |> StateFile.read_map()
    |> Map.new(fn {issue_id, record} -> {issue_id, atomize(record)} end)
  end

  defp store(approvals) do
    StateFile.write_map(@file_name, Map.new(approvals, fn {issue_id, record} -> {issue_id, stringify(record)} end))
  end

  defp atomize(record) when is_map(record) do
    %{
      issue_id: record["issue_id"] || record[:issue_id],
      identifier: record["identifier"] || record[:identifier],
      approved_at: record["approved_at"] || record[:approved_at],
      approved_by: record["approved_by"] || record[:approved_by],
      review_approved_at: record["review_approved_at"] || record[:review_approved_at],
      review_approved_by: record["review_approved_by"] || record[:review_approved_by]
    }
  end

  defp stringify(record) when is_map(record) do
    %{
      "issue_id" => record[:issue_id] || record["issue_id"],
      "identifier" => record[:identifier] || record["identifier"],
      "approved_at" => record[:approved_at] || record["approved_at"],
      "approved_by" => record[:approved_by] || record["approved_by"],
      "review_approved_at" => record[:review_approved_at] || record["review_approved_at"],
      "review_approved_by" => record[:review_approved_by] || record["review_approved_by"]
    }
  end
end
