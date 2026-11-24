Rails.application.routes.draw do
  resource :session, only: [:new, :create, :destroy]
  resources :passwords, param: :token, only: [:new, :create, :edit, :update]
  root "articles#index"

  resources :articles do
    resources :comments, only: [:create, :destroy]
  end

  # Under /admin, for admins only (User#admin?): the article list and its
  # delete buttons. examples/blog also has a jobs page here.
  namespace :admin do
    resources :articles, only: [:index, :destroy]
  end
end
