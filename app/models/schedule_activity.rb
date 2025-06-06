# frozen_string_literal: true

class ScheduleActivity < ApplicationRecord
  # See https://docs.google.com/document/d/1hnzAZizTH0XyGkSYe-PxFL5xpKVWl_cvSdTzlT_kAs8/edit#heading=h.14uuu58hnua
  VALID_ACTIVITY_CODE_BASE = (Event::OFFICIAL_IDS + %w[other]).freeze
  VALID_OTHER_ACTIVITY_CODE = %w[registration checkin multi breakfast lunch dinner awards unofficial misc tutorial setup teardown].freeze
  belongs_to :holder, polymorphic: true
  belongs_to :venue_room, optional: true # TODO: remove the `optional` part after the old holder column is gone
  belongs_to :round, optional: true
  belongs_to :parent_activity, class_name: "ScheduleActivity", optional: true
  has_many :child_activities, class_name: "ScheduleActivity", as: :holder, dependent: :destroy
  has_many :wcif_extensions, as: :extendable, dependent: :delete_all
  has_many :assignments, dependent: :delete_all

  validates :name, presence: true
  validates :wcif_id, numericality: { only_integer: true }
  validates :start_time, presence: { allow_blank: false }
  validates :end_time, presence: { allow_blank: false }
  validates :activity_code, presence: { allow_blank: false }
  # TODO: we don't yet care for scramble_set_id
  validate :included_in_parent_schedule
  validate :valid_activity_code
  delegate :color, to: :holder

  def included_in_parent_schedule
    return if errors.present?

    errors.add(:start_time, "should be after parent's start_time") unless start_time >= holder.start_time
    errors.add(:end_time, "should be before parent's end_time") unless end_time <= holder.end_time
    errors.add(:end_time, "should be after start_time") unless start_time <= end_time
  end

  def valid_activity_code
    return if errors.present?

    activity_id = activity_code.split('-').first
    errors.add(:activity_code, "should be a valid activity code") unless VALID_ACTIVITY_CODE_BASE.include?(activity_id)
    if activity_id == "other"
      other_id = activity_code.split('-').second
      errors.add(:activity_code, "is an invalid 'other' activity code") unless VALID_OTHER_ACTIVITY_CODE.include?(other_id)
    end

    return unless holder.has_attribute?(:activity_code)

    holder_activity_id = holder.activity_code.split('-').first
    errors.add(:activity_code, "should share its base activity id with parent") unless activity_id == holder_activity_id
  end

  # Name can be specified externally, but we may want to infer the activity name
  # from its activity code (eg: if it's for an event or round).
  def localized_name(rounds_by_wcif_id = {})
    parts = self.parsed_activity_code
    if parts[:event_id] == "other"
      # TODO/NOTE: should we fix the name for event with predefined activity codes? (ie: those below but 'misc' and 'unofficial')
      # VALID_OTHER_ACTIVITY_CODE = %w(registration checkin multi breakfast lunch dinner awards unofficial misc).freeze
      name
    else
      inferred_name = Event.c_find(parts[:event_id]).name
      round = rounds_by_wcif_id["#{parts[:event_id]}-r#{parts[:round_number]}"]
      inferred_name = round[:name] if round
      inferred_name += " (#{I18n.t('attempts.attempt_name', number: parts[:attempt_number])})" if parts[:attempt_number]
      inferred_name
    end
  end

  # Get this activity's activity_code and all of its nested activities
  # NOTE: as is, the WCA schedule editor doesn't support nested activities, but this
  # doesn't prevent anyone from submitting a WCIF with 333fm-a1 nested in 333fm (for instance).
  def all_activity_codes
    [activity_code, child_activities.map(&:all_activity_codes)].flatten
  end

  def all_activities
    [self, child_activities.map(&:all_activities)].flatten
  end

  def root_activity
    parent_activity&.root_activity || self
  end

  def parsed_activity_code
    ScheduleActivity.parse_activity_code(self.activity_code)
  end

  def to_wcif
    {
      "id" => wcif_id,
      "name" => name,
      "activityCode" => activity_code,
      "startTime" => start_time.iso8601,
      "endTime" => end_time.iso8601,
      "childActivities" => child_activities.map(&:to_wcif),
      "extensions" => wcif_extensions.map(&:to_wcif),
    }
  end

  # TODO: not a fan of how it works (= passing round information)
  def to_event(rounds_by_wcif_id = {})
    raise "#to_event called for nested activity" unless holder.is_a?(VenueRoom)

    {
      title: localized_name(rounds_by_wcif_id),
      roomId: holder.id,
      roomName: holder.name,
      venueName: holder.competition_venue.name,
      color: color,
      activityDetails: parsed_activity_code,
      start: start_time.in_time_zone(holder.competition_venue.timezone_id),
      end: end_time.in_time_zone(holder.competition_venue.timezone_id),
    }
  end

  def load_wcif!(wcif, venue_room, parent_activity: nil)
    update!(
      venue_room: venue_room,
      parent_activity: parent_activity,
      **ScheduleActivity.wcif_to_attributes(wcif),
    )
    if self.activity_code_previously_changed?
      round = parent_activity&.round || self.find_matched_round
      self.update_attribute!(:round, round) if round.present?
    end
    new_child_activities = wcif["childActivities"].map do |activity_wcif|
      activity = child_activities.find { |a| a.wcif_id == activity_wcif["id"] } || child_activities.build
      activity.load_wcif!(activity_wcif, venue_room, parent_activity: self)
    end
    self.child_activities = new_child_activities
    WcifExtension.update_wcif_extensions!(self, wcif["extensions"]) if wcif["extensions"]
    self
  end

  private def find_matched_round
    # Using `find` instead of `find_by` throughout to leverage preloaded associations
    competition_event = venue_room.competition.competition_events.find { it.event_id == self.parsed_activity_code[:event_id] }
    return nil if competition_event.blank?

    competition_event.rounds.find { it.number == self.parsed_activity_code[:round_number] }
  end

  def move_by(diff)
    # 'diff' must be something add-able to a date (eg: 2.days, 34.seconds)
    self.assign_attributes(start_time: start_time + diff, end_time: end_time + diff)
    self.save(validate: false)
    child_activities.map { |a| a.move_by(diff) }
  end

  def move_to(date)
    self.assign_attributes(start_time: start_time.change(year: date.year, month: date.month, day: date.day),
                           end_time: end_time.change(year: date.year, month: date.month, day: date.day))
    self.save(validate: false)
    child_activities.map { |a| a.move_to(date) }
  end

  def self.wcif_json_schema
    {
      "type" => "object",
      "id" => "activity",
      "properties" => {
        "id" => { "type" => "integer" },
        "name" => { "type" => "string" },
        "activityCode" => { "type" => "string" },
        "startTime" => { "type" => "string" },
        "endTime" => { "type" => "string" },
        "childActivities" => { "type" => "array", "items" => { "$ref" => "activity" } },
        "extensions" => { "type" => "array", "items" => WcifExtension.wcif_json_schema },
      },
      "required" => %w[id name activityCode startTime endTime childActivities],
    }
  end

  def self.wcif_to_attributes(wcif)
    {
      wcif_id: wcif["id"],
      name: wcif["name"],
      activity_code: wcif["activityCode"],
      start_time: wcif["startTime"],
      end_time: wcif["endTime"],
    }
  end

  def self.parse_activity_code(activity_code)
    parts = activity_code.split("-")
    parts_hash = {
      event_id: parts.shift,
      round_number: nil,
      group_number: nil,
      attempt_number: nil,
    }

    parts.each do |p|
      case p[0]
      when "a"
        parts_hash[:attempt_number] = p[1..].to_i
      when "g"
        parts_hash[:group_number] = p[1..].to_i
      when "r"
        parts_hash[:round_number] = p[1..].to_i
      end
    end
    parts_hash
  end
end
