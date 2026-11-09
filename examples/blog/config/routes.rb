Cybertrain::Routes.draw do
  root "articles#index"

  # Nested blocks take the mapper explicitly (Spinel cannot instance_eval
  # them): `articles.resources` instead of Rails' bare `resources`.
  resources :articles do |articles|
    articles.resources :comments, only: [:create, :destroy]
  end

  # The jobs page, behind ApplicationController#require_admin (404 unless
  # BLOG_ADMIN_TOKEN is set and the visitor proves it), and the form that
  # signs a browser in with that token.
  jobs_page "/admin/jobs", before_action: :require_admin
  get "/admin/login", to: "admin_sessions#new"
  post "/admin/login", to: "admin_sessions#create"
end
