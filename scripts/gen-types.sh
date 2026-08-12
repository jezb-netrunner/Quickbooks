#!/bin/sh
# Regenerate src/lib/database.types.ts from the RUNNING local stack.
# Run after any migration change, and commit the result in the same PR.
set -e
npx supabase gen types typescript --local > src/lib/database.types.ts
echo "src/lib/database.types.ts regenerated"
