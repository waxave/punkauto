# Fix: RockAuto locale redirect loops

- Status: Fixed
- Branch: `fix/rockauto-language-redirects`

## Bug summary

Localized RockAuto paths redirect to themselves on the first request. The
redirect response sets a language cookie; following the redirect without that
cookie loops until Faraday's redirect limit is reached.

## Reproduction

```sh
./exe/punkauto --display=transformed --language=es search 2C4516
./exe/punkauto --display=transformed --language=es vehicle honda 2010 accord
```

## Expected and actual behavior

The commands should follow RockAuto's locale redirect and return parsed results.
Previously, both failed with `too many redirects` to the same localized URL.

## Affected areas and fix

`Punkauto::BaseClient` middleware ordering caused redirect handling to run
before cookie persistence. Place redirect handling outside the cookie jar so
the redirect response's language cookie is available to the next request.

## Regression tests

Use WebMock to model the redirect response and assert the redirected request
contains the language cookie. All captured HTML remains in local fixtures; the
test suite continues to disable outbound network requests.
