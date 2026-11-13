Cybertrain::Routes.draw do
  resources :articles, only: [:index, :show, :new, :create]
end
