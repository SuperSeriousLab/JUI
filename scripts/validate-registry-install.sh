#!/usr/bin/env bash
# validate-registry-install.sh — prove eidos Julia registry install flow works
#
# Verified flow (2026-04-18):
#   1. JULIA_PKG_USE_CLI_GIT=true (bypasses Julia LibGit2 credential limitation)
#   2. Add General registry first (transitive deps: JSON3, StructTypes, etc.)
#   3. Add eidos registry
#   4. Pkg.add(["JUI", "FRANK"])
#
# Prerequisites:
#   - git credential helper configured for 192.168.14.77 (eidos dev box default)
#   - Julia 1.10+
#
# Without JULIA_PKG_USE_CLI_GIT, Julia's LibGit2 hangs on credential prompts
# because Forgejo's REQUIRE_SIGNIN_VIEW gates all repo access. The CLI git
# path uses the system credential helper (git-credential-eidos).

set -euo pipefail

REGISTRY_URL="http://192.168.14.77:3000/eidos/JuliaRegistry.git"
JULIA="${JULIA:-/home/js/.local/julia-1.11.5/bin/julia}"
TIMEOUT="${TIMEOUT:-600}"

echo -e "\e[1;34m=== eidos Julia Registry Install Validation ===\e[0m"
echo "Registry:    $REGISTRY_URL"
echo "Julia:       $JULIA"
echo "Timeout:     ${TIMEOUT}s"
echo "CLI git:     JULIA_PKG_USE_CLI_GIT=true (required)"
echo ""

run_scenario() {
    local name="$1"
    local script="$2"
    local tmpdir tmpdepot
    tmpdir=$(mktemp -d)
    tmpdepot=$(mktemp -d)

    echo -e "\e[1;34m[SCENARIO] $name\e[0m"
    echo "  depot: $tmpdepot"

    if (cd "$tmpdir" && timeout "$TIMEOUT" env \
            JULIA_DEPOT_PATH="$tmpdepot" \
            JULIA_PKG_USE_CLI_GIT=true \
            "$JULIA" --project=. -e "$script" < /dev/null); then
        echo -e "  \e[1;32m✓ PASS\e[0m"
        echo ""
        return 0
    else
        echo -e "  \e[1;31m✗ FAIL\e[0m"
        echo ""
        return 1
    fi
}

# Scenario 1: FRANK only
run_scenario "FRANK in clean env" "
using Pkg
Pkg.Registry.add(\"General\")
Pkg.Registry.add(Pkg.RegistrySpec(url=\"$REGISTRY_URL\"))
Pkg.add(\"FRANK\")
using FRANK
v = pkgversion(FRANK)
@assert v == v\"0.2.0\" \"expected FRANK v0.2.0, got \$v\"
e = FrankEmitter(io=devnull)
emit!(e, \"test\", FRANK.STATE_TRANSITION, Dict{String,Any}(\"k\"=>\"v\"))
println(\"FRANK v\$v installed + emission OK\")
"

# Scenario 2: JUI + FRANK (weak dep ext activation)
run_scenario "JUI + FRANK (extension activation)" "
using Pkg
Pkg.Registry.add(\"General\")
Pkg.Registry.add(Pkg.RegistrySpec(url=\"$REGISTRY_URL\"))
Pkg.add([\"JUI\", \"FRANK\"])
using JUI, FRANK
v_jui = pkgversion(JUI)
v_frank = pkgversion(FRANK)
@assert v_jui == v\"0.2.0\" \"expected JUI v0.2.0, got \$v_jui\"
@assert v_frank == v\"0.2.0\" \"expected FRANK v0.2.0, got \$v_frank\"
ext = Base.get_extension(JUI, :JUIFRANKExt)
@assert ext !== nothing \"JUIFRANKExt did NOT activate\"
println(\"JUI v\$v_jui + FRANK v\$v_frank installed, ext activated\")
"

# Scenario 3: JUI solo (FRANK absent — zero-overhead path)
run_scenario "JUI solo (FRANK-absent path)" "
using Pkg
Pkg.Registry.add(\"General\")
Pkg.Registry.add(Pkg.RegistrySpec(url=\"$REGISTRY_URL\"))
Pkg.add(\"JUI\")
using JUI
v = pkgversion(JUI)
@assert v == v\"0.2.0\" \"expected JUI v0.2.0, got \$v\"
@assert !isdefined(Main, :FRANK) \"FRANK should not auto-load\"
ext = Base.get_extension(JUI, :JUIFRANKExt)
@assert ext === nothing \"JUIFRANKExt should be nothing when FRANK absent\"
buf = JUI.Buffer(JUI.Rect(1,1,10,5))
@assert length(buf.content) == 50
println(\"JUI v\$v solo install OK, ext correctly absent\")
"

echo -e "\e[1;32m=== All scenarios passed ===\e[0m"
