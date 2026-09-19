# ───────────────────────────────────────────────────────────────────────────
#  Shared helper — sourced, never executed.
#
#  Lives on its own so the two places that need a friendly model label agree:
#  config/start.sh (the launch-time label cached in @concierge_model) and
#  config/status-model.sh (the live label the status bar re-reads every tick).
# ───────────────────────────────────────────────────────────────────────────

# Turn a model id into a friendly status-bar label:
#   claude-fable-5          -> fable 5
#   claude-opus-4-8         -> opus 4.8
#   claude-haiku-4-5-2025.. -> haiku 4.5   (trailing date snapshot dropped)
pretty_model() {
  local id="${1#claude-}"                    # drop the claude- prefix
  id="$(printf '%s' "$id" | sed -E 's/-[0-9]{8}$//')"  # drop -YYYYMMDD snapshot
  local family="${id%%-*}"                    # first token is the family
  local rest="${id#"$family"}"                # remaining -x-y version tokens
  rest="${rest#-}"                            # trim leading dash
  if [ -n "$rest" ]; then
    printf '%s %s' "$family" "$(printf '%s' "$rest" | tr '-' '.')"
  else
    printf '%s' "$family"
  fi
}
