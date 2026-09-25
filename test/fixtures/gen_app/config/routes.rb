Cybertrain::Routes.draw do
  root "posts#index"
  resources :posts do |posts|
    posts.collection { |c| c.get "search" }
    posts.member { |m| m.get "preview" }
    posts.resources :comments, only: [:create, :destroy]
  end
  get "/about", to: "pages#about"
end
