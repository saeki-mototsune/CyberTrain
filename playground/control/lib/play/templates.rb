# frozen_string_literal: true

module Play
  # Every docker command line the control plane runs, as argv arrays (spec
  # §5.4). Pure functions: the only variable parts are the handle, the
  # session and preview ids, the subnet and the two times, all made by the
  # control plane, plus the operator's PLAY_* settings. No argument takes a
  # value from a visitor's request, and nothing goes through a shell.
  module Templates
    module_function

    def labels(handle, created, expires)
      ["--label", "cybertrain-play.role=session",
       "--label", "cybertrain-play.handle=#{handle}",
       "--label", "cybertrain-play.created-at=#{created}",
       "--label", "cybertrain-play.expires-at=#{expires}"]
    end

    # IPv6 off whatever the daemon's default-network-opts say: the router
    # turns sessions away by their IPv4 address. One element: `--ipv6 false`
    # would make "false" the network's name.
    def network_create(handle:, subnet:, created:, expires:)
      ["docker", "network", "create",
       "--driver", "bridge",
       "--internal",
       "--ipv6=false",
       "--subnet", subnet,
       "--opt", "com.docker.network.bridge.inhibit_ipv4=true",
       *labels(handle, created, expires),
       "ctplay-n-#{handle}"]
    end

    def network_connect(handle:, container:)
      ["docker", "network", "connect", "ctplay-n-#{handle}", container]
    end

    # The flags that confine a session (spec §5.4), in one place.
    # playground/web-smoke.sh runs its session with exactly these
    # (# BEGIN hardened run ... # END hardened run); test/drift_test.rb
    # compares the two.
    def hardening(config)
      ["--user", "1000:1000",
       "--cap-drop", "ALL",
       "--security-opt", "no-new-privileges",
       "--read-only",
       "--tmpfs", "/tmp:rw,exec,nosuid,nodev,size=#{config.tmpfs_tmp},mode=1777",
       "--tmpfs", "/home/dev:rw,nosuid,nodev,size=#{config.tmpfs_home},uid=1000,gid=1000,mode=0755",
       "--tmpfs", "/workspace:rw,exec,nosuid,nodev,size=#{config.tmpfs_workspace},uid=1000,gid=1000,mode=0755",
       "--tmpfs", "/opt/cybertrain-cache:rw,nosuid,nodev,size=#{config.tmpfs_cache},uid=1000,gid=1000,mode=0755",
       "--memory", config.session_memory, "--memory-swap", config.session_memory,
       "--cpus", config.session_cpus,
       "--pids-limit", config.session_pids.to_s]
    end

    def session_run(config, handle:, sid:, pid:, created:, expires:)
      argv = ["docker", "run",
              "--detach", "--rm", "--init",
              "--pull", "never",
              "--name", "ctplay-s-#{handle}",
              "--hostname", "playground",
              "--network", "ctplay-n-#{handle}",
              "--network-alias", "s-#{sid}",
              "--network-alias", "p-#{pid}",
              *labels(handle, created, expires),
              *hardening(config),
              "--log-driver", "json-file", "--log-opt", "max-size=1m", "--log-opt", "max-file=1"]
      argv += ["--runtime", config.runtime] unless config.runtime.empty?
      argv + ["--env", "VSCODE_PROXY_URI=#{config.proxy_uri(pid)}",
              "--env", "PLAYGROUND_ENDS_AT=#{expires}",
              "--env", "PLAYGROUND_IDLE_TIMEOUT=#{config.idle_timeout}",
              config.session_image]
    end

    def remove_container(handle:)
      ["docker", "rm", "--force", "ctplay-s-#{handle}"]
    end

    def network_containers(handle:)
      ["docker", "network", "inspect", "--format", "{{range $id, $c := .Containers}}{{$id}} {{end}}", "ctplay-n-#{handle}"]
    end

    def network_disconnect(handle:, container:)
      ["docker", "network", "disconnect", "--force", "ctplay-n-#{handle}", container]
    end

    def network_remove(handle:)
      ["docker", "network", "rm", "ctplay-n-#{handle}"]
    end

    def list_containers
      ["docker", "ps", "--all", "--no-trunc", "--filter", "label=cybertrain-play.role=session",
       "--format", "{{.ID}}\t{{.Names}}\t{{.State}}\t{{.Label \"cybertrain-play.handle\"}}\t" \
                   "{{.Label \"cybertrain-play.created-at\"}}\t{{.Label \"cybertrain-play.expires-at\"}}"]
    end

    def list_networks
      ["docker", "network", "ls", "--no-trunc", "--filter", "label=cybertrain-play.role=session",
       "--format", "{{.ID}}\t{{.Name}}\t{{.Label \"cybertrain-play.handle\"}}\t{{.Label \"cybertrain-play.created-at\"}}"]
    end

    def network_subnet(handle:)
      ["docker", "network", "inspect", "--format", "{{(index .IPAM.Config 0).Subnet}}", "ctplay-n-#{handle}"]
    end

    def list_routers(config)
      ["docker", "ps", *config.router_filters.flat_map { |f| ["--filter", f] },
       "--filter", "status=running", "--format", "{{.ID}}"]
    end

    def stats(names)
      ["docker", "stats", "--no-stream", "--format", "{{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}", *names]
    end

    def image_inspect(config)
      ["docker", "image", "inspect", "--format", "{{.Id}}", config.session_image]
    end

    def version
      ["docker", "version", "--format", "{{.Server.Version}}"]
    end
  end
end
