Cybertrain::Routes.draw do
  namespace :admin do |admin|
    admin.resources :users, only: [:index, :show], param: :login
    admin.resources :reports, only: [:index]
  end
end
