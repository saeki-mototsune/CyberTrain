class PagesController < ApplicationController
  def about
    render plain: "about #{root_path} #{about_url}"
  end
end
