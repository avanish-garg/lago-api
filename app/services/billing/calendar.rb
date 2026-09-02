# frozen_string_literal: true

module Billing
  class Calendar
    def initialize(anchor_date:, interval:, timezone:)
      @anchor_date = anchor_date
      @interval = interval
      @timezone = timezone
    end

    # Boundary 0: the start of the anchor day in the customer timezone.
    # @example anchor 2022-02-01 in "America/New_York" is 2022-02-01 05:00 UTC
    def anchor
      @anchor ||= anchor_date.in_time_zone(timezone).beginning_of_day
    end

    # The index of the period `timestamp` falls in, negative before the anchor. A position on
    # this ruler, not a billing cycle number.
    # @example anchored on Jul 15: index_at(Jul 2) is -1, the period [Jun 15, Jul 15)
    def index_at(timestamp)
      interval.steps_between(anchor, timestamp.in_time_zone(timezone))
    end

    # The half-open period `timestamp` falls in, as [boundary, next boundary).
    # @example anchored on Feb 1: period_at(Feb 10) is 2022-02-01...2022-03-01
    def period_at(timestamp)
      index = index_at(timestamp)

      at(index)...at(index + 1)
    end

    # Days in the whole period `timestamp` falls in, whether or not the window covers it all.
    # @example anchored on Jun 1 monthly: days_in_period_at(Jun 10) is 30
    def days_in_period_at(timestamp)
      period = period_at(timestamp)

      covered_days(period.begin, period.end)
    end

    # Fraction of its period the half-open window [from, to) covers. The window must sit
    # inside one period: measuring across a boundary would divide by the wrong length.
    # @example in a 30-day period: [Jun 1, Jul 1) is 1.0, [Jun 28, Jul 1) is 0.1
    def elapsed_ratio(from, to)
      period = period_at(from)
      raise ArgumentError, "window end #{to} precedes its start #{from}" if to < from
      raise ArgumentError, "window [#{from}, #{to}) crosses the boundary at #{period.end}" if to > period.end

      covered_days(from, to).fdiv(covered_days(period.begin, period.end))
    end

    private

    attr_reader :anchor_date, :interval, :timezone

    # The boundary at position `index`, re-derived from the anchor so month-ends don't drift.
    # @example anchored on Jan 31: at(1) is Feb 28, at(2) is Mar 31
    def at(index)
      interval.advance(anchor, index)
    end

    # Days in the half-open window [from, to), counted in the customer's timezone. A day
    # belongs to the window holding its midnight, so a window cut part-way through a day
    # does not claim it.
    #
    # That is what makes a cut cycle add up. The count is a difference of a function of the
    # two ends alone, so however many times a period is cut — one rate change, then another
    # — the windows telescope back to the period itself and bill it exactly once. Cuts
    # inside a day are the normal case rather than the edge one: a pay-in-advance rate takes
    # effect at an arbitrary instant, and RateCardRate#normalize_effective_from floors only
    # arrears rates, to UTC midnight rather than to the customer's.
    #
    # A day begun still counts whole at the end of service, since a terminal window opens on
    # the period's own boundary and that midnight is inside it.
    #
    # Deliberately not Utils::Datetime.date_diff_with_timezone: that counts each side of a
    # cut independently and both with a ceil, so the shared day is billed twice. A v1
    # upgrade at 14:00 charges 16 + 15 days of a 30-day month, one at midnight 16 + 16.
    #
    # @example [Jun 1, Jun 1 09:00) is 1 day — Jun 1 begins inside it
    # @example [Jun 1, Jun 16 14:00) is 16 days, [Jun 16 14:00, Jul 1) is 14, and 16 + 14 = 30
    def covered_days(from, to)
      (opening_date(to) - opening_date(from)).to_i
    end

    # The first local date whose midnight is at or after `time`. Compares against midnight
    # rather than adding a day, so a DST transition cannot shift the answer.
    # @example in "Europe/Paris": Jun 16 00:00 local stays Jun 16, Jun 16 00:00 UTC is Jun 17
    def opening_date(time)
      local = time.in_time_zone(timezone)

      (local == local.beginning_of_day) ? local.to_date : local.to_date + 1
    end
  end
end
