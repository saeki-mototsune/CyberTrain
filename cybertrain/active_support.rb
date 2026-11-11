# ActiveSupport::Concern, as far as a controller or model concern needs
# it to compile (spec sections 4.1 and 4.2, plan decision 11). `ActiveSupport` as a whole
# does not exist.
module ActiveSupport
  # Lets a module of `app/controllers/concerns` (or `app/models/concerns`)
  # be written the Rails way:
  #
  #     module AdminGate
  #       extend ActiveSupport::Concern
  #
  #       included do
  #         before_action :require_admin
  #         helper_method :admin?
  #       end
  #
  #       class_methods do
  #         def per_page = 50
  #       end
  #
  #       def admin? = Current.user&.admin?
  #       def require_admin = (render plain: "Not Found", status: :not_found unless admin?)
  #     end
  #
  # {#included} and {#class_methods} do nothing, compiled and under CRuby
  # alike: their blocks never run. `spin run gen` reads them instead and
  # writes `gen/concerns.rb`, loaded after the application's classes: the
  # `included` body is spliced, as written, into every controller that
  # includes the concern, its declarations taking the place of the
  # `include` line among the controller's own (callbacks and `rescue_from`
  # handlers keep that order); each `class_methods` method becomes a method
  # of the concern, which every including class forwards to, so
  # `self.class.per_page` works in an action. A concern may include
  # concerns (expanded depth first, each once; a cycle is refused), and a
  # concern an ancestor already includes is not expanded again.
  #
  # A model concern's `included` body may hold any of a model's
  # declarations (`validates`, `validate`, `scope`, associations,
  # `encrypts`, callbacks); they count as written in the model at the
  # `include` (its `validates` rules run there among the model's own;
  # callbacks run after the model's own). Its instance methods are the
  # model's, and templates may call those without parameters.
  #
  # The application loads each concern from `gen/concerns/<path under
  # app/>`, its file with the `included` and `class_methods` blocks
  # blanked, so a block there may call the including class's methods
  # without a receiver (`scope :visible, -> { where(hidden: 0) }`).
  #
  # Differences from Rails: `around_action` in an `included` block is
  # refused (there are no around callbacks); a `class_methods` method may
  # not share its name with an instance method of the concern or of a
  # class that includes it (the compiled program would also give every
  # including class an instance method of that name; spikes/NOTES.md rule
  # 93), nor, in a model, with a scope or a class method every model has;
  # and a model concern's callbacks (`before_save` and the rest) run after
  # all of the model's own, wherever the `include` stands (Rails runs them
  # in declaration order, so a concern included first runs first).
  # @api public
  module Concern
    # A declaration only: `spin run gen` splices the block's lines into
    # each including class.
    # @return [nil]
    # @api public
    def included(base = nil, &block) = nil

    # A declaration only: `spin run gen` turns each `def` of the block into
    # a method of the concern and a forwarder in each including class.
    # @return [nil]
    # @api public
    def class_methods(&block) = nil

    # The declarations an `included` block may make, as no-ops on the
    # concern, with the parameters of Cybertrain::Controller's: Spinel
    # compiles the never-run block all the same and resolves its
    # implicit-self calls against the concern (spikes/NOTES.md rule 92).
    def before_action(name = nil, only: [], except: [], &block) = nil
    def after_action(name = nil, only: [], except: [], &block) = nil
    def skip_before_action(name, only: [], except: []) = nil
    def rate_limit(to:, within:, only: [], except: [], by: :client_ip, with: nil, if: nil, unless: nil, name: "",
                   store: :cache, redirect_to: "", alert: "") = nil
    def rescue_from(klass, with: nil, &block) = nil
    def helper_method(*names) = nil
    def layout(name = nil, only: [], except: []) = nil
    def content_security_policy(&block) = nil
  end
end
