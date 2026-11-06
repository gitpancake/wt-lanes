#!/usr/bin/env bash
# Builds lane prompts from the fragments in share/prompts/. A fragment is one
# rule, written once. {{include:<name>}} pulls in another fragment, {{KEY}} is
# replaced from a KEY=value argument or from lane.config. Newlines collapse to
# spaces because a kickoff prompt travels as one argument.

WT_SHARE_DIR=${WT_SHARE_DIR:-$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")}
source "$WT_SHARE_DIR/lane.config"

ctx_display() {
  local tier display=""
  for tier in $1; do display+="${display:+/}$((tier / 1000))K"; done
  printf '%s' "$display"
}

lane_config_pairs() {
  local postTiers=($LANE_CTX_POST_PR_TIERS)
  printf '%s\n' \
    "CTX_PRE_PR=$(ctx_display "$LANE_CTX_PRE_PR_TIERS")" \
    "CTX_POST_PR=$(ctx_display "$LANE_CTX_POST_PR_TIERS")" \
    "CTX_POST_PR_HANDOFF=$(ctx_display "${postTiers[${#postTiers[@]}-1]}")" \
    "CTX_WINDOW=$(ctx_display "$LANE_CTX_WINDOW")" \
    "GATE_TIMEOUT_MS=$LANE_GATE_TIMEOUT_MS"
}

render_prompt() {
  local fragmentName=$1
  shift
  local text includeName pair key
  text=$(<"$WT_SHARE_DIR/prompts/$fragmentName.md")
  text=${text//$'\n'/ }
  while [[ "$text" =~ \{\{include:([a-z0-9-]+)\}\} ]]; do
    includeName=${BASH_REMATCH[1]}
    text=${text//"{{include:$includeName}}"/"$(render_prompt "$includeName" "$@")"}
  done
  while IFS= read -r pair; do
    key=${pair%%=*}
    text=${text//"{{$key}}"/"${pair#*=}"}
  done < <(printf '%s\n' "$@"; lane_config_pairs)
  printf '%s' "$text"
}
