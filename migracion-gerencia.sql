-- =====================================================================
--  CONTROL DE TALLER · nuevo cargo "Gerencia"
--  Gerencia ve TODA la data (incluidos costos y cotizaciones), valida horas
--  y trabaja como jefe de taller, pero NO entra a Ajustes ni cambia claves:
--  eso queda solo para el Administrador.
--  Ejecutar UNA vez en Supabase > SQL Editor > New snippet > Run
-- =====================================================================

-- 1) El rol nuevo
do $$
declare c record;
begin
  for c in select conname from pg_constraint
            where conrelid = 'public.perfiles'::regclass and contype = 'c' and pg_get_constraintdef(oid) ilike '%rol%'
  loop
    execute format('alter table perfiles drop constraint %I', c.conname);
  end loop;
end $$;
alter table perfiles add constraint perfiles_rol_check
  check (rol in ('operario','bodega','jefe','gerencia','admin'));

-- 2) Gerencia hereda todo permiso que hoy tiene el jefe de taller
--    (se agrega 'gerencia' a cada regla que nombra a 'jefe')
do $$
declare p record; q text; w text; sql text;
begin
  for p in
    select schemaname, tablename, policyname, qual, with_check from pg_policies
     where schemaname in ('public','storage')
       and (coalesce(qual,'') like '%''jefe''%' or coalesce(with_check,'') like '%''jefe''%')
       and coalesce(qual,'') not like '%gerencia%' and coalesce(with_check,'') not like '%gerencia%'
  loop
    q := replace(p.qual,       '''jefe''::text', '''jefe''::text, ''gerencia''::text');
    w := replace(p.with_check, '''jefe''::text', '''jefe''::text, ''gerencia''::text');
    sql := format('alter policy %I on %I.%I', p.policyname, p.schemaname, p.tablename);
    if q is not null then sql := sql || ' using (' || q || ')'; end if;
    if w is not null then sql := sql || ' with check (' || w || ')'; end if;
    execute sql;
  end loop;
end $$;

-- 3) Gerencia puede LEER costos, tarifas y cotizaciones (no modificarlos)
drop policy if exists admin_costo on hh_costo;
create policy admin_costo on hh_costo for select to authenticated using (mi_rol() in ('admin','gerencia'));
drop policy if exists ger_tarifas on tarifas;
create policy ger_tarifas on tarifas for select to authenticated using (mi_rol() = 'gerencia');
drop policy if exists ger_ppto on ot_ppto;
create policy ger_ppto on ot_ppto for select to authenticated using (mi_rol() = 'gerencia');

-- 4) Traspaso de saldo a bodega: también para gerencia
create or replace function traspasar_a_bodega(p_linea bigint, p_material bigint, p_cantidad numeric)
returns void language plpgsql security definer set search_path = public as $$
declare l ot_stock%rowtype; o text;
begin
  if mi_rol() not in ('bodega','jefe','gerencia','admin') then raise exception 'Sin permiso'; end if;
  select * into l from ot_stock where id = p_linea;
  if p_cantidad <= 0 or p_cantidad > ot_stock_saldo(p_linea) + 0.0001 then raise exception 'Cantidad mayor al saldo'; end if;
  select numero into o from ots where id = l.ot_id;
  update ot_stock set traspasado = traspasado + p_cantidad where id = p_linea;
  insert into stock_ingresos (material_id, cantidad, costo_unit, kg, doc_ref)
  values (p_material, p_cantidad, l.costo_unit,
          case when l.kg_unidad is not null then round(p_cantidad * l.kg_unidad, 2) end,
          'Traspaso desde ' || o);
end $$;

-- Para dar el cargo: en la app, Ajustes › Trabajadores › (el trabajador) › Rol = Gerencia.
