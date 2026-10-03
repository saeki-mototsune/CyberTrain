# frozen_string_literal: true

require_relative "test_helper"

class TemplatesTest < Minitest::Test
  include PlayTestHelpers

  H = "1f2e3d4c5b6a7980"
  SID = "0123456789abcdef0123456789abcdef"
  PID = "fedcba9876543210fedcba9876543210"

  def run_argv(env = {})
    Play::Templates.session_run(play_config(env), handle: H, sid: SID, pid: PID, created: 1_800_000_000,
                                                  expires: 1_800_001_800)
  end

  def test_network_create_is_the_spec_argv
    assert_equal ["docker", "network", "create", "--driver", "bridge", "--internal", "--ipv6=false",
                  "--subnet", "10.250.0.16/28", "--opt", "com.docker.network.bridge.inhibit_ipv4=true",
                  "--label", "cybertrain-play.role=session", "--label", "cybertrain-play.handle=#{H}",
                  "--label", "cybertrain-play.created-at=1800000000", "--label", "cybertrain-play.expires-at=1800001800",
                  "ctplay-n-#{H}"],
                 Play::Templates.network_create(handle: H, subnet: "10.250.0.16/28", created: 1_800_000_000,
                                                expires: 1_800_001_800)
  end

  def test_session_run_is_the_spec_argv
    assert_equal ["docker", "run", "--detach", "--rm", "--init", "--pull", "never",
                  "--name", "ctplay-s-#{H}", "--hostname", "playground", "--network", "ctplay-n-#{H}",
                  "--network-alias", "s-#{SID}", "--network-alias", "p-#{PID}",
                  "--label", "cybertrain-play.role=session", "--label", "cybertrain-play.handle=#{H}",
                  "--label", "cybertrain-play.created-at=1800000000", "--label", "cybertrain-play.expires-at=1800001800",
                  "--user", "1000:1000", "--cap-drop", "ALL", "--security-opt", "no-new-privileges", "--read-only",
                  "--tmpfs", "/tmp:rw,exec,nosuid,nodev,size=256m,mode=1777",
                  "--tmpfs", "/home/dev:rw,nosuid,nodev,size=128m,uid=1000,gid=1000,mode=0755",
                  "--tmpfs", "/workspace:rw,exec,nosuid,nodev,size=256m,uid=1000,gid=1000,mode=0755",
                  "--tmpfs", "/opt/cybertrain-cache:rw,nosuid,nodev,size=64m,uid=1000,gid=1000,mode=0755",
                  "--memory", "1536m", "--memory-swap", "1536m", "--cpus", "1", "--pids-limit", "512",
                  "--log-driver", "json-file", "--log-opt", "max-size=1m", "--log-opt", "max-file=1",
                  "--env", "VSCODE_PROXY_URI=https://{{port}}-#{PID}.play.example.test",
                  "--env", "PLAYGROUND_ENDS_AT=1800001800", "--env", "PLAYGROUND_IDLE_TIMEOUT=300",
                  "ghcr.io/example/cybertrain-playground-web@sha256:0123"],
                 run_argv
  end

  def test_session_run_never_carries_a_forbidden_flag
    argv = run_argv("PLAY_RUNTIME" => "runsc")
    forbidden = ["--privileged", "--cap-add", "-v", "--volume", "--mount", "-p", "--publish", "--publish-all", "-P",
                 "--pid", "--ipc", "--device", "--restart", "--userns", "--uts", "--network=host"]
    assert_empty argv & forbidden
    refute_includes argv.each_cons(2).to_a, ["--network", "host"]
    refute(argv.any? { |a| a.include?("seccomp=unconfined") || a.include?("apparmor=unconfined") })
    refute(argv.any? { |a| a.start_with?("--pid=", "--ipc=", "--privileged=") })
  end

  def test_runtime_only_when_set
    refute_includes run_argv, "--runtime"
    argv = run_argv("PLAY_RUNTIME" => "runsc")
    assert_equal "runsc", argv[argv.index("--runtime") + 1]
    assert_operator argv.index("--runtime"), :<, argv.index("--env")
  end

  def test_numbers_come_from_the_settings
    argv = run_argv("PLAY_SESSION_MEMORY" => "2g", "PLAY_SESSION_CPUS" => "0.5", "PLAY_SESSION_PIDS" => "256",
                    "PLAY_TMPFS_TMP" => "128m", "PLAY_TMPFS_HOME" => "64m", "PLAY_TMPFS_WORKSPACE" => "512m",
                    "PLAY_TMPFS_CACHE" => "32m", "PLAY_IDLE_TIMEOUT" => "600")
    assert_equal %w[2g 2g], [argv[argv.index("--memory") + 1], argv[argv.index("--memory-swap") + 1]]
    assert_equal "0.5", argv[argv.index("--cpus") + 1]
    assert_equal "256", argv[argv.index("--pids-limit") + 1]
    tmpfs = argv.each_cons(2).select { |flag, _| flag == "--tmpfs" }.map(&:last)
    assert_equal %w[size=128m size=64m size=512m size=32m], tmpfs.map { |t| t[/size=\w+/] }
    assert_includes argv, "PLAYGROUND_IDLE_TIMEOUT=600"
  end

  def test_a_local_public_url_keeps_its_port_in_the_proxy_uri
    argv = run_argv("PLAY_PUBLIC_URL" => "http://play.localhost:8080")
    assert_includes argv, "VSCODE_PROXY_URI=http://{{port}}-#{PID}.play.localhost:8080"
  end

  def test_teardown_and_listing_argvs
    assert_equal ["docker", "rm", "--force", "ctplay-s-#{H}"], Play::Templates.remove_container(handle: H)
    assert_equal ["docker", "network", "inspect", "--format", "{{range $id, $c := .Containers}}{{$id}} {{end}}",
                  "ctplay-n-#{H}"], Play::Templates.network_containers(handle: H)
    assert_equal ["docker", "network", "disconnect", "--force", "ctplay-n-#{H}", "abc123"],
                 Play::Templates.network_disconnect(handle: H, container: "abc123")
    assert_equal ["docker", "network", "rm", "ctplay-n-#{H}"], Play::Templates.network_remove(handle: H)
    assert_equal ["docker", "network", "connect", "ctplay-n-#{H}", "abc123"],
                 Play::Templates.network_connect(handle: H, container: "abc123")
    assert_equal ["docker", "ps", "--all", "--no-trunc", "--filter", "label=cybertrain-play.role=session", "--format",
                  "{{.ID}}\t{{.Names}}\t{{.State}}\t{{.Label \"cybertrain-play.handle\"}}\t" \
                  "{{.Label \"cybertrain-play.created-at\"}}\t{{.Label \"cybertrain-play.expires-at\"}}"],
                 Play::Templates.list_containers
    assert_equal ["docker", "network", "ls", "--no-trunc", "--filter", "label=cybertrain-play.role=session", "--format",
                  "{{.ID}}\t{{.Name}}\t{{.Label \"cybertrain-play.handle\"}}\t{{.Label \"cybertrain-play.created-at\"}}"],
                 Play::Templates.list_networks
    assert_equal ["docker", "network", "inspect", "--format", "{{(index .IPAM.Config 0).Subnet}}", "ctplay-n-#{H}"],
                 Play::Templates.network_subnet(handle: H)
    assert_equal ["docker", "ps", "--filter", "label=service=cybertrain-play-router", "--filter", "label=role=web",
                  "--filter", "status=running", "--format", "{{.ID}}"], Play::Templates.list_routers(play_config)
    assert_equal ["docker", "stats", "--no-stream", "--format", "{{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}",
                  "ctplay-s-a", "ctplay-s-b"], Play::Templates.stats(%w[ctplay-s-a ctplay-s-b])
    assert_equal ["docker", "image", "inspect", "--format", "{{.Id}}",
                  "ghcr.io/example/cybertrain-playground-web@sha256:0123"], Play::Templates.image_inspect(play_config)
    assert_equal ["docker", "version", "--format", "{{.Server.Version}}"], Play::Templates.version
  end
end
