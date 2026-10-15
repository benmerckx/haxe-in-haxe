# bench-data

Benchmark results of hxmc (data only; see `hxmc/test/Bench.hx` and
`.github/workflows/bench.yml` on main). `results/<date>-<commit>.json` is one
run each, appended by the bench workflow; `history.json` and `latest.json` are
regenerated from them (`Bench --history`) and copied into the website by its
build. Files with `"source": "imported"` are earlier measurements taken from
the repository's history (a development VM, best of the runs), not CI runs.
