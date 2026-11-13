Cybertrain::Routes.draw do
  resource :session, only: [:new, :create, :destroy]
  get "/sign_up", to: "registrations#new", as: "sign_up"
  post "/sign_up", to: "registrations#create"
end
