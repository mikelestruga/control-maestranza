-- Migración: destino de las salidas de bodega (OT, faena con su contrato, o maestranza).
-- Ejecutar DESPUÉS de migracion-oc-bodega.sql. Las salidas que ya existen siguen cargadas a su OT.

create table if not exists destinos (
  id bigint generated always as identity primary key,
  tipo text not null check (tipo in ('faena','maestranza')),
  nombre text not null,
  contrato text,
  activo boolean not null default true,
  creado timestamptz not null default now(),
  registrado_por uuid default auth.uid()
);
create unique index if not exists destinos_unico on destinos (tipo, lower(nombre), lower(coalesce(contrato, '')));
alter table destinos enable row level security;
drop policy if exists dest_leer on destinos; drop policy if exists dest_crear on destinos; drop policy if exists dest_mod on destinos;
create policy dest_leer  on destinos for select to authenticated using (mi_rol() in ('bodega','jefe','gerencia','admin'));
create policy dest_crear on destinos for insert to authenticated with check (mi_rol() in ('bodega','jefe','gerencia','admin') and tipo = 'faena');
create policy dest_mod   on destinos for all    to authenticated using (mi_rol() in ('admin','gerencia')) with check (mi_rol() in ('admin','gerencia'));
revoke all on destinos from anon, authenticated;
grant select, insert, update, delete on destinos to authenticated;
insert into destinos (tipo, nombre) select 'maestranza', 'Maestranza (uso interno)' where not exists (select 1 from destinos where tipo = 'maestranza');

-- La salida va a una OT o a un destino (nunca a ambos)
alter table consumos alter column ot_id drop not null;
alter table consumos add column if not exists destino_id bigint references destinos(id);
alter table consumos drop constraint if exists consumos_ot_o_destino;
alter table consumos add constraint consumos_ot_o_destino check (num_nonnulls(ot_id, destino_id) = 1);
create index if not exists consumos_destino on consumos (destino_id);

-- Texto que identifica el registro (ej.: "OT-1234 · Minera X")
create or replace function audit_det(t text, r jsonb) returns text
language plpgsql stable security definer set search_path = public as $$
declare x text;
begin
  if t = 'ots' then x := coalesce(r->>'numero','') || ' · ' || coalesce(r->>'cliente','');
  elsif t = 'ot_ppto' then x := 'Cotización de ' || coalesce((select numero from ots where id = (r->>'ot_id')::bigint), 'OT');
  elsif t = 'materiales' then x := coalesce(r->>'nombre','') || coalesce(' (' || (r->>'grupo') || ')', '');
  elsif t in ('tarifas','maquinas','procesos','operaciones','tipos_item') then x := r->>'nombre';
  elsif t = 'dias_especiales' then x := coalesce(r->>'fecha','') || ' ' || coalesce(r->>'descripcion','');
  elsif t = 'config' then x := r->>'clave';
  elsif t = 'perfiles' then x := coalesce(r->>'nombre','') || ' (' || coalesce(r->>'usuario','') || ')';
  elsif t in ('hh_registros','asistencia') then
    x := coalesce((select nombre from perfiles where id = (r->>'perfil_id')::uuid), '?') || ' · ' || coalesce(r->>'fecha', left(r->>'entrada', 10), '')
         || coalesce(' · OT ' || (select numero from ots where id = (r->>'ot_id')::bigint), '');
  elsif t in ('consumos','servicios') then
    x := coalesce(r->>'descripcion', (select nombre from materiales where id = (r->>'material_id')::bigint),
                  (select nombre from procesos where id = (r->>'proceso_id')::bigint), '')
         || coalesce(' · OT ' || (select numero from ots where id = (r->>'ot_id')::bigint), '')
         || coalesce(' · ' || (select tipo || ' ' || nombre || coalesce(' / ' || contrato, '') from destinos where id = (r->>'destino_id')::bigint), '');
  elsif t = 'destinos' then x := coalesce(r->>'nombre','') || coalesce(' / ' || (r->>'contrato'), '');
  elsif t = 'stock_ingresos' then x := coalesce((select nombre from materiales where id = (r->>'material_id')::bigint), '?') || ' · ' || coalesce(r->>'cantidad','') || ' un';
  elsif t = 'ot_stock' then x := coalesce(r->>'descripcion','') || ' · OT ' || coalesce((select numero from ots where id = (r->>'ot_id')::bigint), '?');
  elsif t = 'compras' then x := coalesce(r->>'numero','s/n') || ' · ' || coalesce(r->>'proveedor','') || ' · ' || case when r->>'ot_id' is null then 'Bodega' else 'OT ' || coalesce((select numero from ots where id = (r->>'ot_id')::bigint), '?') end;
  elsif t = 'oc_lineas' then x := coalesce(r->>'descripcion','') || ' · OC ' || coalesce((select numero from compras where id = (r->>'compra_id')::bigint), 's/n');
  elsif t = 'documentos' then x := coalesce(r->>'nombre','') || ' · ' || case when r->>'ot_id' is null then 'Bodega' else 'OT ' || coalesce((select numero from ots where id = (r->>'ot_id')::bigint), '?') end;
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
    when 'consumos' then 'Bodega' when 'destinos' then 'Bodega' when 'stock_ingresos' then 'Bodega' when 'ot_stock' then 'Bodega'
    when 'compras' then 'Compras y documentos' when 'documentos' then 'Compras y documentos' when 'oc_lineas' then 'Compras y documentos'
    when 'servicios' then 'Pintura y servicios'
    when 'maquina_uso' then 'Máquinas'
    when 'tarifas' then 'Costos y tarifas' when 'maquinas' then 'Costos y tarifas' when 'procesos' then 'Costos y tarifas' when 'tipos_item' then 'Costos y tarifas'
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

drop trigger if exists zz_auditar on destinos;
create trigger zz_auditar after insert or update or delete on destinos for each row execute function auditar('todo');
