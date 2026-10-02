# playground/control/Dockerfile -- the hosted playground's control plane (SP2).
# Kamal builds it (playground/deploy/control.yml); playground/dev/compose.yml
# runs it locally. It talks to the host's Docker through the mounted socket.
FROM ruby:4.0.7-slim
# build-essential: puma's native extension. The docker CLI is the static
# binary of the official cli image; the daemon is the host's.
RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential \
 && rm -rf /var/lib/apt/lists/*
COPY --from=docker:28-cli /usr/local/bin/docker /usr/local/bin/docker
ENV RACK_ENV=production BUNDLE_DEPLOYMENT=1 BUNDLE_WITHOUT=test
WORKDIR /app
COPY playground/control/Gemfile playground/control/Gemfile.lock ./
RUN bundle install
COPY playground/control/ ./
EXPOSE 9292
HEALTHCHECK --interval=10s --timeout=3s --start-period=10s \
  CMD ["ruby", "-rnet/http", "-e", "exit(Net::HTTP.get_response(URI('http://127.0.0.1:9292/up')).code == '200' ? 0 : 1)"]
# Single-mode puma: the limits and the session records live in this process.
CMD ["bundle", "exec", "puma", "-p", "9292", "-t", "4:16"]
