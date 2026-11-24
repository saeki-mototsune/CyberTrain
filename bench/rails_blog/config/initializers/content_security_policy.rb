# Be sure to restart your server when you modify this file.

# Define an application-wide content security policy.
# See the Securing Rails Applications Guide for more information:
# https://guides.rubyonrails.org/security.html#content-security-policy-header

# The policy of examples/blog (its config/app.rb), sent with every response:
# scripts, styles and images from this origin (and data: images), and a fresh
# nonce per response on script-src and style-src, which the import map's
# inline scripts carry (javascript_importmap_tags) and csp_meta_tag prints.
# examples/blog also allows the one jsDelivr path its Turbo is pinned from;
# here Turbo is turbo-rails' own copy, served from this origin.
Rails.application.configure do
  config.content_security_policy do |policy|
    policy.default_src :self
    policy.script_src  :self
    policy.style_src   :self
    policy.img_src     :self, :data
  end

  # A new nonce for every response, as examples/blog makes one, rather than
  # the session id the generated comment suggests.
  config.content_security_policy_nonce_generator = ->(request) { SecureRandom.base64(16) }
  config.content_security_policy_nonce_directives = %w(script-src style-src)
end
