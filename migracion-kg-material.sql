-- =====================================================================
--  CONTROL DE TALLER · agregar kg de material (ingresos y salidas a OT)
--  Ejecutar UNA vez en Supabase > SQL Editor > New snippet > Run
-- =====================================================================

-- Peso por unidad de cada material (kg por m, kg por unidad, etc.)
alter table materiales add column if not exists kg_unidad numeric check (kg_unidad >= 0);
update materiales set kg_unidad = 1 where kg_unidad is null and lower(unidad) = 'kg';

-- Kg de cada movimiento: se calcula solo con kg_unidad, o se ingresa (pesaje, guía)
alter table stock_ingresos add column if not exists kg numeric check (kg >= 0);
alter table consumos       add column if not exists kg numeric check (kg >= 0);

-- Salidas a OT: completa descripción, unidad, costo y kg desde el catálogo
create or replace function consumo_antes() returns trigger
language plpgsql security definer set search_path = public as $$
declare m materiales%rowtype;
begin
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

-- Ingresos a bodega: kg automático si el material tiene kg por unidad
create or replace function ingreso_antes() returns trigger
language plpgsql security definer set search_path = public as $$
declare m materiales%rowtype;
begin
  select * into m from materiales where id = new.material_id;
  if new.kg is null then
    if m.kg_unidad is not null then new.kg := round(new.cantidad * m.kg_unidad, 2);
    elsif lower(m.unidad) = 'kg' then new.kg := new.cantidad;
    end if;
  end if;
  return new;
end $$;
drop trigger if exists ingreso_antes on stock_ingresos;
create trigger ingreso_antes before insert on stock_ingresos
  for each row execute function ingreso_antes();

-- Suma al stock, actualiza el último costo y, si el material no tenía
-- kg por unidad, lo aprende del pesaje de este ingreso
create or replace function ingreso_stock() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  update materiales
     set stock = stock + new.cantidad,
         costo_unit = coalesce(new.costo_unit, costo_unit),
         costo_estimado = case when new.costo_unit is not null then false else costo_estimado end,
         kg_unidad = coalesce(kg_unidad, case when new.kg is not null and new.cantidad > 0
                                              then round(new.kg / new.cantidad, 4) end)
   where id = new.material_id;
  return null;
end $$;

-- Completa kg de movimientos ya registrados
update consumos c set kg = round(c.cantidad * m.kg_unidad, 2)
  from materiales m where c.kg is null and c.material_id = m.id and m.kg_unidad is not null;
update consumos set kg = cantidad where kg is null and lower(coalesce(unidad, '')) = 'kg';
update stock_ingresos i set kg = round(i.cantidad * m.kg_unidad, 2)
  from materiales m where i.kg is null and i.material_id = m.id and m.kg_unidad is not null;
