deploy-website:
	cd website && bun install --frozen-lockfile
	cd website && bun run deploy

# Apalache's launcher hardcodes -Xmx4096m, which gets these runs OOM-killed on
# a loaded machine. A smaller heap is both survivable and markedly faster.
export JVM_ARGS := "-Xmx1800m"

# Model-check the claim/lease protocol, single-store mode (spec/08_CLAIMS.md)
formal-claims length="8":
	apalache-mc check --config=formal/ClaimsSafe.cfg --length={{length}} formal/ClaimLedger.tla

# Model-check federated mode (spec/08_CLAIMS.md SS9.3)
formal-federated length="7":
	apalache-mc check --config=formal/FedSafe.cfg --length={{length}} formal/ClaimFederated.tla

# Confirm every disabled federated requirement produces a counterexample
formal-federated-matrix length="8":
	#!/usr/bin/env bash
	set -euo pipefail
	for c in FedNoEstablish FedNoFF FedNoRevalidate FedUnsafeSteal; do
	  printf "%-22s " "$c"
	  apalache-mc check --config=formal/$c.cfg --length={{length}} formal/ClaimFederated.tla 2>&1 \
	    | grep -E "The outcome is" || true
	done

# Confirm every disabled requirement produces a MutualExclusion counterexample
formal-claims-matrix length="10":
	#!/usr/bin/env bash
	set -euo pipefail
	for c in MxNoCAS MxNoFencing MxNoDeltaAuth MxNoWatchdog MxNoSkewAsym MxSmallAllow; do
	  echo "== $c (expect: Error)"
	  apalache-mc check --config=formal/$c.cfg --length={{length}} formal/ClaimLedger.tla 2>&1 \
	    | grep -E 'The outcome is' || true
	done
