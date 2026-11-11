# The nested form: `module Admin` around the class. gen scans it as
# Admin::ReportsController; ApplicationController, written bare inside the
# module, resolves to the top-level class (gen found no
# Admin::ApplicationController).
module Admin
  class ReportsController < ApplicationController
    include AdminGate

    def index
      render plain: "admin reports for #{@viewer} per_page=#{self.class.per_page} #{admin_reports_path}"
    end
  end
end
