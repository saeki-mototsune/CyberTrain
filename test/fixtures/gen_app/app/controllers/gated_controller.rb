# Concerns at the position of their include: set_post runs first, then
# AdminGate's require_admin and Auditing's audit, then log_visit.
class GatedController < ApplicationController
  before_action :set_post
  include AdminGate
  include Auditing
  before_action :log_visit

  def show
    render plain: "gated #{@post} per_page=#{self.class.per_page} admin?=#{admin?} audited_at=#{@audited_at}"
  end

  private

  def set_post
    @post = params[:id].to_s
  end

  def log_visit
    response.set_header("X-Visit", "logged")
  end
end
