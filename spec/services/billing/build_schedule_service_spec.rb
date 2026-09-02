# frozen_string_literal: true

require "rails_helper"

RSpec.describe Billing::BuildScheduleService do
  subject(:result) { described_class.call(subscription_rate_card:, plan_rate_cards:) }

  let(:organization) { create(:organization) }
  let(:customer) { create(:customer, organization:, timezone:) }
  let(:timezone) { "UTC" }
  let(:plan) { create(:plan, organization:, pricing_type: "product_catalog") }
  let(:subscription) { create(:subscription, organization:, customer:, plan:) }
  let(:rate_card) { create(:rate_card, organization:) }
  let(:plan_rate_cards) { [] }
  let(:ended_at) { nil }

  let(:subscription_rate_card) do
    create(
      :subscription_rate_card,
      organization:, subscription:, customer:, rate_card:,
      billing_anchor_date: Date.new(2026, 1, 1),
      started_at: Time.utc(2026, 1, 15, 14, 30),
      next_billing_at: Time.utc(2026, 2, 1),
      ended_at:
    )
  end

  before do
    create(
      :rate_card_rate,
      organization:, rate_card:,
      effective_from: Time.utc(2025, 1, 1),
      billing_interval_count: 1,
      billing_interval_unit: "month"
    )
  end

  it "carries the card's anchor, timing and end onto the schedule" do
    cycle = result.schedule.cycles_due_by(Time.utc(2026, 3, 1)).first

    expect(result).to be_success
    expect(cycle.from...cycle.to).to eq(Time.utc(2026, 1, 15)...Time.utc(2026, 2, 1))
    expect(cycle.due_at).to eq(Time.utc(2026, 2, 1))
  end

  # A card attached at 14:30 is billed for that whole day, and the flooring happens in the
  # customer's timezone rather than UTC.
  context "with a customer timezone" do
    let(:timezone) { "Europe/Paris" }

    it "opens the first cycle at the start of the signing day there" do
      cycle = result.schedule.cycles_due_by(Time.utc(2026, 3, 1)).first

      expect(cycle.from).to eq(Time.utc(2026, 1, 14, 23))
    end
  end

  context "when the card has ended" do
    let(:ended_at) { Time.utc(2026, 1, 20) }

    it "stops the schedule there" do
      cycles = result.schedule.cycles_due_by(Time.utc(2026, 6, 1))

      expect(cycles.sole.to).to eq(Time.utc(2026, 1, 20))
    end
  end

  describe "phases" do
    # No phases at all: the card bills on its own cadence forever, which is one open phase.
    it "gives a card without phases a single open phase" do
      cycles = result.schedule.cycles_due_by(Time.utc(2026, 3, 1))

      expect(cycles.map { |cycle| cycle.phase.cycle_count }).to eq([nil, nil])
      expect(cycles.map { |cycle| cycle.phase.code }).to eq([nil, nil])
    end

    context "with a bounded phase carrying an interval override" do
      let(:rate_override) do
        create(:rate_override, organization:, billing_interval_count: 1, billing_interval_unit: "week")
      end

      before do
        create(
          :rate_phase,
          organization:,
          plan_rate_card: nil,
          subscription_rate_card:,
          position: 1,
          code: "weekly_intro",
          billing_interval_cycle_count: 2,
          rate_override:
        )
      end

      # Two weekly cycles, then the card's own monthly cadence takes over: the open tail is
      # appended because the configured phases are all bounded.
      it "uses the override cadence and then falls back to the card's" do
        cycles = result.schedule.cycles_due_by(Time.utc(2026, 4, 1))

        expect(cycles.first(2).map { |cycle| [cycle.from.to_date.to_s, cycle.phase.code] }).to eq(
          [["2026-01-15", "weekly_intro"], ["2026-01-22", "weekly_intro"]]
        )
        expect(cycles[2].from.to_date.to_s).to eq("2026-01-29")
        expect(cycles[2].phase.code).to be_nil
      end

      it "carries the override so the caller can price the cycle with it" do
        expect(result.schedule.cycles_due_by(Time.utc(2026, 2, 1)).first.phase.override).to eq(rate_override)
      end
    end

    # Phases live on the plan entry until the subscription overrides them.
    context "with phases on the plan entry" do
      let(:plan_rate_card) { create(:plan_rate_card, organization:, plan:, rate_card:, units: 1) }
      let(:plan_rate_cards) { [plan_rate_card] }

      before do
        create(
          :rate_phase,
          organization:, plan_rate_card:, position: 1, code: "intro",
          billing_interval_cycle_count: 2
        )
      end

      it "reads them through the plan" do
        expect(result.schedule.cycles_due_by(Time.utc(2026, 2, 1)).first.phase.code).to eq("intro")
      end
    end
  end

  # QA plan R2: "No rate = no fee is expected behavior, not an error." There is no cadence
  # to build a calendar from either, so the schedule cannot be produced at all.
  context "when no rate is in force when the card starts" do
    before { rate_card.rates.update_all(effective_from: Time.utc(2027, 1, 1)) } # rubocop:disable Rails/SkipsModelValidations

    it "fails rather than guessing a cadence" do
      expect(result).not_to be_success
      expect(result.error.error_code).to eq("rate_not_found")
    end
  end
end
