# /etc/profile.d/cybertrain-playground.sh -- installed by playground/Dockerfile.
# The toolchain lives under /opt, so the home directory holds nothing the
# prebuilt app needs (playground/README.md).
export CYBERTRAIN_HOME=/opt/cybertrain
export XDG_CACHE_HOME=/opt/cybertrain-cache
case ":${PATH}:" in
  *:/opt/cybertrain/bin:*) ;;
  *) PATH="/opt/cybertrain/bin:${PATH}"; export PATH ;;
esac
# In a GitHub Codespace the editor's preview is an iframe inside a webview on
# another site (vscode-cdn.net): a SameSite=Lax session cookie is dropped
# there and every form POST gets 403. Codespaces sets CODESPACES=true.
# Defaults only: a value already set (for a test) wins.
if [ "${CODESPACES:-}" = "true" ]; then
  export CYBERTRAIN_SESSION_SAME_SITE="${CYBERTRAIN_SESSION_SAME_SITE:-None}"
  export CYBERTRAIN_SESSION_PARTITIONED="${CYBERTRAIN_SESSION_PARTITIONED:-1}"
fi
