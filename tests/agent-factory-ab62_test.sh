#!/usr/bin/env bash
# Acceptance tests for agent-factory-ab62: team-lead releases its claim (`bd unclaim`) after routing
# an issue to another role's queue. One function per acceptance criterion in
# docs/stories/agent-factory-ab62.md (test_acN_...).
#
# The behaviour under test is team-lead's documented procedure (agents/team-lead.md), which an LLM
# follows - there is no code path to run - so every check is a prose check on that file, scoped to
# the section that governs the scenario in each criterion:
#   - routing/rerouting of needs-team-lead and no-role:* issues: steps 1-5 + the Sweep section
#   - stage-chain building: the "Size a new story's chain" section
#   - the escalate (needs-human) path: step 4
# Written from the story's acceptance criteria only - not from docs/design/agent-factory-ab62.md.
#
# Run directly: bash tests/agent-factory-ab62_test.sh
set -uo pipefail

KIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$KIT_DIR"
DOC="agents/team-lead.md"
PASS=0; FAIL=0
pass() { PASS=$((PASS + 1)); echo "PASS: $1"; }
fail() { FAIL=$((FAIL + 1)); echo "FAIL: $1"; }

# section <heading-regex>: print from the matching "## " heading up to the next "## " heading.
section() { awk -v re="$1" '/^## /{p = ($0 ~ re)} p' "$DOC"; }
# preamble: everything before the first "## " heading (includes numbered steps 1-5).
preamble() { awk '/^## /{exit} {print}' "$DOC"; }
# step <n>: the numbered step n of the preamble (until the next numbered step).
step() { preamble | awk -v n="$1" '$0 ~ "^"n"\\. "{p=1; print; next} /^[0-9]+\\. /{p=0} p'; }

UNCLAIM='bd unclaim'

[ -f "$DOC" ] || { echo "FAIL: $DOC missing"; exit 1; }

# ============================================================
# AC1 - after routing an issue to a role queue, team-lead unclaims it (no assignee, open, ready).
# ============================================================

test_ac1_reroute_step_says_bd_unclaim() {
  local s; s="$(step 3)"
  if grep -q "$UNCLAIM" <<<"$s"; then pass "AC1: step 3 (act on diagnosis / reroute) names 'bd unclaim'"
  else fail "AC1: step 3 (act on diagnosis / reroute) never mentions 'bd unclaim'"; fi
}

test_ac1_sweep_route_to_po_says_bd_unclaim() {
  local s; s="$(section '^## Sweep')"
  if grep -q "$UNCLAIM" <<<"$s"; then pass "AC1: sweep section (no-role:* issue routed to po) names 'bd unclaim'"
  else fail "AC1: sweep section (no-role:* issue routed to po) never mentions 'bd unclaim'"; fi
}

test_ac1_unclaim_happens_after_routing_labels() {
  # The unclaim must be described as coming after the routing (label change), not before it.
  local s; s="$(step 3)"
  local l_label l_unclaim
  l_label=$(grep -n -m1 -E 'role:<?[A-Za-z]|--add-label|label add' <<<"$s" | cut -d: -f1)
  l_unclaim=$(grep -n -m1 "$UNCLAIM" <<<"$s" | cut -d: -f1)
  if [ -n "$l_label" ] && [ -n "$l_unclaim" ] && [ "$l_unclaim" -ge "$l_label" ]; then
    pass "AC1: step 3 places 'bd unclaim' after the routing/label instructions"
  else
    fail "AC1: step 3 does not place 'bd unclaim' after the routing instructions (label line=${l_label:-none}, unclaim line=${l_unclaim:-none})"
  fi
}

test_ac1_result_state_open_and_unassigned_is_stated() {
  # The doc should say why: the issue must end up unassigned/open so the next role's bd ready sees it.
  if grep -qiE 'bd ready' <<<"$(grep -iE -B3 -A3 "$UNCLAIM" "$DOC")"; then
    pass "AC1: text around 'bd unclaim' explains the target role's bd ready picks the issue up"
  else
    fail "AC1: text around 'bd unclaim' does not mention the next role's bd ready / pickup"
  fi
}

# ============================================================
# AC2 - rerouting a needs-team-lead issue back to its owning role is unclaimed the same way.
# ============================================================

test_ac2_needs_team_lead_reroute_path_covers_unclaim() {
  # Step 3's Reroute / Fix-directly / "Either way" wrap-up applies to needs-team-lead issues (steps 1-5);
  # the unclaim must be inside step 3, and be tied to the needs-team-lead reroute, not only sweep.
  local s; s="$(step 3)"
  if grep -q "$UNCLAIM" <<<"$s" && grep -q 'needs-team-lead' <<<"$s"; then
    pass "AC2: step 3 covers needs-team-lead removal and 'bd unclaim'"
  else
    fail "AC2: step 3 must cover both needs-team-lead removal and 'bd unclaim'"
  fi
}

test_ac2_unclaim_applies_to_fix_directly_too() {
  # "Fix directly" also hands the issue back to its role, so the unclaim should sit in the shared
  # "Either way" wrap-up (or otherwise be stated for both reroute and fix-directly).
  local s; s="$(step 3)"
  local either_line unclaim_line
  either_line=$(grep -n -m1 'Either way' <<<"$s" | cut -d: -f1)
  unclaim_line=$(grep -n -m1 "$UNCLAIM" <<<"$s" | cut -d: -f1)
  if [ -n "$either_line" ] && [ -n "$unclaim_line" ] && [ "$unclaim_line" -ge "$either_line" ]; then
    pass "AC2: 'bd unclaim' is part of step 3's shared 'Either way' wrap-up"
  elif grep -qiE 'fix directly' <<<"$s" && [ -n "$unclaim_line" ] && \
       grep -B4 "$UNCLAIM" <<<"$s" | grep -qiE 'fix directly|either'; then
    pass "AC2: 'bd unclaim' is stated to apply to fix-directly as well"
  else
    fail "AC2: 'bd unclaim' is not stated to apply to both reroute and fix-directly outcomes"
  fi
}

test_ac2_sweep_with_story_label_inherits_unclaim() {
  # The sweep's story:<id> branch delegates to steps 1-5, so it inherits the unclaim - but only if
  # its "skip that part of step 3" carve-out doesn't skip the unclaim. It must not say to skip unclaim.
  local s; s="$(section '^## Sweep')"
  if grep -qiE "skip[^.]*unclaim" <<<"$s"; then
    fail "AC2: sweep section tells team-lead to skip the unclaim for story-labelled issues"
  else
    pass "AC2: sweep section does not exempt story-labelled issues from the unclaim"
  fi
}

# ============================================================
# AC3 - after building a stage chain, team-lead's own claimed issue (e.g. the needs-chain sizing issue,
# if left open) is not left claimed.
# ============================================================

test_ac3_size_chain_section_mentions_unclaim() {
  local s; s="$(section '^## Size a new story')"
  if grep -q "$UNCLAIM" <<<"$s"; then pass "AC3: 'Size a new story's chain' section names 'bd unclaim'"
  else fail "AC3: 'Size a new story's chain' section never mentions 'bd unclaim'"; fi
}

test_ac3_unclaim_is_conditional_on_issue_left_open() {
  # The sizing issue is normally closed; the unclaim is required only if it is left open/claimed.
  local s; s="$(section '^## Size a new story')"
  if grep -B3 -A3 "$UNCLAIM" <<<"$s" | grep -qiE 'open|not (closed|close)|left|otherwise|if '; then
    pass "AC3: chain-section unclaim is tied to the issue being left open"
  else
    fail "AC3: chain-section unclaim is not tied to the sizing issue being left open"
  fi
}

# ============================================================
# AC4 - issues team-lead keeps (needs-human escalation) or closes need no extra unclaim; the rule
# applies only to issues handed on to another role's queue.
# ============================================================

test_ac4_escalation_step_does_not_require_unclaim() {
  local s; s="$(step 4)"
  if [ -z "$s" ]; then fail "AC4: could not locate step 4 (escalate) in $DOC"; return; fi
  if grep -q "$UNCLAIM" <<<"$s" && ! grep -qiE "(no|not|never|without|except|neither)[^.]{0,80}$UNCLAIM|$UNCLAIM[^.]{0,80}(not|unnecessary|n't)" <<<"$s"; then
    fail "AC4: step 4 (needs-human escalation) tells team-lead to run 'bd unclaim'"
  else
    pass "AC4: step 4 (needs-human escalation) does not require 'bd unclaim'"
  fi
}

test_ac4_rule_scoped_to_handed_on_issues() {
  # The doc must say the unclaim applies only when the issue is handed on to another role.
  local ctx; ctx="$(grep -iE -B4 -A4 "$UNCLAIM" "$DOC")"
  if grep -qiE 'only|handed|hand(ed)? (it )?(on|off|to)|next role|another role|target role' <<<"$ctx" \
     && grep -qiE 'needs-human|escalat|closed|keep' <<<"$ctx"; then
    pass "AC4: unclaim rule is scoped to handed-on issues and contrasts with kept/escalated/closed ones"
  else
    fail "AC4: unclaim rule is not scoped to handed-on issues (no contrast with needs-human/closed/kept)"
  fi
}

test_ac4_needs_human_never_paired_with_unclaim_instruction() {
  # No line pairs 'needs-human' with an instruction to unclaim as a requirement.
  if grep -iE "needs-human" "$DOC" | grep -iE "$UNCLAIM" | grep -viE "(not|no|n't|never|without|except|only)" | grep -q .; then
    fail "AC4: a line requires 'bd unclaim' together with needs-human"
  else
    pass "AC4: no line requires 'bd unclaim' together with needs-human"
  fi
}

# ============================================================
# AC5 - agents/team-lead.md states explicitly that team-lead must run `bd unclaim <id>` after routing.
# ============================================================

test_ac5_doc_contains_bd_unclaim_id_literal() {
  if grep -qE 'bd unclaim (<[^>]+>|\$?[A-Za-z_-]+)' "$DOC"; then
    pass "AC5: $DOC contains a literal 'bd unclaim <id>' instruction"
  else
    fail "AC5: $DOC has no literal 'bd unclaim <id>' instruction"
  fi
}

test_ac5_instruction_is_mandatory_wording() {
  if grep -iE -B2 -A2 "$UNCLAIM" "$DOC" | grep -qE '\b(must|MUST|always|Always|required|Run|run)\b'; then
    pass "AC5: 'bd unclaim' is phrased as a required action (must/always/run)"
  else
    fail "AC5: 'bd unclaim' is not phrased as a required action"
  fi
}

test_ac5_instruction_says_next_role_can_pick_up() {
  if grep -iE -B3 -A3 "$UNCLAIM" "$DOC" | grep -qiE 'pick (it|the issue) up|picks? (it|the issue) up|next role|target role|bd ready'; then
    pass "AC5: doc states the purpose - so the next role can pick the issue up"
  else
    fail "AC5: doc does not state that the unclaim lets the next role pick the issue up"
  fi
}

test_ac5_no_ambiguity_only_in_code_fence_or_comment() {
  # Guard against the instruction being hidden in an HTML comment.
  if awk '/<!--/{c=1} c&&/bd unclaim/{f=1} /-->/{c=0} END{exit !f}' "$DOC"; then
    fail "AC5: 'bd unclaim' appears inside an HTML comment"
  else
    pass "AC5: 'bd unclaim' is not hidden in an HTML comment"
  fi
}

# ---- run all ----
for t in $(declare -F | awk '{print $3}' | grep '^test_ac'); do "$t"; done
echo
echo "Result: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
