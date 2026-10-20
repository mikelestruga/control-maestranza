-- =====================================================================
--  CONTROL DE TALLER · agregar kg producidos
--  Ejecutar UNA vez en Supabase > SQL Editor > New snippet > Run
-- =====================================================================

-- Peso total cotizado de la OT y kg producidos (se suman solos)
alter table ots add column if not exists kg_cotizados numeric check (kg_cotizados >= 0);
alter table ots add column if not exists kg_producidos numeric not null default 0;

-- Registro de producción terminada: lo ingresa el jefe de taller
create table if not exists produccion (
  id bigint generated always as identity primary key,
  ot_id bigint not null references ots(id),
  fecha date not null default current_date,
  kg numeric not null check (kg > 0),
  piezas numeric not null default 0 check (piezas >= 0),
  nota text,
  registrado_por uuid references perfiles(id) default auth.uid(),
  creado timestamptz not null default now()
);
create index if not exists produccion_ot on produccion (ot_id);
create index if not exists produccion_fecha on produccion (fecha);

-- Mantiene en la OT el total de kg y de piezas terminadas
create or replace function produccion_totales() returns trigger
language plpgsql security definer set search_path = public as $$
declare oid bigint := coalesce(new.ot_id, old.ot_id);
begin
  update ots set
    kg_producidos = (select coalesce(sum(kg), 0) from produccion where ot_id = oid),
    terminadas    = (select coalesce(sum(piezas), 0) from produccion where ot_id = oid)
  where id = oid;
  if tg_op = 'UPDATE' and old.ot_id <> new.ot_id then
    update ots set
      kg_producidos = (select coalesce(sum(kg), 0) from produccion where ot_id = old.ot_id),
      terminadas    = (select coalesce(sum(piezas), 0) from produccion where ot_id = old.ot_id)
    where id = old.ot_id;
  end if;
  return null;
end $$;
drop trigger if exists produccion_totales on produccion;
create trigger produccion_totales after insert or update or delete on produccion
  for each row execute function produccion_totales();

alter table produccion enable row level security;
drop policy if exists prod_leer on produccion;
drop policy if exists prod_crear on produccion;
drop policy if exists prod_editar on produccion;
drop policy if exists prod_borrar on produccion;
create policy prod_leer   on produccion for select to authenticated using (mi_rol() in ('jefe','admin'));
create policy prod_crear  on produccion for insert to authenticated with check (mi_rol() in ('jefe','admin'));
create policy prod_editar on produccion for update to authenticated using (mi_rol() in ('jefe','admin')) with check (mi_rol() in ('jefe','admin'));
create policy prod_borrar on produccion for delete to authenticated using (mi_rol() in ('jefe','admin'));

grant all on produccion to authenticated;
