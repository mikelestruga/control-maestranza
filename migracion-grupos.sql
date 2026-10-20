-- =====================================================================
--  CONTROL DE TALLER · grupos de materiales y costo promedio ponderado
--  Ejecutar UNA vez en Supabase > SQL Editor > New snippet > Run
-- =====================================================================

-- Grupo del material (ej.: "Discos de corte" agrupa 4½", 7", 9")
alter table materiales add column if not exists grupo text;
create index if not exists materiales_grupo on materiales (grupo);

-- Salida a OT por grupo: guarda el grupo y de qué ítems se descontó
alter table consumos add column if not exists grupo text;
alter table consumos add column if not exists reparto jsonb;

-- Salidas a OT: completa datos, costo y kg. Si es por grupo, usa el
-- precio promedio del grupo y descuenta del tamaño con más stock.
create or replace function consumo_antes() returns trigger
language plpgsql security definer set search_path = public as $$
declare
  m materiales%rowtype; u text; cpp numeric; est boolean; restante numeric; tomar numeric;
  rep jsonb := '[]'::jsonb; todos_kg boolean;
begin
  if new.material_id is null and new.grupo is not null and new.reparto is null then
    select unidad into u from materiales where grupo = new.grupo and activo
      group by unidad order by count(*) desc, unidad limit 1;
    if u is null then raise exception 'El grupo % no tiene materiales activos', new.grupo; end if;
    new.unidad := coalesce(new.unidad, u);
    new.descripcion := coalesce(new.descripcion, new.grupo || ' (grupo)');
    if new.costo_unit is null then
      select case when coalesce(sum(greatest(stock, 0)) filter (where costo_unit is not null), 0) > 0
                  then sum(greatest(stock, 0) * costo_unit) filter (where costo_unit is not null)
                       / sum(greatest(stock, 0)) filter (where costo_unit is not null)
                  else avg(costo_unit) end,
             bool_or(costo_estimado)
        into cpp, est
        from materiales where grupo = new.grupo and activo and unidad = u;
      if cpp is not null then
        new.costo_unit := round(cpp, 2);
        new.estado_costo := case when est then 'estimado' else 'real' end;
      end if;
    end if;
    if new.origen = 'bodega' then
      restante := new.cantidad;
      for m in select * from materiales where grupo = new.grupo and activo and unidad = u order by stock desc, id loop
        exit when restante <= 0;
        tomar := least(restante, greatest(m.stock, 0));
        if tomar > 0 then
          rep := rep || jsonb_build_array(jsonb_build_object('material_id', m.id, 'cantidad', tomar, 'kg_unidad', m.kg_unidad));
          restante := restante - tomar;
        end if;
      end loop;
      if restante > 0 then   -- sin stock suficiente: el resto queda negativo en el de más stock
        select * into m from materiales where grupo = new.grupo and activo and unidad = u order by stock desc, id limit 1;
        rep := rep || jsonb_build_array(jsonb_build_object('material_id', m.id, 'cantidad', restante, 'kg_unidad', m.kg_unidad));
      end if;
      new.reparto := rep;
      if new.kg is null then
        select bool_and(e->>'kg_unidad' is not null), sum((e->>'cantidad')::numeric * (e->>'kg_unidad')::numeric)
          into todos_kg, tomar from jsonb_array_elements(rep) e;
        if todos_kg then new.kg := round(tomar, 2); end if;
      end if;
    end if;
  end if;
  if new.material_id is not null then
    select * into m from materiales where id = new.material_id;
    if new.descripcion is null then new.descripcion := m.nombre; end if;
    if new.unidad is null then new.unidad := m.unidad; end if;
    if new.costo_unit is null and m.costo_unit is not null then
      new.costo_unit := m.costo_unit;
      new.estado_costo := case when m.costo_estimado then 'estimado' else 'real' end;
    end if;
    if new.kg is null and m.kg_unidad is not null then new.kg := round(new.cantidad * m.kg_unidad, 2); end if;
  end if;
  if new.kg is null and lower(coalesce(new.unidad, '')) = 'kg' then new.kg := new.cantidad; end if;
  if new.costo_unit is null then new.estado_costo := 'pendiente';
  elsif new.estado_costo = 'pendiente' then new.estado_costo := 'real';
  end if;
  return new;
end $$;

-- Descuenta (o devuelve al borrar) el stock, también en salidas por grupo
create or replace function consumo_stock() returns trigger
language plpgsql security definer set search_path = public as $$
declare r consumos%rowtype; signo numeric; e jsonb;
begin
  if tg_op = 'INSERT' then r := new; signo := -1; else r := old; signo := 1; end if;
  if r.origen <> 'bodega' then return null; end if;
  if r.reparto is not null then
    for e in select * from jsonb_array_elements(r.reparto) loop
      update materiales set stock = stock + signo * (e->>'cantidad')::numeric where id = (e->>'material_id')::bigint;
    end loop;
  elsif r.material_id is not null then
    update materiales set stock = stock + signo * r.cantidad where id = r.material_id;
  end if;
  return null;
end $$;

-- Ingresos: suma stock y calcula COSTO PROMEDIO PONDERADO
-- (stock actual × costo actual + cantidad × costo nuevo) / (stock + cantidad)
create or replace function ingreso_stock() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  update materiales
     set stock = stock + new.cantidad,
         costo_unit = case
           when new.costo_unit is null then costo_unit
           when costo_unit is null or stock <= 0 then new.costo_unit
           else round((stock * costo_unit + new.cantidad * new.costo_unit) / (stock + new.cantidad), 2)
         end,
         costo_estimado = case when new.costo_unit is not null then false else costo_estimado end,
         kg_unidad = coalesce(kg_unidad, case when new.kg is not null and new.cantidad > 0
                                              then round(new.kg / new.cantidad, 4) end)
   where id = new.material_id;
  return null;
end $$;
