Cybertrain::Routes.draw do
  resources :articles, only: [:show]
end
