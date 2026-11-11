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

  # get "/files/:name", format: false: the dot stays in the segment.
  def file
    render plain: "file #{params[:name]} #{request.format}"
  end
end
