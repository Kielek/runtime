# W3C Trace Context compliance repro

This folder contains a small HTTP service and runner for the upstream
`w3c/trace-context` compliance suite. It is intended as a focused repro for
`System.Diagnostics.W3CPropagator` and related `Activity` propagation behavior.

The folder embeds the W3C test suite files from the same upstream commit
currently pinned by the OpenTelemetry .NET W3C trace context test:

```text
34b10ac5af7f0caeb28efe35fe51cd4763ec5771
```

It executes the suite with:

```text
SPEC_LEVEL=2
STRICT_LEVEL=2
```

## Prerequisites

- PowerShell
- Git
- Python 3.11 or the Windows `py` launcher
- A restored dotnet/runtime enlistment

## Run

From the repository root:

```powershell
pwsh -File .\src\tests\W3CTraceContextCompliance\run-w3c-suite.ps1
```

If `System.Diagnostics.DiagnosticSource` is already built:

```powershell
pwsh -File .\src\tests\W3CTraceContextCompliance\run-w3c-suite.ps1 `
  -SkipDiagnosticSourceBuild
```

To run against a separate `w3c/trace-context` checkout, pass
`-TraceContextPath`.

Generated files are written under:

```text
artifacts\W3CTraceContextCompliance
```

The temporary HTTP server is stopped automatically after the suite exits.

## Current observed result

Against the current local runtime build used for this repro, the full W3C suite
ran 41 tests and failed with 5 failures and 2 errors:

```text
FAILED (failures=5, errors=2)
W3C suite exit code: 7
```

Failing tests:

```text
FAIL  test_traceparent_version_0xCC
FAIL  test_tracestate_included_traceparent_missing
ERROR test_tracestate_key_illegal_characters
ERROR test_tracestate_key_illegal_vendor_format
FAIL  test_tracestate_key_length_limit
FAIL  test_tracestate_member_count_limit
FAIL  test_tracestate_ows_handling
```
