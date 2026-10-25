# Contributing

## Branch naming

Use a short prefix and a hyphenated description:

- `feat/<topic>` for new behavior
- `fix/<topic>` for defect repairs
- `docs/<topic>` for documentation
- `refactor/<topic>` for internal restructuring
- `chore/<topic>` for tooling and maintenance
- `test/<topic>` for test-only changes

Example: `feat/chunk-store`.

## Commit format

Follow [Conventional Commits](https://www.conventionalcommits.org/):

```
<type>(<optional-scope>): <imperative summary>
```

Types: `feat`, `fix`, `docs`, `refactor`, `test`, `chore`. Keep the subject to one line, explain why in the body when needed, and do not include secrets.

## Build and test

Set `VCPKG_ROOT`, then from the repository root:

```bash
cmake --preset debug
cmake --build --preset debug
ctest --preset debug
```

Format C++ with clang-format using `.clang-format` (Google style) before opening a pull request. Add GoogleTest coverage under `tests/` for every behavior change.
