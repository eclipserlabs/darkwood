defmodule Darkwood.Ingestion.RateLimiterTest do
  use ExUnit.Case, async: false

  alias Darkwood.Ingestion.RateLimiter

  test "allows requests then throttles over the limit" do
    ip = "10.0.0.#{System.unique_integer([:positive])}"

    assert :ok = RateLimiter.check(ip)

    results = for _ <- 1..200, do: RateLimiter.check(ip)
    assert {:error, :throttled} in results
  end

  test "invalid input does not crash" do
    assert :ok = RateLimiter.check(nil)
  end
end
