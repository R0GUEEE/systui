#!/bin/bash
set -euo pipefail

f=src/features/97-software-catalogue-collections-final.sh
manifest=src/features/.load-order

bash -n "$f"
grep -qx '97-software-catalogue-collections-final.sh' "$manifest"
grep -q 'systui_catalogue_collections_ensure' "$f"
grep -q 'catalogue_collections()' "$f"
grep -q 'Developer workstation' "$f"
grep -q 'Python development' "$f"
grep -q 'Backup toolkit' "$f"
grep -q 'No packages were selected' "$f"
grep -q 'pm_install "${pkgs\[@\]}"' "$f"

# Functional registry recovery: collections must repopulate from an empty state.
unset CAT_COLLECTIONS 2>/dev/null || true
# Minimal stubs needed only for sourcing.
tui_menu_no_tags(){ :; }
tui_check(){ :; }
tui_msg(){ :; }
tui_yesno(){ return 1; }
show_warnings(){ :; }
source "$f"

[ -n "${CAT_COLLECTIONS[developer]:-}" ]
[ -n "${CAT_COLLECTIONS[python]:-}" ]
[ -n "${CAT_COLLECTIONS[network]:-}" ]
[ -n "${CAT_COLLECTIONS[backup]:-}" ]
case " ${CAT_COLLECTIONS[developer]} " in *' python3 '* ) : ;; *) exit 1 ;; esac
case " ${CAT_COLLECTIONS[network]} " in *' nmap '* ) : ;; *) exit 1 ;; esac

echo 'ok - curated software collections recover and dispatch selected packages'
