Cybertrain::Routes.draw do
  namespace :admin do |admin|
    admin.resources :users, only: [:index, :show], param: :login
  end
end
