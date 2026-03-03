defmodule Nopea.OccurrenceLogTest do
  use ExUnit.Case, async: true

  alias Nopea.Occurrence, as: NopeaOccurrence

  @result %{
    service: "api-gateway",
    namespace: "staging",
    strategy: :direct,
    status: :completed,
    deploy_id: "01LOG",
    manifests_applied: 2,
    duration_ms: 800,
    verified: true,
    error: nil,
    applied_resources: []
  }

  defp start_emitter(occ) do
    {:ok, emitter} = NopeaOccurrence.start_log_emitter(occ)
    on_exit(fn -> if Process.alive?(emitter), do: GenServer.stop(emitter) end)
    emitter
  end

  describe "start_log_emitter/1" do
    test "starts a log emitter for the occurrence" do
      occ = NopeaOccurrence.build(@result)
      emitter = start_emitter(occ)
      assert is_pid(emitter)
    end

    test "emitter uses :both mode" do
      occ = NopeaOccurrence.build(@result)
      emitter = start_emitter(occ)

      semantic = %FalseProtocol.Semantic{
        event: "deploy.test.event",
        what_happened: "test event"
      }

      assert {:ok, entry} = FalseProtocol.LogEmitter.info_full(emitter, "test message", semantic)
      assert entry.mode == :both
      assert entry.message == "test message"
      assert entry.semantic.event == "deploy.test.event"
    end

    test "emitter sequences entries correctly" do
      occ = NopeaOccurrence.build(@result)
      emitter = start_emitter(occ)

      semantic = %FalseProtocol.Semantic{
        event: "deploy.test.first",
        what_happened: "first"
      }

      {:ok, entry1} = FalseProtocol.LogEmitter.info_full(emitter, "first", semantic)

      semantic2 = %FalseProtocol.Semantic{
        event: "deploy.test.second",
        what_happened: "second"
      }

      {:ok, entry2} = FalseProtocol.LogEmitter.info_full(emitter, "second", semantic2)

      assert entry1.seq == 1
      assert entry2.seq == 2
    end

    test "entries reference the parent occurrence" do
      occ = NopeaOccurrence.build(@result)
      emitter = start_emitter(occ)

      semantic = %FalseProtocol.Semantic{
        event: "deploy.test.ref",
        what_happened: "ref test"
      }

      {:ok, entry} = FalseProtocol.LogEmitter.info_full(emitter, "ref test", semantic)
      assert entry.occurrence_id == occ.id
    end
  end

  describe "attach_log_ref/2" do
    test "attaches log_ref with entry count" do
      occ = NopeaOccurrence.build(@result)
      emitter = start_emitter(occ)

      semantic = %FalseProtocol.Semantic{
        event: "deploy.test.count",
        what_happened: "counting"
      }

      FalseProtocol.LogEmitter.info_full(emitter, "one", semantic)
      FalseProtocol.LogEmitter.info_full(emitter, "two", semantic)

      updated = NopeaOccurrence.attach_log_ref(occ, emitter)

      assert %FalseProtocol.LogRef{} = updated.log_ref
      assert updated.log_ref.count == 2
    end
  end
end
