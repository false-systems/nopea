defmodule Nopea.Test.Helpers do
  @moduledoc """
  Shared test helpers — polling assertions that replace raw `Process.sleep`.
  """

  @doc "Polls until the given block returns a truthy value, with timeout."
  defmacro assert_eventually(timeout_ms \\ 1000, do: block) do
    quote do
      deadline = System.monotonic_time(:millisecond) + unquote(timeout_ms)

      Stream.repeatedly(fn ->
        try do
          result = unquote(block)
          if result, do: {:ok, result}, else: {:retry}
        rescue
          _ -> {:retry}
        catch
          _, _ -> {:retry}
        end
      end)
      |> Enum.reduce_while(nil, fn
        {:ok, result}, _acc ->
          {:halt, result}

        {:retry}, _acc ->
          if System.monotonic_time(:millisecond) > deadline do
            {:halt, flunk("assert_eventually timed out after #{unquote(timeout_ms)}ms")}
          else
            Process.sleep(10)
            {:cont, nil}
          end
      end)
    end
  end
end
