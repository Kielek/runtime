# Strict tracestate key tests still enforce obsolete tenant/vendor `@` grammar

## Summary

The current Trace Context Level 2 `tracestate` key grammar allows `@` as a normal `keychar`, but the strict compliance tests still reject several keys based on the older tenant/vendor split around `@`.

Current spec text:

<https://www.w3.org/TR/trace-context-2/#key>

```abnf
key = ( lcalpha / DIGIT ) 0*255 ( keychar )
keychar    = lcalpha / DIGIT / "_" / "-"/ "*" / "/" / "@"
lcalpha    = %x61-7A ; a-z
```

The prose immediately below that grammar says a key may contain at signs (`@`) and is limited to 256 total characters.

## Affected Tests

In `test/test.py`, these `STRICT_LEVEL >= 2` tests appear to enforce the older tenant/vendor format instead of the current grammar:

- [`TraceContextTest.test_tracestate_key_illegal_vendor_format`](https://github.com/w3c/trace-context/blob/34b10ac5af7f0caeb28efe35fe51cd4763ec5771/test/test.py#L724-L752)
- [`TraceContextTest.test_tracestate_key_length_limit`](https://github.com/w3c/trace-context/blob/34b10ac5af7f0caeb28efe35fe51cd4763ec5771/test/test.py#L783-L825)

Examples currently treated as invalid by the suite but valid under the current Level 2 grammar:

```text
foo@=1
foo@@bar=1
foo@bar@baz=1
t...t@v=1        # 242 chars before @, total key length still <= 256
t@vvvvvvvvvvvvvvv=1
```

`@foo=1` should remain invalid because `key` must begin with `lcalpha` or `DIGIT`.

`z * 257 + '=1'` should also remain invalid because the total key length exceeds 256.

## Spec/Test History

The test behavior looks consistent with older spec text, but not with the current grammar:

- PR [#153](https://github.com/w3c/trace-context/pull/153) added `@` in tracestate key names for multi-tenant vendors.
- PR [#176](https://github.com/w3c/trace-context/pull/176) added the affected tracestate tests.
- PR [#281](https://github.com/w3c/trace-context/pull/281) moved these tests behind `STRICT_LEVEL >= 2`.
- PR [#386](https://github.com/w3c/trace-context/pull/386) clarified the ABNF and changed the key grammar to the current `keychar` form. The PR discussion/commit notes include “permit any number of at signs”.

After PR #386, `@` is no longer structurally special in the grammar. It is just one allowed `keychar`.

## Expected Behavior

The strict test suite should match the current Trace Context Level 2 grammar:

- Keep rejecting keys that violate the current grammar:
  - empty key
  - first character not `lcalpha` or `DIGIT`
  - characters outside `keychar`
  - total key length greater than 256
- Stop rejecting keys only because of the number or position of `@` after the first character.
- Stop applying the older `241` / `14` tenant/vendor section limits unless the spec reintroduces those limits.

## Suggested Fix

Update `test_tracestate_key_illegal_vendor_format` and `test_tracestate_key_length_limit` so they validate the current `key` grammar:

- `foo@=1`, `foo@@bar=1`, and `foo@bar@baz=1` should be accepted.
- `t * 242 + '@v=1'` and `'t@' + 'v' * 15 + '=1'` should be accepted when total key length is `<= 256`.
- `@foo=1` should remain rejected.
- `z * 257 + '=1'` should remain rejected.
