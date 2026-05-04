#!/opt/homebrew/bin/bash
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

for ep in 2a73txojt5y5mcbp5usni3rdywe74wsg
do
    echo "Starting rollback for $ep"
    "$SCRIPT_DIR/01_scale_down.sh" $ep
    "$SCRIPT_DIR/02_fix_db.sh" $ep reset
#    "$SCRIPT_DIR/02_fix_db.sh" $ep restore
    "$SCRIPT_DIR/can_scale_up.sh" $ep ddiaas-endpoint-manager v0.1.0-13-g2c6382a-j159-main

done

