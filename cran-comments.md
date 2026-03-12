## R CMD check results

0 errors | 0 warnings | 1 note

* This is a release update (v0.5.0).
* The note regarding "New submission" or "First release" is expected if applicable.
* All examples have been optimized for temporal stability and performance.
* Long-running examples are marked with `\donttest{}`.

## Major Changes

* Introduced **Temporal Stability Engine**: Ensuring risk group stability over time (vintages).
* New **Recipe-Based Predict API**: Serialized model objects for reliable OOT (Out-Of-Time) prediction.
* High-Scale Segment Screening: Optimized C++ backend for large-scale risk profiling.

## Test coverage

All tests passed on multiple architectures (x64 and i386).
Streamlined parallel test suites to prevent environmental timeouts.

## Reverse dependencies

None.
