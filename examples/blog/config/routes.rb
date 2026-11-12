Cybertrain::Routes.draw do
  get "/articles/:id/cover", to: "articles#cover", as: "article_cover"
  root "articles#index"

  # Nested blocks take the mapper explicitly (Spinel cannot instance_eval
  # them): `articles.resources` instead of Rails' bare `resources`.
  resources :articles do |articles|
    articles.resources :comments, only: [:create, :destroy]
  end

  # Under /admin, each behind ApplicationController#require_admin (404
  # unless BLOG_ADMIN_TOKEN is set and the visitor proves it): the article
  # list and its delete buttons (Admin::ArticlesController, gated by the
  # AdminGate concern) and the jobs page (/admin/jobs). Then the form that
  # signs a browser in with that token.
  namespace :admin do |admin|
    admin.resources :articles, only: [:index, :destroy]
    admin.jobs_page "/jobs", before_action: :require_admin
  end
  get "/admin/login", to: "admin_sessions#new"
  post "/admin/login", to: "admin_sessions#create"
end
