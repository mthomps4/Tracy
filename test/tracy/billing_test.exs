defmodule Tracy.BillingTest do
  use Tracy.DataCase, async: true

  alias Tracy.Billing
  alias Tracy.Billing.AgentRun

  describe "record_run/1" do
    test "inserts a run with required fields" do
      assert {:ok, %AgentRun{} = run} =
               Billing.record_run(%{
                 role: "main",
                 provider: "stub",
                 model: "stub",
                 bucket: "sdk_pool",
                 input_tokens: 10,
                 output_tokens: 5,
                 cost_micros: 1_000
               })

      assert run.bucket == "sdk_pool"
      assert run.cost_micros == 1_000
    end

    test "derives duration_ms from started_at + completed_at" do
      started = DateTime.utc_now()
      completed = DateTime.add(started, 1_250, :millisecond)

      assert {:ok, run} =
               Billing.record_run(%{
                 role: "main",
                 provider: "stub",
                 model: "stub",
                 bucket: "interactive",
                 started_at: started,
                 completed_at: completed
               })

      assert run.duration_ms == 1_250
    end

    test "rejects an invalid bucket" do
      assert {:error, cs} =
               Billing.record_run(%{
                 role: "main",
                 provider: "stub",
                 model: "stub",
                 bucket: "made-up"
               })

      assert %{bucket: ["is invalid"]} = errors_on(cs)
    end
  end

  describe "spend_micros/1" do
    test "sums cost in the current month for a bucket" do
      Billing.record_run(%{role: "main", provider: "stub", model: "stub", bucket: "sdk_pool", cost_micros: 250_000})
      Billing.record_run(%{role: "researcher", provider: "stub", model: "stub", bucket: "sdk_pool", cost_micros: 750_000})
      Billing.record_run(%{role: "main", provider: "stub", model: "stub", bucket: "interactive", cost_micros: 9_999_999})

      assert Billing.spend_micros(bucket: "sdk_pool") == 1_000_000
    end
  end

  describe "sdk_pool_status/1" do
    test "returns a map with pct + zone for a fresh pool" do
      status = Billing.sdk_pool_status()
      assert status.bucket == :sdk_pool
      assert status.cap_micros == Billing.sdk_pool_monthly_micros()
      assert status.spent_micros == 0
      assert status.pct == 0.0
      assert status.zone == :normal
    end

    test "transitions zones as spend rises" do
      # 60% — caution
      Billing.record_run(%{role: "main", provider: "stub", model: "stub", bucket: "sdk_pool", cost_micros: 60_000_000})
      assert Billing.sdk_pool_status().zone == :caution

      # +20% → 80% — winddown
      Billing.record_run(%{role: "main", provider: "stub", model: "stub", bucket: "sdk_pool", cost_micros: 20_000_000})
      assert Billing.sdk_pool_status().zone == :winddown

      # +10% → 90% — hardstop
      Billing.record_run(%{role: "main", provider: "stub", model: "stub", bucket: "sdk_pool", cost_micros: 10_000_000})
      assert Billing.sdk_pool_status().zone == :hardstop
    end
  end

  describe "gate_sdk_pool/1" do
    test ":ok when fresh" do
      assert Billing.gate_sdk_pool() == :ok
    end

    test "{:hardstop, pct} once past 85%" do
      Billing.record_run(%{role: "main", provider: "stub", model: "stub", bucket: "sdk_pool", cost_micros: 90_000_000})
      assert {:hardstop, pct} = Billing.gate_sdk_pool()
      assert pct >= 85
    end
  end

  describe "cost projections" do
    test "cost_dollars/1 + cost_cents/1 round-trip" do
      run = %AgentRun{cost_micros: 1_234_500}
      assert AgentRun.cost_dollars(run) == 1.2345
      assert AgentRun.cost_cents(run) == 123
    end
  end
end
