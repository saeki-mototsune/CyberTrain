Cybertrain::Routes.draw do
  root "posts#index"
  resources :posts do |posts|
    posts.collection { |c| c.get "search" }
    posts.member { |m| m.get "preview" }
    posts.resources :comments, only: [:create, :destroy]
  end
  get "/about", to: "pages#about"
  scope "/v1", as: "v1" do |v|
    v.get "/about", to: "pages#about"
  end
  resource :profile, controller: "pages", only: [:show] do |r|
    r.get :refresh, on: :member
  end
  get "/old-posts/:id", to: redirect("/posts/%{id}")
  get "/files/:name", to: "pages#file", format: false
  jobs_page "/admin/jobs", before_action: :require_admin
end
