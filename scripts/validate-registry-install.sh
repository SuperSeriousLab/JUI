#!/usr/bin/env bash
set -euo pipefail

REGISTRY_URL="http://192.168.14.77:3000/eidos/JuliaRegistry.git"
JULIA="/home/js/.local/julia-1.11.5/bin/julia"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Export git environment variables to avoid prompts
export GIT_TERMINAL_PROMPT=0

# Color output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Global tracking
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0

# Helper: run in isolated depot and project
run_isolated() {
    local tmpdir=$(mktemp -d)
    local tmpdepot=$(mktemp -d)
    local julia_code="$1"

    cd "$tmpdir"
    # Redirect stdin from /dev/null to prevent interactive prompts
    JULIA_DEPOT_PATH="$tmpdepot" "$JULIA" --project=. -e "$julia_code" < /dev/null
    local exit_code=$?

    cd / && rm -rf "$tmpdir" "$tmpdepot"
    return $exit_code
}

# Helper: test result tracking
test_result() {
    local name="$1"
    local result="$2"  # "PASS", "FAIL", or "SKIP"

    case "$result" in
        PASS)
            echo -e "${GREEN}✓ PASS${NC} $name"
            ((PASS_COUNT++))
            ;;
        FAIL)
            echo -e "${RED}✗ FAIL${NC} $name"
            ((FAIL_COUNT++))
            ;;
        SKIP)
            echo -e "${YELLOW}⊘ SKIP${NC} $name"
            ((SKIP_COUNT++))
            ;;
    esac
}

echo -e "${BLUE}=== Julia Registry Install Validation ===${NC}"
echo "Registry: $REGISTRY_URL"
echo "Julia: $JULIA"
echo ""

# Scenario 1: Clean env, install FRANK
echo -e "${BLUE}Scenario 1: Install FRANK in clean environment${NC}"
if run_isolated '
using Pkg
Pkg.Registry.add(Pkg.RegistrySpec(url="'"$REGISTRY_URL"'"))
Pkg.add("FRANK")
using FRANK

# Verify version
v = pkgversion(FRANK)
println("FRANK version: $v")
if v != v"0.2.0"
    error("Expected FRANK v0.2.0, got $v")
end

# Test basic emission
e = FrankEmitter(io=devnull)
emit!(e, "test_event", FRANK.STATE_TRANSITION, Dict("key"=>"value"))
println("Successfully emitted test event")
' 2>/dev/null; then
    test_result "Scenario 1: Install FRANK" "PASS"
else
    test_result "Scenario 1: Install FRANK" "FAIL"
fi
echo ""

# Scenario 2: Clean env, install JUI
echo -e "${BLUE}Scenario 2: Install JUI in clean environment${NC}"
if run_isolated '
using Pkg
Pkg.Registry.add(Pkg.RegistrySpec(url="'"$REGISTRY_URL"'"))

# Time the installation
import Dates
start_time = Dates.now()
Pkg.add("JUI")
elapsed = Dates.now() - start_time

using JUI
v = pkgversion(JUI)
println("JUI version: $v")
if v != v"0.2.0"
    error("Expected JUI v0.2.0, got $v")
end

# Test basic TUI operations with TestBackend
buf = JUI.Buffer(width=80, height=24)
println("Successfully created Buffer")
println("Elapsed time: $(Dates.value(elapsed))ms")
' 2>/dev/null; then
    test_result "Scenario 2: Install JUI" "PASS"
else
    test_result "Scenario 2: Install JUI" "FAIL"
fi
echo ""

# Scenario 3: Install both JUI and FRANK, verify weak dep extension
echo -e "${BLUE}Scenario 3: Verify JUIFRANKExt weak dependency mechanism${NC}"
if run_isolated '
using Pkg
Pkg.Registry.add(Pkg.RegistrySpec(url="'"$REGISTRY_URL"'"))
Pkg.add(["JUI", "FRANK"])

using JUI
using FRANK

# Check if extension is loaded
ext = Base.get_extension(JUI, :JUIFRANKExt)
if ext === nothing
    error("JUIFRANKExt not loaded!")
end

println("JUIFRANKExt successfully loaded")

# Verify FRANK functionality within JUI context
e = FrankEmitter(io=devnull)
emit!(e, "jui_test", FRANK.STATE_TRANSITION, Dict())
println("FRANK emission works in JUI context")
' 2>/dev/null; then
    test_result "Scenario 3: JUIFRANKExt weak dep" "PASS"
else
    test_result "Scenario 3: JUIFRANKExt weak dep" "FAIL"
fi
echo ""

# Scenario 4: Version pinning
echo -e "${BLUE}Scenario 4: Version pinning for JUI v0.2.0${NC}"
if run_isolated '
using Pkg
Pkg.Registry.add(Pkg.RegistrySpec(url="'"$REGISTRY_URL"'"))
Pkg.add(Pkg.PackageSpec(name="JUI", version="0.2.0"))

using JUI
v = pkgversion(JUI)
println("Installed JUI version: $v")
if v != v"0.2.0"
    error("Version pinning failed: expected 0.2.0, got $v")
end
println("Version pinning successful")
' 2>/dev/null; then
    test_result "Scenario 4: Version pinning" "PASS"
else
    test_result "Scenario 4: Version pinning" "FAIL"
fi
echo ""

# Scenario 5: Update flow documentation
echo -e "${BLUE}Scenario 5: Update flow documentation${NC}"
cat <<'EOF'
Phase 5 Update Flow (documented-only, not implemented yet):

1. Bump patch version in JUI/Project.toml: 0.2.0 → 0.2.1
2. Tag release: git tag v0.2.1 && git push origin v0.2.1
3. Re-register via LocalRegistry:
   - Requires LocalRegistry.jl in user registry management
   - Run: julia -e 'using LocalRegistry; register(path="/home/js/eidos/JUI", registry="eidos/JuliaRegistry", push=true)'
4. Registry CI/CD (Forgejo) auto-detects push event
5. Users run: Pkg.update("JUI") → resolves to 0.2.1
6. Version constraint in compat section must allow 0.2.1

Current state: Registry integration complete, update mechanics ready for Phase 5.
EOF
test_result "Scenario 5: Update flow docs" "SKIP"
echo ""

# Summary
echo -e "${BLUE}=== Summary ===${NC}"
echo -e "Passed:  ${GREEN}$PASS_COUNT${NC}"
echo -e "Failed:  ${RED}$FAIL_COUNT${NC}"
echo -e "Skipped: ${YELLOW}$SKIP_COUNT${NC}"
echo ""

if [ "$FAIL_COUNT" -gt 0 ]; then
    echo -e "${RED}Validation FAILED${NC}"
    exit 1
else
    echo -e "${GREEN}Validation PASSED${NC}"
    exit 0
fi
