class PagesController < ApplicationController
  def about
    render plain: "about #{root_path} #{about_url}"
  end

  # resource :profile, controller: "pages": a singular resource drawn to
  # another controller.
  def show
    render plain: "profile #{profile_path} #{refresh_profile_path}"
  end

  # The profile's `get :refresh, on: :member` route.
  def refresh
    render plain: "refresh #{v1_about_path}"
  end
end
