-- =====================================================================
--  CONTROL DE TALLER · compras con OC y stock por proyecto (OT)
--  Ejecutar UNA vez en Supabase > SQL Editor > New snippet > Run
-- =====================================================================

-- Orden de compra (o factura/guía) de material comprado para una OT
create table if not exists compras (
  id bigint generated always as identity primary key,
  ot_id bigint not null references ots(id),
  numero text,
  proveedor text,
  fecha date not null default current_date,
  estado text not null default 'pedida' check (estado in ('pedida','recibida')),
  fecha_recepcion date,
  neto numeric,
  total numeric,
  nota text,
  leida_con_ia boolean not null default false,
  creado_por uuid references perfiles(id) default auth.uid(),
  creado timestamptz not null default now()
);
create index if not exists compras_ot on compras (ot_id);

-- Líneas de la compra = stock propio de la OT (no se mezcla con bodega general)
create table if not exists ot_stock (
  id bigint generated always as identity primary key,
  compra_id bigint not null references compras(id) on delete cascade,
  ot_id bigint not null references ots(id),
  codigo text,
  descripcion text not null,
  unidad text not null default 'un',
  cantidad numeric not null check (cantidad > 0),
  costo_unit numeric check (costo_unit >= 0),            -- neto por unidad; null = pendiente
  kg_unidad numeric check (kg_unidad >= 0),              -- kg por unidad; null = sin peso
  traspasado numeric not null default 0 check (traspasado >= 0),   -- saldo devuelto a bodega general
  creado timestamptz not null default now()
);
create index if not exists ot_stock_ot on ot_stock (ot_id);

-- Las salidas diarias desde el stock de la OT son consumos con origen 'stock_ot'
alter table consumos add column if not exists ot_stock_id bigint references ot_stock(id);
alter table consumos drop constraint if exists consumos_origen_check;
alter table consumos add constraint consumos_origen_check check (origen in ('bodega','compra_directa','stock_ot'));

-- Saldo de una línea (cantidad − salidas − traspasos)
create or replace function ot_stock_saldo(p_id bigint, p_excluir bigint default null) returns numeric
language sql stable security definer set search_path = public as $$
  select s.cantidad - s.traspasado
         - coalesce((select sum(c.cantidad) from consumos c where c.ot_stock_id = s.id and c.id is distinct from p_excluir), 0)
  from ot_stock s where s.id = p_id
$$;

-- Salidas: completa la salida desde la línea del stock de la OT
create or replace function consumo_stock_ot() returns trigger
language plpgsql security definer set search_path = public as $$
declare l ot_stock%rowtype; saldo numeric;
begin
  if new.ot_stock_id is null then return new; end if;
  select * into l from ot_stock where id = new.ot_stock_id;
  if not found then raise exception 'La línea de stock no existe'; end if;
  new.ot_id := l.ot_id;
  new.origen := 'stock_ot';
  new.material_id := null; new.grupo := null;
  if new.descripcion is null then new.descripcion := l.descripcion; end if;
  if new.unidad is null then new.unidad := l.unidad; end if;
  if tg_op = 'INSERT' or new.cantidad is distinct from old.cantidad then
    saldo := ot_stock_saldo(l.id, new.id);
    if new.cantidad > saldo + 0.0001 then
      raise exception 'Saldo insuficiente: quedan % % de %', round(saldo, 2), l.unidad, l.descripcion;
    end if;
  end if;
  if new.costo_unit is null and l.costo_unit is not null then new.costo_unit := l.costo_unit; new.estado_costo := 'real'; end if;
  if new.kg is null and l.kg_unidad is not null then new.kg := round(new.cantidad * l.kg_unidad, 2); end if;
  if new.kg is null and lower(l.unidad) = 'kg' then new.kg := new.cantidad; end if;
  return new;
end $$;
drop trigger if exists consumo_0_stock_ot on consumos;
-- el nombre empieza con 0 para correr antes que consumo_antes (orden alfabético)
create trigger consumo_0_stock_ot before insert or update on consumos
  for each row execute function consumo_stock_ot();

-- Si cambia el precio de la línea (llega la factura), se actualizan sus salidas
create or replace function ot_stock_precio() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if new.costo_unit is distinct from old.costo_unit then
    update consumos set costo_unit = new.costo_unit,
                        estado_costo = case when new.costo_unit is null then 'pendiente' else 'real' end
     where ot_stock_id = new.id;
  end if;
  if new.kg_unidad is distinct from old.kg_unidad then
    update consumos set kg = case when new.kg_unidad is null then null else round(cantidad * new.kg_unidad, 2) end
     where ot_stock_id = new.id;
  end if;
  return new;
end $$;
drop trigger if exists ot_stock_precio on ot_stock;
create trigger ot_stock_precio after update on ot_stock
  for each row execute function ot_stock_precio();

-- Traspasa el saldo (o parte) de una línea a un material de la bodega general
create or replace function traspasar_a_bodega(p_linea bigint, p_material bigint, p_cantidad numeric)
returns void language plpgsql security definer set search_path = public as $$
declare l ot_stock%rowtype; o text;
begin
  if mi_rol() not in ('bodega','jefe','admin') then raise exception 'Sin permiso'; end if;
  select * into l from ot_stock where id = p_linea;
  if p_cantidad <= 0 or p_cantidad > ot_stock_saldo(p_linea) + 0.0001 then raise exception 'Cantidad mayor al saldo'; end if;
  select numero into o from ots where id = l.ot_id;
  update ot_stock set traspasado = traspasado + p_cantidad where id = p_linea;
  insert into stock_ingresos (material_id, cantidad, costo_unit, kg, doc_ref)
  values (p_material, p_cantidad, l.costo_unit,
          case when l.kg_unidad is not null then round(p_cantidad * l.kg_unidad, 2) end,
          'Traspaso desde ' || o);
end $$;
grant execute on function traspasar_a_bodega(bigint, bigint, numeric) to authenticated;
grant execute on function ot_stock_saldo(bigint, bigint) to authenticated;

-- Permisos: bodega, jefe de taller y administración
alter table compras enable row level security;
alter table ot_stock enable row level security;
drop policy if exists compras_leer on compras;   drop policy if exists compras_crear on compras;
drop policy if exists compras_editar on compras; drop policy if exists compras_borrar on compras;
drop policy if exists ots_leer on ot_stock;      drop policy if exists ots_crear on ot_stock;
drop policy if exists ots_editar on ot_stock;    drop policy if exists ots_borrar on ot_stock;
create policy compras_leer   on compras for select to authenticated using (mi_rol() in ('bodega','jefe','admin'));
create policy compras_crear  on compras for insert to authenticated with check (mi_rol() in ('bodega','jefe','admin'));
create policy compras_editar on compras for update to authenticated using (mi_rol() in ('bodega','jefe','admin')) with check (mi_rol() in ('bodega','jefe','admin'));
create policy compras_borrar on compras for delete to authenticated using (mi_rol() = 'admin');
create policy ots_leer   on ot_stock for select to authenticated using (mi_rol() in ('bodega','jefe','admin'));
create policy ots_crear  on ot_stock for insert to authenticated with check (mi_rol() in ('bodega','jefe','admin'));
create policy ots_editar on ot_stock for update to authenticated using (mi_rol() in ('bodega','jefe','admin')) with check (mi_rol() in ('bodega','jefe','admin'));
create policy ots_borrar on ot_stock for delete to authenticated using (mi_rol() = 'admin');
grant all on compras, ot_stock to authenticated;

-- Tope diario de lecturas con IA (lo usa la función leer-oc)
create table if not exists ia_uso (dia date primary key, n int not null default 0);
alter table ia_uso enable row level security;
create or replace function ia_tomar(p_max int) returns int
language plpgsql security definer set search_path = public as $$
declare v int;
begin
  insert into ia_uso(dia, n) values ((now() at time zone 'America/Santiago')::date, 1)
  on conflict (dia) do update set n = ia_uso.n + 1 where ia_uso.n < p_max
  returning n into v;
  return coalesce(v, 0);
end $$;
create or replace function ia_devolver() returns void
language sql security definer set search_path = public as $$
  update ia_uso set n = greatest(n - 1, 0) where dia = (now() at time zone 'America/Santiago')::date;
$$;
revoke all on function ia_tomar(int) from public, anon, authenticated;
revoke all on function ia_devolver() from public, anon, authenticated;
