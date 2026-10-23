# Cross-test profile for LMDB.
# Keep cross-test's full target matrix and runner detection; set no matrix or runner override.
# Targets without an executor are built but not run.
# Run the package's default static `test` step; shared linkage is a separate build.
# Leave scratch, cache, job width, and timeouts to cross-test and the caller.
CROSS_BUILD_STEP=test
