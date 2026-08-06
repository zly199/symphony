defmodule SymphonyElixir.CodexTranscriptTest do
  use SymphonyElixir.TestSupport

  alias SymphonyElixir.CodexTranscript

  describe "recording a run" do
    test "keeps every event and reads them back oldest first" do
      handle = CodexTranscript.start_run("issue-1", identifier: "MT-1", phase: :analysis)

      CodexTranscript.record(handle, %{
        event: :notification,
        timestamp: ~U[2026-08-06 00:00:01Z],
        payload: %{"method" => "item/completed", "params" => %{"item" => %{"type" => "agentMessage", "text" => "根因是版本比较"}}},
        raw: ~s({"method":"item/completed"})
      })

      CodexTranscript.record(handle, %{
        event: :turn_completed,
        timestamp: ~U[2026-08-06 00:00:02Z],
        payload: %{"method" => "turn/completed"}
      })

      CodexTranscript.finish(handle, :ok)

      assert {:ok, name, events} = CodexTranscript.read("issue-1")
      assert String.ends_with?(name, ".jsonl")

      assert Enum.map(events, & &1["event"]) == [
               "transcript_opened",
               "notification",
               "turn_completed",
               "transcript_closed"
             ]

      agent_event = Enum.at(events, 1)
      assert agent_event["at"] == "2026-08-06T00:00:01Z"
      assert get_in(agent_event, ["payload", "params", "item", "text"]) == "根因是版本比较"
      # The app-server's own line survives, so a transcript can answer questions
      # this module never anticipated.
      assert agent_event["raw"] == ~s({"method":"item/completed"})
      assert get_in(Enum.at(events, 0), ["details", "phase"]) == "analysis"
    end

    test "lists runs newest first and reads a named one" do
      first = CodexTranscript.start_run("issue-2")
      CodexTranscript.record(first, %{event: :notification, timestamp: DateTime.utc_now(), payload: %{"method" => "first/run"}})
      CodexTranscript.finish(first, :ok)

      # Run file names carry a millisecond stamp, so two runs in the same test
      # only sort apart if time actually moved.
      Process.sleep(5)

      second = CodexTranscript.start_run("issue-2")
      CodexTranscript.record(second, %{event: :notification, timestamp: DateTime.utc_now(), payload: %{"method" => "second/run"}})
      CodexTranscript.finish(second, :ok)

      assert [newest, oldest] = CodexTranscript.runs("issue-2")
      assert newest.bytes > 0
      assert newest.recorded_at =~ ~r/^\d{4}-\d{2}-\d{2}T/

      assert {:ok, _name, events} = CodexTranscript.read("issue-2")
      assert Enum.any?(events, &(get_in(&1, ["payload", "method"]) == "second/run"))

      assert {:ok, _name, older_events} = CodexTranscript.read("issue-2", oldest.name)
      assert Enum.any?(older_events, &(get_in(&1, ["payload", "method"]) == "first/run"))
    end

    test "a run name that was never recorded is not found" do
      handle = CodexTranscript.start_run("issue-3")
      CodexTranscript.finish(handle, :ok)

      assert {:error, :not_found} = CodexTranscript.read("issue-3", "../../../etc/passwd")
      assert {:error, :not_found} = CodexTranscript.read("issue-never-ran")
    end

    test "an issue id cannot walk out of the transcripts directory" do
      directory = CodexTranscript.directory("../../escape")

      assert Path.basename(directory) == "------escape"
      assert directory |> Path.dirname() |> Path.basename() == "transcripts"
    end

    test "recording against a handle that never opened is a no-op" do
      handle = %{path: nil, device: nil, bytes: nil}

      assert :ok = CodexTranscript.record(handle, %{event: :notification, timestamp: DateTime.utc_now()})
      assert :ok = CodexTranscript.finish(handle, :ok)
    end

    test "clear drops every recorded run" do
      handle = CodexTranscript.start_run("issue-4")
      CodexTranscript.finish(handle, :ok)

      assert [_run] = CodexTranscript.runs("issue-4")
      assert :ok = CodexTranscript.clear("issue-4")
      assert [] = CodexTranscript.runs("issue-4")
    end
  end
end
