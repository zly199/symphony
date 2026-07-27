#!/usr/bin/env sh
set -eu

exec python3 workflows/kyuyo-backend/evals/runners/run_evals.py "$@"
