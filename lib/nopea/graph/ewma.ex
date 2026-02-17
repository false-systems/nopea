defmodule Nopea.Graph.EWMA do
  @moduledoc """
  Exponential Weighted Moving Average — the math behind all weight calculations.

  Pure value object. No side effects, no dependencies.
  """

  @alpha 0.3
  @decay_factor 0.95

  @doc """
  Update weight with new observation.

  new_weight = α × observation + (1 - α) × current
  """
  @spec update(float(), float()) :: float()
  def update(current, observation)
      when is_float(current) and is_float(observation) and
             current >= 0.0 and current <= 1.0 and
             observation >= 0.0 and observation <= 1.0 do
    @alpha * observation + (1.0 - @alpha) * current
  end

  @doc """
  Apply time-based decay to weight.
  """
  @spec decay(float(), float()) :: float()
  def decay(weight, factor \\ @decay_factor)
      when is_float(weight) and is_float(factor) and
             weight >= 0.0 and weight <= 1.0 and
             factor >= 0.0 and factor <= 1.0 do
    weight * factor
  end

  @doc """
  Check if weight is below death threshold.
  """
  @spec dead?(float(), float()) :: boolean()
  def dead?(weight, threshold)
      when is_float(weight) and is_float(threshold) do
    weight < threshold
  end

  @doc """
  Clamp a value to [0.0, 1.0].
  """
  @spec clamp(float()) :: float()
  def clamp(value) when is_float(value) do
    value |> max(0.0) |> min(1.0)
  end
end
