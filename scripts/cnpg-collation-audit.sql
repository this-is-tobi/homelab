-- Read-only collation audit for the CNPG Postgres clusters (PostgreSQL 17+).
--
-- Why: pg_collation stamps every libc/ICU collation with the library version
-- it was created under. Changing the base image in the shared
-- ClusterImageCatalog (argo-cd/apps/cloudnative-pg/values.yaml) swaps glibc
-- and ICU under every cluster at once, and an index, constraint or expression
-- keyed on a versioned (non-C) collation may then hold an order the new
-- library no longer agrees with: lookups miss rows and unique indexes can let
-- duplicates in. Databases initdb'd with C/C compare raw bytes and are
-- immune; only objects that name an explicit libc or ICU collation are at
-- risk. Run this after every base-image change of the catalog, and after
-- restoring a backup onto a different image than the one that wrote it.
--
-- How: on each cluster's replica (a hot standby, so nothing can be written
-- and the primary carries no extra load), once per database: the app
-- database (spec.bootstrap.initdb.database of the Cluster), postgres and
-- template1. template0 refuses connections and is a copy of template1 at
-- initdb. psql in the postgres container connects as the postgres superuser
-- over the local socket; default_transaction_read_only keeps the session
-- read-only even if it lands on a primary by mistake.
--
--   kubectl get clusters.postgresql.cnpg.io -A    # namespaces and clusters
--   ns=<namespace> cluster=<cluster> db=<database>
--   pod=$(kubectl -n "$ns" get pod \
--     -l "cnpg.io/cluster=$cluster,cnpg.io/instanceRole=replica" \
--     -o jsonpath='{.items[0].metadata.name}')
--   kubectl -n "$ns" exec -i "$pod" -c postgres -- \
--     env PGOPTIONS='-c default_transaction_read_only=on' \
--     psql -X -q -v ON_ERROR_STOP=1 -d "$db" -f - < scripts/cnpg-collation-audit.sql
--
-- Reading the output:
--   1    expect provider c, datcollate/datctype C and datcollversion (null).
--   2-4  must be empty. A row is an object keyed on a versioned collation;
--        when recorded_version differs from actual_version (or the collation
--        is an unversioned libc C.*), its on-disk order may be stale.
--        Remediation writes, so run it on the primary: CREATE EXTENSION
--        amcheck; bt_index_check(index => '<index>'::regclass,
--        heapallindexed => true, checkunique => true) on each listed btree
--        index; REINDEX INDEX CONCURRENTLY every affected index (deduplicate
--        first if checkunique reports duplicates); only then
--        ALTER COLLATION <name> REFRESH VERSION. Refreshing first merely
--        silences the mismatch warning and leaves a corrupt index in place.
--   5    informational. Large "stale" counts are expected after a glibc/ICU
--        change, because initdb imports every OS collation; they are harmless
--        while 2-4 are empty. Do not bulk-refresh them.

\pset pager off
\pset null '(null)'

\echo '== 1. database default locale (expect provider c, C/C, datcollversion null)'
SELECT current_database() AS db, datname, datlocprovider, datcollate, datctype,
       datlocale, datcollversion,
       pg_database_collation_actual_version(oid) AS actual_version
FROM pg_database
WHERE datname = current_database();

\echo '== 2. columns with an explicit versioned collation (expect 0 rows)'
SELECT current_database() AS db, a.attrelid::regclass AS relation, a.attname,
       co.collname, co.collprovider, co.collcollate, co.colllocale,
       co.collversion AS recorded_version,
       pg_collation_actual_version(co.oid) AS actual_version,
       CASE WHEN co.collprovider = 'c' AND co.collcollate ILIKE 'C.%'
              THEN 'unversioned libc C.*: check with amcheck'
            WHEN co.collversion IS DISTINCT FROM pg_collation_actual_version(co.oid)
              THEN 'VERSION MISMATCH'
            ELSE 'versions match' END AS verdict
FROM pg_attribute a
JOIN pg_class c ON c.oid = a.attrelid
JOIN pg_collation co ON co.oid = a.attcollation
WHERE a.attnum > 0 AND NOT a.attisdropped
  AND c.relkind NOT IN ('i', 'I')
  AND c.relnamespace NOT IN ('pg_catalog'::regnamespace, 'information_schema'::regnamespace)
  AND co.collprovider NOT IN ('d', 'b')
  AND NOT (co.collprovider = 'c' AND co.collcollate IN ('C', 'POSIX'))
ORDER BY 2, 3;

\echo '== 3. indexes keyed on a versioned collation (expect 0 rows; any row -> bt_index_check)'
SELECT current_database() AS db, i.indexrelid::regclass AS index, i.indrelid::regclass AS "table",
       am.amname, co.collname, co.collprovider,
       co.collversion AS recorded_version,
       pg_collation_actual_version(co.oid) AS actual_version
FROM pg_index i
JOIN pg_class ic ON ic.oid = i.indexrelid
JOIN pg_am am ON am.oid = ic.relam
CROSS JOIN LATERAL unnest(i.indcollation::oid[]) AS k(collid)
JOIN pg_collation co ON co.oid = k.collid
WHERE ic.relnamespace NOT IN ('pg_catalog'::regnamespace, 'information_schema'::regnamespace)
  AND co.collprovider NOT IN ('d', 'b')
  AND NOT (co.collprovider = 'c' AND co.collcollate IN ('C', 'POSIX'))
ORDER BY 2;

\echo '== 4. any other object depending on a versioned collation: expressions, predicates, constraints, views, domains (expect 0 rows)'
SELECT current_database() AS db,
       pg_describe_object(d.classid, d.objid, d.objsubid) AS dependent_object,
       co.collname, co.collprovider,
       co.collversion AS recorded_version,
       pg_collation_actual_version(co.oid) AS actual_version
FROM pg_depend d
JOIN pg_collation co ON d.refclassid = 'pg_collation'::regclass AND co.oid = d.refobjid
WHERE co.collprovider NOT IN ('d', 'b')
  AND NOT (co.collprovider = 'c' AND co.collcollate IN ('C', 'POSIX'))
ORDER BY 2;

\echo '== 5. informational: catalog collations with a stale recorded version (large counts expected after a glibc/ICU change; harmless unless 2-4 reference them)'
SELECT current_database() AS db, collprovider, count(*) AS total,
       count(*) FILTER (WHERE collversion IS DISTINCT FROM pg_collation_actual_version(oid)) AS stale
FROM pg_collation
WHERE collprovider IN ('c', 'i')
GROUP BY collprovider
ORDER BY collprovider;
