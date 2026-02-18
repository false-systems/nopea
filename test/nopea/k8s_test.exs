defmodule Nopea.K8sTest do
  use ExUnit.Case, async: true

  alias Nopea.K8s

  describe "conn/0" do
    test "returns conn from application env when set" do
      # test_helper.exs sets :k8s_conn to %K8s.Conn{}
      assert {:ok, conn} = K8s.conn()
      assert is_struct(conn)
    end
  end
end
