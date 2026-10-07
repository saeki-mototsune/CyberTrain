# /etc/profile.d/cybertrain-playground.sh -- installed by playground/Dockerfile.
# The toolchain lives under /opt, so the home directory holds nothing the
# prebuilt app needs (playground/README.md).
export CYBERTRAIN_HOME=/opt/cybertrain
export XDG_CACHE_HOME=/opt/cybertrain-cache
case ":${PATH}:" in
  *:/opt/cybertrain/bin:*) ;;
  *) PATH="/opt/cybertrain/bin:${PATH}"; export PATH ;;
esac
