# chunkvault

chunkvault is a distributed file storage system written in C++20. Files are split into content-addressed chunks, metadata lives in PostgreSQL, hot paths are cached in Redis, and a Drogon HTTP API coordinates uploads, downloads, and replication across storage nodes.

## Planned features

- Content-defined chunking and integrity checks
- Multi-node replication and repair
- JWT-authenticated HTTP API for object upload, download, and listing
- PostgreSQL metadata and Redis caching
- Independent `storage_node` process for blob placement
- Operational tooling, deployment manifests, and benchmarks

## Build

Prerequisites: CMake 3.21+, a C++20 compiler, Ninja, and [vcpkg](https://github.com/microsoft/vcpkg). Set `VCPKG_ROOT` to your vcpkg checkout.

```bash
cp .env.example .env
cmake --preset debug
cmake --build --preset debug
ctest --preset debug
```

The `debug` and `release` presets use `$VCPKG_ROOT/scripts/buildsystems/vcpkg.cmake`. Run the API with environment variables from `.env.example`:

```bash
./build/chunkvault
```

`GET /health` returns `{"status":"ok"}`.
