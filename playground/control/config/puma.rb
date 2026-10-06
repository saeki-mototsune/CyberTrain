# frozen_string_literal: true

# Puma for the control plane: playground/control/Dockerfile runs
# `bundle exec puma -C config/puma.rb`. Single mode (no workers): the limits
# and the session records live in this one process. Creations queue on one
# lock, so the thread count also bounds how many requests can wait.
port 9292
threads 4, 16

# No route takes a request body (lib/play/guard.rb answers 413 to one).
# Puma itself refuses a declared body larger than this, without reading it;
# a chunked body it decodes first (unless more than this arrives with the
# headers), and the guard then refuses it.
http_content_length_limit 4096
