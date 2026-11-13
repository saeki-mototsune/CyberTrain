Cybertrain::Routes.draw do
  resources :articles, only: [:index, :show, :create]
end
