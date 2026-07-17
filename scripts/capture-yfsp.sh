#!/bin/bash
# capture-yfsp.sh -> 统一入口 shim
exec "$(dirname "${BASH_SOURCE[0]}")/capture.sh" "$@"