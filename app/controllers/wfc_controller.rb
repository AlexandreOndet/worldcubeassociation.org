# frozen_string_literal: true

class WfcController < ApplicationController
  before_action :authenticate_user!
  before_action -> { redirect_to_root_unless_user(:can_admin_finances?) }

  def panel
  end

  def competition_export
    select_attributes = [
      :id, :name, :start_date, :end_date,
      :country_id, :announced_at, :results_posted_at,
      :currency_code, :base_entry_fee_lowest_denomination,
      "count(distinct persons.id) as num_competitors"
    ]
    from = params.require(:from_date)
    to = params.require(:to_date)
    response.headers["Content-Disposition"] = "attachment; filename=\"wfc-competitions-export-#{from}-#{to}.tsv\""
    @competitions = Competition
                    .select(select_attributes)
                    .includes(:delegates, :championships, :organizers, :events, organizers: [:wfc_dues_redirect])
                    .left_joins(:competitors)
                    .group(:id)
                    .where(results_posted_at: from..to)
                    .order(:results_posted_at, :name)
  end
end
