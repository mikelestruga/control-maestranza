-- Migración: historial de costo/precio por kg de cada tipo, y costo/precio propio en cada ítem de OT.
-- Ejecutar DESPUÉS de migracion-tipos-costo.sql.
alter table ot_items add column if not exists costo_kg numeric check (costo_kg >= 0);
alter table ot_items add column if not exists precio_kg numeric check (precio_kg >= 0);
-- los ítems existentes conservan el valor vigente de su tipo
update ot_items i set costo_kg = t.costo_kg, precio_kg = t.precio_kg from tipos_item t where t.id = i.tipo_id and i.costo_kg is null and i.precio_kg is null;

create table if not exists tipos_item_hist (
  id bigint generated always as identity primary key,
  tipo_id bigint not null references tipos_item(id) on delete cascade,
  fecha date not null default current_date,
  costo_kg numeric, precio_kg numeric,
  registrado_por uuid default auth.uid(),
  creado timestamptz not null default now()
);
create index if not exists tipos_item_hist_tipo on tipos_item_hist (tipo_id, fecha desc);
create or replace function tipos_item_hist_trg() returns trigger
language plpgsql security definer set search_path = public as $$
declare u tipos_item_hist%rowtype;
begin
  if new.costo_kg is null and new.precio_kg is null then return null; end if;
  select * into u from tipos_item_hist where tipo_id = new.id order by fecha desc, id desc limit 1;
  if found and u.costo_kg is not distinct from new.costo_kg and u.precio_kg is not distinct from new.precio_kg then return null; end if;
  if found and u.fecha = current_date then
    update tipos_item_hist set costo_kg = new.costo_kg, precio_kg = new.precio_kg, registrado_por = auth.uid() where id = u.id;
  else
    insert into tipos_item_hist (tipo_id, costo_kg, precio_kg) values (new.id, new.costo_kg, new.precio_kg);
  end if;
  return null;
end $$;
drop trigger if exists tipos_item_hist_ai on tipos_item;
create trigger tipos_item_hist_ai after insert or update of costo_kg, precio_kg on tipos_item for each row execute function tipos_item_hist_trg();
alter table tipos_item_hist enable row level security;
drop policy if exists tih_leer on tipos_item_hist;
create policy tih_leer on tipos_item_hist for select to authenticated using (mi_rol() in ('admin','gerencia'));
revoke all on tipos_item_hist from anon, authenticated;
grant select on tipos_item_hist to authenticated;
-- historial inicial con los valores actuales
insert into tipos_item_hist (tipo_id, costo_kg, precio_kg)
select t.id, t.costo_kg, t.precio_kg from tipos_item t
where (t.costo_kg is not null or t.precio_kg is not null) and not exists (select 1 from tipos_item_hist h where h.tipo_id = t.id);
