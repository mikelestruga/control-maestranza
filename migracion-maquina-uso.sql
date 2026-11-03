-- Migración: horas de máquina por OT. Ejecutar una vez en Supabase > SQL Editor.

-- ---------- Horas de máquina por OT (independientes de las horas del operador) ----
-- El operador se cobra con su tarifa HH; la máquina con su costo por hora. Aquí se anota
-- el tiempo de máquina que no está en una tarea de operario. El costo lo ve solo admin/gerencia.
create table if not exists maquina_uso (
  id bigint generated always as identity primary key,
  ot_id bigint not null references ots(id) on delete cascade,
  maquina_id bigint not null references maquinas(id),
  fecha date not null default current_date,
  horas numeric not null check (horas > 0 and horas <= 24),
  nota text,
  registrado_por uuid default auth.uid(),
  creado timestamptz not null default now()
);
create index if not exists maquina_uso_ot on maquina_uso (ot_id);
create table if not exists maquina_uso_costo (
  uso_id bigint primary key references maquina_uso(id) on delete cascade,
  costo numeric not null default 0,
  estimado boolean not null default false
);
create or replace function maquina_uso_calcula() returns trigger
language plpgsql security definer set search_path = public as $$
declare m maquinas%rowtype;
begin
  select * into m from maquinas where id = new.maquina_id;
  insert into maquina_uso_costo (uso_id, costo, estimado)
  values (new.id, round(new.horas * coalesce(m.costo_hh, 0)), coalesce(m.estimada, false))
  on conflict (uso_id) do update set costo = excluded.costo, estimado = excluded.estimado;
  return null;
end $$;
drop trigger if exists maquina_uso_costo_trg on maquina_uso;
create trigger maquina_uso_costo_trg after insert or update on maquina_uso for each row execute function maquina_uso_calcula();
alter table maquina_uso enable row level security;
alter table maquina_uso_costo enable row level security;
drop policy if exists mu_leer on maquina_uso; drop policy if exists mu_esc on maquina_uso; drop policy if exists mu_costo on maquina_uso_costo;
create policy mu_leer on maquina_uso for select to authenticated using (mi_rol() in ('jefe','gerencia','admin'));
create policy mu_esc  on maquina_uso for all to authenticated using (mi_rol() in ('jefe','gerencia','admin')) with check (mi_rol() in ('jefe','gerencia','admin'));
create policy mu_costo on maquina_uso_costo for select to authenticated using (mi_rol() in ('admin','gerencia'));
revoke all on maquina_uso, maquina_uso_costo from anon, authenticated;
grant select, insert, update, delete on maquina_uso to authenticated;
grant select on maquina_uso_costo to authenticated;

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
    when 'ots' then 'Órdenes de trabajo' when 'ot_ppto' then 'Órdenes de trabajo' when 'produccion' then 'Órdenes de trabajo'
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

drop trigger if exists zz_auditar on maquina_uso;
create trigger zz_auditar after insert or update or delete on maquina_uso for each row execute function auditar('todo');
