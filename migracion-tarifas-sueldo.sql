-- =====================================================================
--  CONTROL DE TALLER · costo HH calculado desde el sueldo del mes
--  Ejecutar UNA vez en Supabase > SQL Editor > New snippet > Run
--
--  Cada categoría puede guardar el sueldo total del mes (costo empresa), las horas
--  que ese sueldo cubre y el multiplicador de la hora extra. Con eso la app calcula:
--     costo hora normal = sueldo del mes ÷ horas del mes
--     costo hora extra  = costo hora normal × multiplicador
--  Si no se llenan el sueldo y las horas, siguen valiendo los valores escritos a mano.
-- =====================================================================
alter table tarifas add column if not exists sueldo_mes numeric check (sueldo_mes >= 0);
alter table tarifas add column if not exists horas_mes numeric check (horas_mes > 0);
alter table tarifas add column if not exists mult_extra numeric not null default 1.5 check (mult_extra >= 1);

-- Mantiene los costos por hora coherentes con el sueldo, aunque se edite desde otro lado
create or replace function tarifa_calcula() returns trigger
language plpgsql as $$
begin
  if new.sueldo_mes is not null and new.horas_mes is not null then
    new.costo_hh := round(new.sueldo_mes / new.horas_mes);
    new.costo_hh_extra := round(new.costo_hh * new.mult_extra);
  elsif new.costo_hh_extra is null and new.costo_hh is not null then
    new.costo_hh_extra := round(new.costo_hh * new.mult_extra);
  end if;
  return new;
end $$;
drop trigger if exists tarifa_calcula on tarifas;
create trigger tarifa_calcula before insert or update on tarifas
  for each row execute function tarifa_calcula();
