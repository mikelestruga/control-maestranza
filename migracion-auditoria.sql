-- =====================================================================
--  CONTROL DE TALLER · permisos ampliados + registro de cambios
--  Requiere haber ejecutado antes migracion-gerencia.sql.
--  Ejecutar UNA vez en Supabase > SQL Editor > New snippet > Run
--
--  1) Gerencia puede modificar costos y datos (tarifas, cotizaciones, materiales,
--     OT, consumos, servicios, compras...). Sigue sin acceso a trabajadores,
--     claves ni parámetros de la plataforma: eso es solo del Administrador.
--  2) Bodega puede agregar, editar y quitar materiales del catálogo.
--  3) Todo cambio queda anotado en el registro de cambios (solo lo ve el Administrador).
-- =====================================================================

-- 1) Donde hoy solo decide el administrador sobre datos del taller, también Gerencia
do $$
declare p record; q text; w text; sql text;
begin
  for p in
    select schemaname, tablename, policyname, qual, with_check from pg_policies
     where ((schemaname = 'public' and tablename in ('tarifas','maquinas','procesos','materiales','ot_ppto','ots','consumos','servicios','compras','ot_stock','documentos','asistencia'))
         or (schemaname = 'storage' and tablename = 'objects'))
       and (coalesce(qual,'') like '%mi_rol() = ''admin''::text%' or coalesce(with_check,'') like '%mi_rol() = ''admin''::text%')
  loop
    q := replace(p.qual,       'mi_rol() = ''admin''::text', 'mi_rol() = ANY (ARRAY[''admin''::text, ''gerencia''::text])');
    w := replace(p.with_check, 'mi_rol() = ''admin''::text', 'mi_rol() = ANY (ARRAY[''admin''::text, ''gerencia''::text])');
    sql := format('alter policy %I on %I.%I', p.policyname, p.schemaname, p.tablename);
    if q is not null then sql := sql || ' using (' || q || ')'; end if;
    if w is not null then sql := sql || ' with check (' || w || ')'; end if;
    execute sql;
  end loop;
end $$;
drop policy if exists ger_tarifas on tarifas;     -- reemplazada por la regla anterior
drop policy if exists ger_ppto on ot_ppto;
drop policy if exists ing_crear on stock_ingresos;
create policy ing_crear on stock_ingresos for insert to authenticated with check (mi_rol() in ('bodega','gerencia','admin'));

-- 2) Bodega administra el catálogo de materiales (todo queda en el registro de cambios)
drop policy if exists bodega_mat on materiales;
create policy bodega_mat on materiales for all to authenticated using (mi_rol() = 'bodega') with check (mi_rol() = 'bodega');

-- Gerencia da de alta trabajadores y los activa o desactiva, pero no los elimina,
-- no toca a administradores/gerencia ni puede dar esos cargos.
drop policy if exists ger_perfil on perfiles;
create policy ger_perfil on perfiles for update to authenticated
  using (mi_rol() = 'gerencia' and rol in ('operario','bodega','jefe'))
  with check (mi_rol() = 'gerencia' and rol in ('operario','bodega','jefe'));

-- 3) Registro de cambios
-- Cada alta, cambio o eliminación que hace un usuario queda anotada con quién, cuándo y qué.
-- Solo el administrador puede leerla; nadie puede modificarla ni borrarla desde la app.
create table if not exists auditoria (
  id bigint generated always as identity primary key,
  fecha timestamptz not null default now(),
  usuario_id uuid,
  usuario_nombre text,
  usuario_rol text,
  seccion text not null,
  accion text not null check (accion in ('crear','modificar','eliminar')),
  tabla text,
  registro text,
  detalle text,
  cambios jsonb
);
create index if not exists auditoria_fecha on auditoria (fecha desc);
create index if not exists auditoria_seccion on auditoria (seccion, fecha desc);
alter table auditoria enable row level security;
drop policy if exists aud_leer on auditoria;
create policy aud_leer on auditoria for select to authenticated using (mi_rol() = 'admin');
revoke all on auditoria from anon, authenticated;
grant select on auditoria to authenticated;

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

do $$ declare x record; begin
  for x in select * from (values ('ots','todo'),('ot_ppto','todo'),('produccion','todo'),('hh_registros','cambios'),('asistencia','cambios'),
      ('materiales','todo'),('consumos','cambios'),('stock_ingresos','todo'),('ot_stock','cambios'),('compras','todo'),('documentos','todo'),
      ('servicios','cambios'),('tarifas','todo'),('maquinas','todo'),('procesos','todo'),('perfiles','cambios'),('config','todo'),
      ('operaciones','todo'),('dias_especiales','todo')) as v(t, m)
  loop
    execute format('drop trigger if exists zz_auditar on %I', x.t);
    execute format('create trigger zz_auditar after insert or update or delete on %I for each row execute function auditar(%L)', x.t, x.m);
  end loop;
end $$;
