Cybertrain::Routes.draw do
  root "articles#index"

  # Nested blocks take the mapper explicitly (Spinel cannot instance_eval
  # them): `articles.resources` instead of Rails' bare `resources`.
  resources :articles do |articles|
    articles.resources :comments, only: [:create, :destroy]
  end
end
