-- Migración: costo por kg y precio por kg en cada tipo de trabajo. Ejecutar DESPUÉS de migracion-ot-tipos.sql.
alter table tipos_item add column if not exists costo_kg numeric check (costo_kg >= 0);
alter table tipos_item add column if not exists precio_kg numeric check (precio_kg >= 0);
