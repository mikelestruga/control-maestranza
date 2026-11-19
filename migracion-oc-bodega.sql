-- Migración: órdenes de compra de bodega con IA y acuse de recepción (parcial o total).
-- Ejecutar una vez en Supabase > SQL Editor. Requiere migracion-compras-ot.sql, migracion-documentos.sql y el registro de cambios.

-- ---------- Órdenes de compra de bodega (con recepción parcial o total) ----
-- Una compra sin OT (ot_id null) es una OC para reponer la bodega general. Sus líneas
-- apuntan a un material del catálogo; al acusar recepción entran a stock_ingresos.
alter table compras alter column ot_id drop not null;
alter table compras drop constraint if exists compras_estado_check;
alter table compras add constraint compras_estado_check check (estado in ('pedida','parcial','recibida'));
alter table documentos alter column ot_id drop not null;
create table if not exists oc_lineas (
  id bigint generated always as identity primary key,
  compra_id bigint not null references compras(id) on delete cascade,
  material_id bigint references materiales(id),
  codigo text,
  descripcion text not null,
  unidad text not null default 'un',
  cantidad numeric not null check (cantidad > 0),
  recibido numeric not null default 0 check (recibido >= 0),
  costo_unit numeric check (costo_unit >= 0),          -- neto por unidad de la OC; null = pendiente
  kg_unidad numeric check (kg_unidad >= 0),            -- kg por unidad de la OC
  factor numeric not null default 1 check (factor > 0), -- unidades del material por cada unidad de la OC
  creado timestamptz not null default now()
);
create index if not exists oc_lineas_compra on oc_lineas (compra_id);
create index if not exists oc_lineas_material on oc_lineas (material_id);
alter table oc_lineas enable row level security;
drop policy if exists ocl_leer on oc_lineas;   drop policy if exists ocl_crear on oc_lineas;
drop policy if exists ocl_editar on oc_lineas; drop policy if exists ocl_borrar on oc_lineas;
create policy ocl_leer   on oc_lineas for select to authenticated using (mi_rol() in ('bodega','jefe','gerencia','admin'));
create policy ocl_crear  on oc_lineas for insert to authenticated with check (mi_rol() in ('bodega','jefe','gerencia','admin'));
create policy ocl_editar on oc_lineas for update to authenticated using (mi_rol() in ('bodega','jefe','gerencia','admin')) with check (mi_rol() in ('bodega','jefe','gerencia','admin'));
create policy ocl_borrar on oc_lineas for delete to authenticated using (mi_rol() in ('admin','gerencia'));
revoke all on oc_lineas from anon, authenticated;
grant select, insert, update, delete on oc_lineas to authenticated;

-- Acusar recepción: p_lineas = [{"id":…, "cantidad":…, "material_id":…, "factor":…}]
create or replace function recibir_oc(p_compra bigint, p_lineas jsonb) returns void
language plpgsql security definer set search_path = public as $$
declare c compras%rowtype; x jsonb; l oc_lineas%rowtype; q numeric; mat bigint; f numeric; n int := 0; pend int;
begin
  if mi_rol() not in ('bodega','gerencia','admin') then raise exception 'Sin permiso para acusar recepción'; end if;
  select * into c from compras where id = p_compra for update;
  if not found or c.ot_id is not null then raise exception 'La compra no es una OC de bodega'; end if;
  for x in select * from jsonb_array_elements(p_lineas) loop
    q := nullif(x->>'cantidad','')::numeric;
    if q is null or q <= 0 then continue; end if;
    select * into l from oc_lineas where id = (x->>'id')::bigint and compra_id = p_compra for update;
    if not found then raise exception 'Línea no encontrada'; end if;
    if q > l.cantidad - l.recibido + 0.0001 then raise exception 'Recibido mayor a lo pendiente: %', l.descripcion; end if;
    mat := coalesce(nullif(x->>'material_id','')::bigint, l.material_id);
    if mat is null then raise exception 'Falta asignar un material a: %', l.descripcion; end if;
    f := coalesce(nullif(x->>'factor','')::numeric, l.factor);
    if f <= 0 then raise exception 'Equivalencia inválida en: %', l.descripcion; end if;
    update oc_lineas set recibido = recibido + q, material_id = mat, factor = f where id = l.id;
    insert into stock_ingresos (material_id, cantidad, costo_unit, kg, doc_ref)
    values (mat, round(q * f, 4), case when l.costo_unit is not null then round(l.costo_unit / f, 4) end,
            case when l.kg_unidad is not null then round(q * l.kg_unidad, 2) end,
            'OC ' || coalesce(c.numero, 's/n') || coalesce(' · ' || c.proveedor, ''));
    n := n + 1;
  end loop;
  if n = 0 then raise exception 'No hay cantidades para recibir'; end if;
  select count(*) into pend from oc_lineas where compra_id = p_compra and recibido < cantidad - 0.0001;
  update compras set estado = case when pend = 0 then 'recibida' else 'parcial' end,
                     fecha_recepcion = case when pend = 0 then current_date else fecha_recepcion end
   where id = p_compra;
end $$;
revoke all on function recibir_oc(bigint, jsonb) from public, anon;
grant execute on function recibir_oc(bigint, jsonb) to authenticated;

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
         || ' · OT ' || coalesce((select numero from ots where id = (r->>'ot_id')::bigint), '?');
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
    when 'consumos' then 'Bodega' when 'stock_ingresos' then 'Bodega' when 'ot_stock' then 'Bodega'
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

drop trigger if exists zz_auditar on oc_lineas;
create trigger zz_auditar after insert or update or delete on oc_lineas for each row execute function auditar('cambios');
