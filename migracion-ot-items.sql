-- Migración: ítems por OT (nombre, piezas/metros, cantidad, kg). Ejecutar una vez en Supabase > SQL Editor.
-- Requiere haber ejecutado antes migracion-kg.sql.

-- ---------- Ítems de cada OT (nombre, unidad piezas/metros, cantidad y kg) ----
create table if not exists ot_items (
  id bigint generated always as identity primary key,
  ot_id bigint not null references ots(id) on delete cascade,
  nombre text not null,
  unidad text not null default 'pza' check (unidad in ('pza','m')),
  cantidad numeric not null check (cantidad > 0),
  kg numeric check (kg >= 0),
  orden int not null default 0
);
create index if not exists ot_items_ot on ot_items (ot_id);
alter table ot_items enable row level security;
drop policy if exists oti_leer on ot_items; drop policy if exists oti_esc on ot_items;
create policy oti_leer on ot_items for select to authenticated using (mi_rol() is not null);
create policy oti_esc  on ot_items for all to authenticated using (mi_rol() in ('jefe','gerencia','admin')) with check (mi_rol() in ('jefe','gerencia','admin'));
revoke all on ot_items from anon, authenticated;
grant select, insert, update, delete on ot_items to authenticated;

-- OT que ya existían: se crea un ítem con sus datos actuales
insert into ot_items (ot_id, nombre, unidad, cantidad, kg)
select o.id, coalesce(nullif(o.descripcion, ''), o.numero),
       case when lower(trim(o.unidad)) in ('m','mt','mts','metro','metros','ml') then 'm' else 'pza' end,
       o.cantidad, o.kg_cotizados
from ots o where not exists (select 1 from ot_items i where i.ot_id = o.id);

-- Texto que identifica el registro (ej.: "OT-1234 · Minera X")
create or replace function audit_det(t text, r jsonb) returns text
language plpgsql stable security definer set search_path = public as $$
declare x text;
begin
  if t = 'ots' then x := coalesce(r->>'numero','') || ' · ' || coalesce(r->>'cliente','');
  elsif t = 'ot_ppto' then x := 'Cotización de ' || coalesce((select numero from ots where id = (r->>'ot_id')::bigint), 'OT');
  elsif t = 'materiales' then x := coalesce(r->>'nombre','') || coalesce(' (' || (r->>'grupo') || ')', '');
  elsif t in ('tarifas','maquinas','procesos','operaciones') then x := r->>'nombre';
  elsif t = 'dias_especiales' then x := coalesce(r->>'fecha','') || ' ' || coalesce(r->>'descripcion','');
  elsif t = 'config' then x := r->>'clave';
  elsif t = 'perfiles' then x := coalesce(r->>'nombre','') || ' (' || coalesce(r->>'usuario','') || ')';
  elsif t in ('hh_registros','asistencia') then
    x := coalesce((select nombre from perfiles where id = (r->>'perfil_id')::uuid), '?') || ' · ' || coalesce(r->>'fecha', left(r->>'entrada', 10), '')
         || coalesce(' · OT ' || (select numero from ots where id = (r->>'ot_id')::bigint), '');
  elsif t in ('consumos','servicios') then
    x := coalesce(r->>'descripcion', (select nombre from materiales where id = (r->>'material_id')::bigint),
                  (select nombre from procesos where id = (r->>'proceso_id')::bigint), '')
         || ' · OT ' || coalesce((select numero from ots where id = (r->>'ot_id')::bigint), '?');
  elsif t = 'stock_ingresos' then x := coalesce((select nombre from materiales where id = (r->>'material_id')::bigint), '?') || ' · ' || coalesce(r->>'cantidad','') || ' un';
  elsif t = 'ot_stock' then x := coalesce(r->>'descripcion','') || ' · OT ' || coalesce((select numero from ots where id = (r->>'ot_id')::bigint), '?');
  elsif t = 'compras' then x := coalesce(r->>'numero','s/n') || ' · ' || coalesce(r->>'proveedor','') || ' · OT ' || coalesce((select numero from ots where id = (r->>'ot_id')::bigint), '?');
  elsif t = 'documentos' then x := coalesce(r->>'nombre','') || ' · OT ' || coalesce((select numero from ots where id = (r->>'ot_id')::bigint), '?');
  elsif t = 'ot_items' then x := coalesce(r->>'nombre','') || ' · ' || coalesce(r->>'cantidad','') || case when r->>'unidad' = 'm' then ' m' else ' pza' end || coalesce(' · ' || (r->>'kg') || ' kg', '') || ' · OT ' || coalesce((select numero from ots where id = (r->>'ot_id')::bigint), '?');
  elsif t = 'maquina_uso' then x := coalesce((select nombre from maquinas where id = (r->>'maquina_id')::bigint), '?') || ' · ' || coalesce(r->>'horas','') || ' h · OT ' || coalesce((select numero from ots where id = (r->>'ot_id')::bigint), '?');
  elsif t = 'produccion' then x := 'OT ' || coalesce((select numero from ots where id = (r->>'ot_id')::bigint), '?') || ' · ' || coalesce(r->>'kg','') || ' kg';
  else x := r->>'id';
  end if;
  return x;
end $$;

-- Trigger común. Registra lo que hace una PERSONA (no lo que calculan otros triggers).
create or replace function auditar() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  uid uuid := auth.uid(); modo text := coalesce(tg_argv[0], 'todo');
  n jsonb; o jsonb; r jsonb; camb jsonb; acc text; sec text; pf perfiles%rowtype;
  ign text[] := array['creado','creada','id','total'];
begin
  if uid is null or pg_trigger_depth() > 1 then return null; end if;
  if tg_op = 'INSERT' and modo = 'cambios' then return null; end if;
  n := case when tg_op <> 'DELETE' then to_jsonb(new) end;
  o := case when tg_op <> 'INSERT' then to_jsonb(old) end;
  r := coalesce(n, o);
  acc := case tg_op when 'INSERT' then 'crear' when 'UPDATE' then 'modificar' else 'eliminar' end;
  if tg_op = 'UPDATE' then
    select jsonb_object_agg(k.key, jsonb_build_array(o->k.key, n->k.key)) into camb
      from jsonb_object_keys(n) as k(key) where n->k.key is distinct from o->k.key and k.key <> all (ign);
    if camb is null then return null; end if;
    if tg_table_name in ('hh_registros','asistencia') and r->>'perfil_id' = uid::text then return null; end if;  -- su propia marcación
    if tg_table_name = 'hh_registros' and not (camb ?| array['horas','horas_extra','inicio','fin','ot_id','operacion_id','maquina_id','tipo','fecha','perfil_id','motivo']) then
      return null;   -- aprobar o validar no se anota; sí corregir horas
    end if;
  else
    select jsonb_object_agg(k.key, case when tg_op = 'INSERT' then jsonb_build_array(null, r->k.key) else jsonb_build_array(r->k.key, null) end) into camb
      from jsonb_object_keys(r) as k(key) where r->k.key <> 'null'::jsonb and k.key <> all (ign);
  end if;
  sec := case tg_table_name
    when 'ots' then 'Órdenes de trabajo' when 'ot_ppto' then 'Órdenes de trabajo' when 'produccion' then 'Órdenes de trabajo' when 'ot_items' then 'Órdenes de trabajo'
    when 'hh_registros' then 'Horas hombre' when 'asistencia' then 'Horas hombre'
    when 'materiales' then 'Materiales'
    when 'consumos' then 'Bodega' when 'stock_ingresos' then 'Bodega' when 'ot_stock' then 'Bodega'
    when 'compras' then 'Compras y documentos' when 'documentos' then 'Compras y documentos'
    when 'servicios' then 'Pintura y servicios'
    when 'maquina_uso' then 'Máquinas'
    when 'tarifas' then 'Costos y tarifas' when 'maquinas' then 'Costos y tarifas' when 'procesos' then 'Costos y tarifas'
    when 'perfiles' then 'Trabajadores'
    else 'Plataforma' end;
  -- el primer cambio sobre un usuario recién creado se anota como "alta" del trabajador
  if tg_table_name = 'perfiles' and tg_op = 'UPDATE'
     and exists (select 1 from auth.users where id = (r->>'id')::uuid and created_at > now() - interval '2 minutes') then
    acc := 'crear';
  end if;
  select * into pf from perfiles where id = uid;
  insert into auditoria (usuario_id, usuario_nombre, usuario_rol, seccion, accion, tabla, registro, detalle, cambios)
  values (uid, pf.nombre, pf.rol, sec, acc, tg_table_name, coalesce(r->>'id', r->>'ot_id', r->>'clave', r->>'fecha'), audit_det(tg_table_name, r), camb);
  return null;
end $$;

drop trigger if exists zz_auditar on ot_items;
create trigger zz_auditar after insert or update or delete on ot_items for each row execute function auditar('todo');
