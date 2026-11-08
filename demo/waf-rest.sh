#!/bin/bash
# waf-rest.sh <command> [args]: Advanced WAF (ASM) helpers for part 16, run ON a BIG-IP as admin (f5fn.sh: `waf <command>` sends this
# script to the active unit's bash). Everything goes through the unit's own iControl REST on localhost:8100 (no password on the
# loopback for admin) and jq. POLICY (default waf-app) names the security policy.
#   templates          the policy templates this version ships (name and title)
#   info               the policy's enforcement mode, template, and how many attack signatures are staged / enforced
#   enforce            takes every staged signature out of staging (performStaging false), then applies the policy
#   mode <transparent|blocking>   sets the enforcement mode, then applies the policy
#   apply              applies the policy (pushes the edited policy to the traffic-handling bd daemon) and waits for the task
#   log [n]            the last n requests with something to say (staged or real violations, or blocked), newest last
#                      (illegal ones found by a server-side filter, staged-only ones among the newest 300):
#                      time, status, support ID, request line, then each violation: name, signature (ID), staged or not, where
#   event <support-id> one request in full: request headers and every violation
#   override <parameter> <signature-id>   adds parameter <parameter> to the policy (wildcard-free, any location) with that one
#                      signature disabled on it, then applies: the narrow fix for a false positive
#   params             the policy's explicit parameters and their signature overrides
#   import <file>      imports a declarative policy file already on the unit (f5fn.sh `wafimport` copies it there): creates the
#                      policy, or replaces it if one with that name exists; waits for the import task and prints its result
#   urls               the policy's URL entities (method, path, explicit / wildcard) and its allowed methods
P=${POLICY:-waf-app}; R=http://localhost:8100/mgmt/tm/asm
c() { curl -s -u admin: -H 'Content-Type: application/json' "$@"; }
pid() { c "$R/policies?\$filter=name+eq+$P&\$select=id" | jq -r '.items[0].id'; }
apply() {
  local id t s; id=$(pid)
  t=$(c -X POST "$R/tasks/apply-policy" -d "{\"policyReference\":{\"link\":\"https://localhost/mgmt/tm/asm/policies/$id\"}}" | jq -r .id)
  for i in $(seq 1 180); do s=$(c "$R/tasks/apply-policy/$t" | jq -r .status); [ "$s" = COMPLETED ] || [ "$s" = FAILURE ] && break; sleep 1; done
  echo "apply $P: $s"
}
case "$1" in
  templates)
    c "$R/policy-templates?\$select=name,title" | jq -r '.items[] | "\(.name)   \(.title)"' | head -${2:-12} ;;
  info)
    id=$(pid)
    ss=$(c "$R/policies/$id/signature-settings" | jq -r 'if .signatureStaging then "on" else "OFF (no signature is staged, whatever its own flag)" end')
    c "$R/policies/$id" | jq -r --arg ss "$ss" '"policy \(.name): enforcement \(.enforcementMode), template \(.templateReference.title // "-"), signature staging (policy-wide): \($ss)"'
    st=$(c "$R/policies/$id/signatures?\$filter=performStaging+eq+true&\$top=1" | jq .totalItems)
    all=$(c "$R/policies/$id/signatures?\$top=1" | jq .totalItems)
    echo "attack signatures: $all in the policy, $st flagged for staging, $((all - st)) not"
    c "$R/policies/$id/signature-sets" | jq -r '.items[] | "  set: \(.signatureSetReference.name)  alarm \(.alarm) block \(.block)"' ;;
  enforce)
    id=$(pid)
    c -X PATCH "$R/policies/$id/signatures?\$filter=performStaging+eq+true" -d '{"performStaging":false}' >/dev/null
    echo "staged signatures now: $(c "$R/policies/$id/signatures?\$filter=performStaging+eq+true&\$top=1" | jq .totalItems)"; apply ;;
  mode)
    id=$(pid); c -X PATCH "$R/policies/$id" -d "{\"enforcementMode\":\"$2\"}" | jq -r '"enforcement mode: \(.enforcementMode)"'; apply ;;
  apply) apply ;;
  log)
    { c "$R/events/requests?\$top=50&\$filter=requestStatus+ne+legal&\$orderby=requestDatetime+desc"
      c "$R/events/requests?\$top=300&\$orderby=requestDatetime+desc"; } | jq -rs --argjson n "${2:-5}" '
      [.[].items[]? | select(.enforcementState.hasViolations or .enforcementState.hasStagingViolations or .enforcementState.isBlocked)]
      | unique_by(.id) | sort_by(.requestDatetime, .id) | .[-$n:] | .[]
      | "\(.requestDatetime[11:19])  \(.requestStatus)  support ID \(.id)  \(.virtualServerName | split("/")[-1])\n  \(.rawRequest.httpRequest | split("\r\n")[0])",
        (.violations[]? | "    \(.violationReference.name)  \(.signatureReference.name // "") \(if .signatureReference then "(\(.signatureReference.signatureId))" else "" end)  \(if .signatureStaging then "STAGED" else "enforced" end)  \(.observedEntity.name // "") = \(.observedEntity.value // "" | .[0:40])\(if .validationError then "  [\(.validationError) at \(.observedEntity.jsonTag // "")\(if .observedEntity.propertyName then " property \(.observedEntity.propertyName)" else "" end)\(if .expectedValue then ", expected \(.expectedValue), got \(.actualValue)" else "" end)]" else "" end)")' ;;
  event)
    c "$R/events/requests/$2" | jq -r '"support ID \(.id)  \(.requestStatus)  \(.virtualServerName)  client \(.clientIp)  rating \(.enforcementState.rating)",
      (.rawRequest.httpRequest | split("\r\n") | map(select(length > 0)) | .[] | "  | \(.)"),
      (.violations[]? | "  \(.violationReference.name)  \(.signatureReference.name // "")  staged=\(.signatureStaging // false)")' ;;
  override)
    id=$(pid)
    sl=$(c "$R/signatures?\$filter=signatureId+eq+$3&\$select=id" | jq -r '.items[0].id')
    c -X POST "$R/policies/$id/parameters" -d "{\"name\":\"$2\",\"type\":\"explicit\",\"parameterLocation\":\"any\",\"valueType\":\"user-input\",\"attackSignaturesCheck\":true,\"signatureOverrides\":[{\"signatureReference\":{\"link\":\"https://localhost/mgmt/tm/asm/signatures/$sl\"},\"enabled\":false}]}" \
      | jq -r '"parameter \(.name): signature check \(.attackSignaturesCheck), overrides \([.signatureOverrides[]? | "\(.signatureReference.name) (\(.signatureReference.signatureId)) enabled=\(.enabled)"] | join(", "))"'
    apply ;;
  params)
    c "$R/policies/$(pid)/parameters" | jq -r '.items[] | "parameter \(.name) (\(.type)): signature check \(.attackSignaturesCheck), overrides \([.signatureOverrides[]? | "\(.signatureReference.name) (\(.signatureReference.signatureId)) enabled=\(.enabled)"] | join(", "))"' ;;
  import)
    body=$(python3 -c 'import json,sys; f=open(sys.argv[1]).read(); n=json.loads(f)["policy"]["name"]; print(json.dumps({"file": f, "isBase64": False, "policy": {"fullPath": "/Common/" + n}}))' "$2")
    t=$(c -X POST "$R/tasks/import-policy" -d "$body" | jq -r .id); s=""
    for i in $(seq 1 90); do s=$(c "$R/tasks/import-policy/$t" | jq -r .status); [ "$s" = COMPLETED ] || [ "$s" = FAILURE ] && break; sleep 2; done
    c "$R/tasks/import-policy/$t" | jq -r '"import: \(.status): \(.result.message // .result)"' ;;
  urls)
    id=$(pid)
    c "$R/policies/$id/urls" | jq -r '.items[] | "  \(.method) \(.name)  (\(.type))"'
    echo "  allowed methods: $(c "$R/policies/$id/methods" | jq -r '[.items[].name] | join(" ")')" ;;
  *) sed -n '2,24p' "$0"; exit 1 ;;
esac
