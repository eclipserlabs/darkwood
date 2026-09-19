defmodule Darkwood.Ingestion.ProducerTest do
  use ExUnit.Case, async: false

  alias Darkwood.Ingestion.Producer

  test "max_buffer is a positive bound" do
    assert Producer.max_buffer() > 0
  end

  test "depth reports buffered state without crashing" do
    assert Producer.depth() == :unknown or match?(%{buffered: _}, Producer.depth())
  end

  test "push accepts or sheds load without crashing" do
    assert Producer.push(%{incident_id: -1, attrs: %{}}) in [:ok, {:error, :overloaded}]
  end
end
