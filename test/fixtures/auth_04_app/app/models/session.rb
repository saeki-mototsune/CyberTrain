# One signed-in browser: a row the cookie session points at by id
# (ApplicationController#resume_session), with the address and user
# agent that created it, so a user can be signed out everywhere by
# deleting their rows. Columns, the Cybertrain::Model superclass and
# `user` (from the user_id foreign key) come from gen/models/session.rb.
#
# Not to be confused with Cybertrain::Session, the signed cookie that
# holds this row's id as `session[:session_id]`.
class Session
end
