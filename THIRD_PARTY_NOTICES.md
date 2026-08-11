# Third-party notices

This repository builds and redistributes runtime artifacts from independently
licensed upstream projects. The MIT license at the repository root
applies only to the original packaging code in this repository. It does not
replace the licenses of upstream projects or their transitive dependencies.

The primary upstream projects are:

| Service | Upstream project | License |
| --- | --- | --- |
| Analytics | [Logflare](https://github.com/Logflare/logflare) | Apache-2.0 |
| Auth | [Supabase Auth](https://github.com/supabase/auth) | MIT |
| Edge Runtime | [Supabase Edge Runtime](https://github.com/supabase/edge-runtime) | MIT |
| Postgres Meta | [postgres-meta](https://github.com/supabase/postgres-meta) | Apache-2.0 |
| Pooler | [Supavisor](https://github.com/supabase/supavisor) | Apache-2.0 |
| Postgres | [Supabase Postgres](https://github.com/supabase/postgres) | PostgreSQL |
| PostgREST | [PostgREST](https://github.com/PostgREST/postgrest) | MIT |
| Realtime | [Supabase Realtime](https://github.com/supabase/realtime) | Apache-2.0 |
| Storage | [Supabase Storage](https://github.com/supabase/storage) | Apache-2.0 |
| Studio | [Supabase](https://github.com/supabase/supabase) | Apache-2.0 |

Each generated runtime archive includes the license and notice files found in
its dependency closure under `share/licenses/`. Each release also includes an
SPDX 2.3 SBOM describing every file shipped in the archive. Those generated
materials are the authoritative notices for a particular service, version, and
target.
