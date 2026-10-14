defmodule Gitpp.BurnTest do
  use ExUnit.Case, async: false

  alias Gitpp.{Project, ProjectSupervisor}

  # The frozen poc-quilt-1 record set (public: conformance/live-records.json
  # in SuperInstance/git.pp-ng).
  @records_json """
  [
    {"id":"genesis","parents":[],"kind":"task","effects":{"project":"poc-quilt-1","status":"open"}},
    {"id":"task-a","parents":["genesis"],"kind":"task","effects":{"config.timeout":30,"feature.cache":"on"}},
    {"id":"task-b","parents":["genesis"],"kind":"task","effects":{"config.timeout":60,"feature.search":"on"}},
    {"id":"override-1","parents":["task-a","task-b"],"kind":"override","effects":{"config.timeout":45},"reason":"captain: 45 is the safe value"},
    {"id":"task-c","parents":["override-1"],"kind":"task","effects":{"feature.inherited":true}},
    {"id":"task-d","parents":["task-b"],"kind":"task","effects":{"config.timeout":99}},
    {"id":"witness-1","parents":["genesis"],"kind":"witness","effects":{"env.oracle_disk_pct":93}},
    {"id":"witness-2","parents":["override-1"],"kind":"witness","effects":{"env.oracle_load1_x100":17}}
  ]
  """

  defp records, do: :json.decode(@records_json)

  test "burn/restart: kill the GenServer, restart from the record list, identical digest" do
    {:ok, sup} = ProjectSupervisor.start_link()
    pid1 = ProjectSupervisor.project_pid(sup)
    :ok = Project.push_records(pid1, records())
    digest_before = Project.digest(pid1)
    state_before = Project.derive(pid1)

    assert state_before["state"]["config.timeout"] == 45
    assert [%{"winner" => "override-1"}] = state_before["conflicts"]

    # Burn it: brutal kill, supervisor restarts an EMPTY project.
    Process.exit(pid1, :kill)
    pid2 = wait_for_restart(sup, pid1)
    assert pid2 != pid1
    assert Project.records(pid2) == []

    # Rebuild from the record alone — in a different arrival order, because
    # the fold must not care what order the mailbox delivered them in.
    :ok = Project.push_records(pid2, Enum.reverse(records()))
    assert Project.digest(pid2) == digest_before
    assert Project.derive(pid2) == state_before
  end

  test "the pinned poc-quilt-1 @task-c closure root reproduces from the doc" do
    # docs/CHECKPOINT-V2.md worked value.
    assert Gitpp.Fold.checkpoint_root(records(), "task-c") ==
             "60effe23970d8a5cc837636c44685502361288c1f00577e9addfa10cbd4fc91d"
  end

  defp wait_for_restart(sup, old_pid, tries \\ 100) do
    case ProjectSupervisor.project_pid(sup) do
      pid when is_pid(pid) and pid != old_pid ->
        pid

      _ ->
        if tries == 0, do: raise("project did not restart")
        Process.sleep(10)
        wait_for_restart(sup, old_pid, tries - 1)
    end
  end
end
