Cybertrain::Routes.draw do
  resource :session, only: [:new, :create, :destroy]
  resources :passwords, param: :token, only: [:new, :create, :edit, :update]
  resource :account, only: [:edit, :update, :destroy]
  get "/setup", to: "setup#new", as: "setup"
  post "/setup", to: "setup#create"
  root "articles#index"

  # Nested blocks take the mapper explicitly (Spinel cannot instance_eval
  # them): `articles.resources` instead of Rails' bare `resources`.
  resources :articles do |articles|
    articles.resources :comments, only: [:create, :destroy]
  end

  # Under /admin, for admins only (User#admin?, set with `./blog user admin
  # EMAIL`): the article list and its delete buttons
  # (Admin::ArticlesController, gated by the AdminGate concern, whose
  # before_action is the Authentication concern's require_admin) and the
  # jobs page (/admin/jobs). The jobs page names require_admin alone
  # (skip_before_action: :require_authentication), so a visitor gets its
  # 404 rather than a redirect to sign in that shows the page exists.
  namespace :admin do |admin|
    admin.resources :articles, only: [:index, :destroy]
    admin.jobs_page "/jobs", before_action: :require_admin, skip_before_action: :require_authentication
  end
end
