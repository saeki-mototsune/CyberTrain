module ApplicationCable
  class Connection < ActionCable::Connection::Base
    identified_by :current_user

    # Visitors too: examples/blog streams an article's new comments to
    # anyone reading it, signed in or not.
    def connect
      set_current_user
    end

    private
      def set_current_user
        if session = Session.find_by(id: cookies.signed[:session_id])
          self.current_user = session.user
        end
      end
  end
end
