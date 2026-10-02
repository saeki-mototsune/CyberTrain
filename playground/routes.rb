Cybertrain::Routes.draw do
  root "articles#index"
  resources :articles
end
