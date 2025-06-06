# frozen_string_literal: true

class Qualification
  include ActiveModel::Validations

  attr_accessor :when_date, :level, :wcif_type, :result_type

  validates :when_date, presence: true
  validates :result_type, presence: true, inclusion: { in: %w[single average] }
  validates :wcif_type, presence: true, inclusion: { in: %w[attemptResult ranking anyResult] }
  validates :level, numericality: { only_integer: true, greater_than: 0 }, if: :result_or_ranking?

  def result_or_ranking?
    %w[attemptResult ranking].include?(self.wcif_type)
  end

  def ==(other)
    other.class == self.class && other.to_wcif == self.to_wcif
  end

  def hash
    self.to_wcif.hash
  end

  def self.load(json)
    if json.nil? || json.is_a?(self)
      json
    else
      json_obj = json.is_a?(Hash) ? json : JSON.parse(json)
      out = Qualification.new
      out.wcif_type = json_obj['type']
      out.result_type = json_obj['resultType']
      out.level = json_obj['level']
      begin
        out.when_date = Date.iso8601(json_obj['whenDate'])
      rescue ArgumentError
        nil
      end
      out
    end
  end

  def can_register?(user, event_id)
    return false if user.person.nil?

    before_deadline_results = user.person.results.in_event(event_id).on_or_before(self.when_date)
    # Allow any competitor with a result to register when type == "ranking" or type == "anyResult".
    # When type == "ranking", the results need to be manually cleared out later.
    case self.wcif_type
    when "anyResult", "ranking"
      case self.result_type
      when "single"
        qualifying_results = before_deadline_results.succeeded
      when "average"
        qualifying_results = before_deadline_results.average_succeeded
      end
    when "attemptResult"
      case self.result_type
      when "single"
        qualifying_results = before_deadline_results.single_better_than(self.level)
      when "average"
        qualifying_results = before_deadline_results.average_better_than(self.level)
      end
    end
    qualifying_results.any?
  end

  def self.dump(qualification)
    qualification ? JSON.dump(qualification.to_wcif) : nil
  end

  def self.wcif_json_schema
    {
      "type" => %w[object null],
      "properties" => {
        "whenDate" => { "type" => "string" },
        "resultType" => { "type" => "string", "enum" => %w[single average] },
        "type" => { "type" => "string", "enum" => %w[attemptResult ranking anyResult] },
        "level" => { "type" => %w[integer null] },
      },
    }
  end

  def to_wcif
    {
      "type" => @wcif_type,
      "resultType" => @result_type,
      "whenDate" => @when_date&.strftime("%Y-%m-%d"),
      "level" => @level,
    }
  end

  def to_s(event)
    if self.wcif_type == "ranking"
      I18n.t("qualification.#{self.result_type}.ranking", ranking: level)
    elsif self.wcif_type == "anyResult"
      I18n.t("qualification.#{self.result_type}.any_result")
    elsif event.event.timed_event?
      I18n.t("qualification.#{self.result_type}.time", time: SolveTime.centiseconds_to_clock_format(level))
    elsif event.event.fewest_moves?
      moves = self.result_type == "average" ? (level.to_f / 100).round(2) : level
      I18n.t("qualification.#{self.result_type}.moves", moves: moves)
    elsif event.event.multiple_blindfolded?
      I18n.t("qualification.#{self.result_type}.points", points: SolveTime.multibld_attempt_to_points(level))
    end
  end
end
