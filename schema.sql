-- =====================================================================
--  CONTROL DE TALLER · esquema para Supabase (PostgreSQL)
--  Pegar completo en Supabase > SQL Editor > New query > Run
--  Es seguro ejecutarlo una sola vez en un proyecto nuevo.
-- =====================================================================

-- ---------- Tablas de configuración y catálogos ----------------------

create table config (
  clave text primary key,
  valor numeric not null,
  descripcion text
);
insert into config values
  ('gg_pct',        18, 'Gastos generales: % que se suma al costo directo de cada OT'),
  ('jornada_horas',  8, 'Horas de jornada normal por día (lo que pase de esto es hora extra)'),
  ('colacion_min',  60, 'Minutos de colación que se descuentan de la asistencia');

-- Costo de la HH por categoría/persona. Solo el administrador puede verlo.
create table tarifas (
  id bigint generated always as identity primary key,
  nombre text not null unique,
  costo_hh numeric not null check (costo_hh >= 0),
  costo_hh_extra numeric not null check (costo_hh_extra >= 0),
  estimada boolean not null default false
);

create table perfiles (
  id uuid primary key references auth.users(id) on delete cascade,
  nombre text not null,
  usuario text,
  rol text not null default 'operario' check (rol in ('operario','bodega','jefe','gerencia','admin')),
  tarifa_id bigint references tarifas(id),
  activo boolean not null default false
);

create table operaciones (
  id bigint generated always as identity primary key,
  nombre text not null unique,
  activa boolean not null default true
);

create table maquinas (
  id bigint generated always as identity primary key,
  nombre text not null unique,
  costo_hh numeric not null default 0 check (costo_hh >= 0),
  estimada boolean not null default false,
  activa boolean not null default true
);

-- Costo de procesos propios (pintura, tratamiento térmico) por unidad
create table procesos (
  id bigint generated always as identity primary key,
  nombre text not null unique,
  tipo text not null default 'otro' check (tipo in ('pintura','tratamiento_termico','ensayo','transporte','otro')),
  unidad text not null,
  costo_unit numeric not null default 0 check (costo_unit >= 0),
  estimada boolean not null default false
);

create table materiales (
  id bigint generated always as identity primary key,
  codigo text,
  nombre text not null,
  unidad text not null default 'un',
  costo_unit numeric check (costo_unit >= 0),          -- null = sin dato
  costo_estimado boolean not null default false,
  kg_unidad numeric check (kg_unidad >= 0),          -- kg por unidad (kg/m, kg/un); null = sin dato
  grupo text,                                        -- ej.: 'Discos de corte' agrupa varios tamaños
  stock numeric not null default 0,
  stock_min numeric not null default 0,
  activo boolean not null default true
);

create table dias_especiales (          -- feriados y días en que todo es hora extra
  fecha date primary key,
  descripcion text
);

-- ---------- Órdenes de trabajo ---------------------------------------

create table ots (
  id bigint generated always as identity primary key,
  numero text not null unique,
  cliente text not null,
  descripcion text,
  estado text not null default 'en_proceso' check (estado in ('cotizada','en_proceso','terminada','entregada')),
  cantidad numeric not null default 1 check (cantidad > 0),   -- piezas de la OT (para costo unitario)
  terminadas numeric not null default 0 check (terminadas >= 0),
  kg_cotizados numeric check (kg_cotizados >= 0),              -- peso total cotizado
  kg_producidos numeric not null default 0,                    -- se suma solo desde 'produccion'
  unidad text not null default 'pza',
  fecha_entrega date,
  ppto_horas numeric,                                         -- HH estimadas en la cotización
  creada timestamptz not null default now()
);

-- Valores de la cotización: solo administrador
create table ot_ppto (
  ot_id bigint primary key references ots(id) on delete cascade,
  ppto_hh numeric not null default 0,
  ppto_material numeric not null default 0,
  ppto_servicios numeric not null default 0,
  ppto_maquina numeric not null default 0,
  precio_venta numeric not null default 0
);

-- ---------- Registros diarios ----------------------------------------

create table hh_registros (
  id bigint generated always as identity primary key,
  perfil_id uuid not null references perfiles(id) default auth.uid(),
  ot_id bigint references ots(id),
  operacion_id bigint references operaciones(id),
  maquina_id bigint references maquinas(id),
  tipo text not null default 'directa' check (tipo in ('directa','retrabajo','indirecta','improductiva')),
  motivo text,
  fecha date,
  inicio timestamptz,
  fin timestamptz,
  horas numeric not null default 0 check (horas >= 0 and horas <= 24),
  horas_extra numeric not null default 0 check (horas_extra >= 0),
  manual boolean not null default false,
  extra_manual boolean not null default false,
  estado text not null default 'pendiente' check (estado in ('pendiente','aprobado')),
  nota text,
  tarifa_id bigint references tarifas(id),
  aprobado_por uuid references perfiles(id),
  creado timestamptz not null default now(),
  check ((tipo in ('directa','retrabajo')) = (ot_id is not null)),
  check (horas_extra <= horas)
);
create index on hh_registros (fecha);
create index on hh_registros (ot_id);
create unique index un_hh_abierto on hh_registros (perfil_id) where fin is null and inicio is not null;

-- Costo congelado al momento de registrar (no cambia si después se edita la tarifa)
create table hh_costo (
  registro_id bigint primary key references hh_registros(id) on delete cascade,
  costo_hh numeric not null default 0,          -- parte en horario normal
  costo_extra numeric not null default 0,       -- parte en horas extra
  costo_maquina numeric not null default 0,
  estimado boolean not null default false
);

create table asistencia (
  id bigint generated always as identity primary key,
  perfil_id uuid not null references perfiles(id) default auth.uid(),
  fecha date not null,
  entrada timestamptz,
  salida timestamptz,
  unique (perfil_id, fecha)
);

create table consumos (
  id bigint generated always as identity primary key,
  ot_id bigint not null references ots(id),
  material_id bigint references materiales(id),
  descripcion text,
  cantidad numeric not null check (cantidad > 0),
  kg numeric check (kg >= 0),
  grupo text,                                        -- salida por grupo (precio promedio del grupo)
  reparto jsonb,                                     -- de qué ítems del grupo se descontó el stock
  unidad text,
  costo_unit numeric check (costo_unit >= 0),
  estado_costo text not null default 'pendiente' check (estado_costo in ('real','estimado','pendiente')),
  origen text not null default 'bodega' check (origen in ('bodega','compra_directa')),
  doc_ref text,
  fecha date not null default current_date,
  registrado_por uuid references perfiles(id) default auth.uid(),
  creado timestamptz not null default now(),
  total numeric generated always as (coalesce(cantidad * costo_unit, 0)) stored,
  check (material_id is not null or descripcion is not null)
);
create index on consumos (ot_id);

create table servicios (
  id bigint generated always as identity primary key,
  ot_id bigint not null references ots(id),
  tipo text not null default 'otro' check (tipo in ('pintura','tratamiento_termico','ensayo','transporte','otro')),
  proceso_id bigint references procesos(id),
  descripcion text,
  proveedor text,                                  -- vacío = proceso propio del taller
  cantidad numeric not null default 1 check (cantidad > 0),
  unidad text,
  costo_unit numeric check (costo_unit >= 0),
  estado_costo text not null default 'pendiente' check (estado_costo in ('real','estimado','pendiente')),
  doc_ref text,
  fecha date not null default current_date,
  registrado_por uuid references perfiles(id) default auth.uid(),
  creado timestamptz not null default now(),
  total numeric generated always as (coalesce(cantidad * costo_unit, 0)) stored,
  check (proceso_id is not null or descripcion is not null)
);
create index on servicios (ot_id);

create table stock_ingresos (
  id bigint generated always as identity primary key,
  material_id bigint not null references materiales(id),
  cantidad numeric not null check (cantidad > 0),
  kg numeric check (kg >= 0),
  costo_unit numeric check (costo_unit >= 0),
  doc_ref text,
  fecha date not null default current_date,
  registrado_por uuid references perfiles(id) default auth.uid(),
  creado timestamptz not null default now()
);

-- ---------- Funciones y triggers -------------------------------------

create or replace function mi_rol() returns text
language sql stable security definer set search_path = public as $$
  select rol from perfiles where id = auth.uid() and activo
$$;

-- Cada usuario nuevo de Supabase Auth recibe un perfil.
-- El primero en crearse queda como administrador activo; los demás quedan
-- inactivos (sin acceso) hasta que el administrador los active desde la app.
create or replace function nuevo_usuario() returns trigger
language plpgsql security definer set search_path = public as $$
declare primero boolean := not exists (select 1 from perfiles);
begin
  insert into perfiles (id, nombre, usuario, rol, activo)
  values (new.id,
          coalesce(new.raw_user_meta_data->>'nombre', split_part(new.email, '@', 1)),
          split_part(new.email, '@', 1),
          case when primero then 'admin' else 'operario' end,
          primero);
  return new;
end $$;
create trigger al_crear_usuario after insert on auth.users
  for each row execute function nuevo_usuario();

-- HH: fecha, tarifa, horas y reparto normal/extra
create or replace function hh_antes() returns trigger
language plpgsql security definer set search_path = public as $$
declare jor numeric; previas numeric; especial boolean;
begin
  if new.fecha is null then
    new.fecha := (coalesce(new.inicio, now()) at time zone 'America/Santiago')::date;
  end if;
  if new.tarifa_id is null then
    select tarifa_id into new.tarifa_id from perfiles where id = new.perfil_id;
  end if;
  if new.fin is not null and not new.manual and new.inicio is not null then
    new.horas := round(extract(epoch from (new.fin - new.inicio)) / 3600.0, 2);
  end if;
  if (new.fin is not null or new.manual) and not new.extra_manual
     and (tg_op = 'INSERT' or old.fin is null or new.horas is distinct from old.horas
          or new.fecha is distinct from old.fecha) then
    select valor into jor from config where clave = 'jornada_horas';
    select coalesce(sum(horas), 0) into previas from hh_registros
     where perfil_id = new.perfil_id and fecha = new.fecha
       and id < new.id and (fin is not null or manual);   -- solo registros anteriores del día
    especial := extract(dow from new.fecha) = 0
                or exists (select 1 from dias_especiales where fecha = new.fecha);
    new.horas_extra := case when especial then new.horas
                            else greatest(0, least(new.horas, previas + new.horas - coalesce(jor, 8))) end;
  end if;
  return new;
end $$;
create trigger hh_antes before insert or update on hh_registros
  for each row execute function hh_antes();

create or replace function hh_despues() returns trigger
language plpgsql security definer set search_path = public as $$
declare t tarifas%rowtype; m maquinas%rowtype; ch numeric := 0; ce numeric := 0; cm numeric := 0; est boolean := false;
begin
  if new.fin is null and not new.manual then return new; end if;   -- tarea aún abierta
  select * into t from tarifas where id = new.tarifa_id;
  if found then
    ch := (new.horas - new.horas_extra) * t.costo_hh;
    ce := new.horas_extra * t.costo_hh_extra;
    est := t.estimada;
  else
    est := true;                                                   -- sin tarifa: costo 0, marcado estimado
  end if;
  if new.maquina_id is not null then
    select * into m from maquinas where id = new.maquina_id;
    if found then cm := new.horas * m.costo_hh; est := est or m.estimada; end if;
  end if;
  insert into hh_costo (registro_id, costo_hh, costo_extra, costo_maquina, estimado)
  values (new.id, ch, ce, cm, est)
  on conflict (registro_id) do update
    set costo_hh = excluded.costo_hh, costo_extra = excluded.costo_extra,
        costo_maquina = excluded.costo_maquina, estimado = excluded.estimado;
  return new;
end $$;
create trigger hh_despues after insert or update on hh_registros
  for each row execute function hh_despues();

-- Consumos: completa datos y costo desde el catálogo
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
create trigger consumo_antes before insert or update on consumos
  for each row execute function consumo_antes();

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
create trigger consumo_stock after insert or delete on consumos
  for each row execute function consumo_stock();

-- Servicios: completa datos y costo desde el proceso del catálogo
create or replace function servicio_antes() returns trigger
language plpgsql security definer set search_path = public as $$
declare p procesos%rowtype;
begin
  if new.proceso_id is not null then
    select * into p from procesos where id = new.proceso_id;
    if new.descripcion is null then new.descripcion := p.nombre; end if;
    if new.unidad is null then new.unidad := p.unidad; end if;
    new.tipo := p.tipo;
    if new.costo_unit is null then
      new.costo_unit := p.costo_unit;
      new.estado_costo := case when p.estimada then 'estimado' else 'real' end;
    end if;
  end if;
  if new.costo_unit is null then new.estado_costo := 'pendiente';
  elsif new.estado_costo = 'pendiente' then new.estado_costo := 'real';
  end if;
  return new;
end $$;
create trigger servicio_antes before insert or update on servicios
  for each row execute function servicio_antes();

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
create trigger ingreso_antes before insert on stock_ingresos
  for each row execute function ingreso_antes();

-- Suma al stock, actualiza el último costo y, si el material no tenía
-- kg por unidad, lo aprende del pesaje de este ingreso
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
create trigger ingreso_stock after insert on stock_ingresos
  for each row execute function ingreso_stock();

-- ---------- Permisos por rol (RLS) -----------------------------------
-- operario: registra sus horas · bodega: consumos y stock
-- jefe: valida horas, OT y servicios · gerencia: lo mismo y además ve todos los costos (solo lectura)
-- admin: todo, incluidos costos, ajustes de la plataforma y cambio de claves

alter table config          enable row level security;
alter table tarifas         enable row level security;
alter table perfiles        enable row level security;
alter table operaciones     enable row level security;
alter table maquinas        enable row level security;
alter table procesos        enable row level security;
alter table materiales      enable row level security;
alter table dias_especiales enable row level security;
alter table ots             enable row level security;
alter table ot_ppto         enable row level security;
alter table hh_registros    enable row level security;
alter table hh_costo        enable row level security;
alter table asistencia      enable row level security;
alter table consumos        enable row level security;
alter table servicios       enable row level security;
alter table stock_ingresos  enable row level security;

-- Lectura abierta para usuarios con sesión
create policy leer_config   on config          for select to authenticated using (mi_rol() is not null);
create policy leer_perfiles on perfiles        for select to authenticated using (mi_rol() is not null);
create policy leer_oper     on operaciones     for select to authenticated using (mi_rol() is not null);
create policy leer_maq      on maquinas        for select to authenticated using (mi_rol() is not null);
create policy leer_dias     on dias_especiales for select to authenticated using (mi_rol() is not null);
create policy leer_ots      on ots             for select to authenticated using (mi_rol() is not null);

-- Solo administrador
create policy admin_config  on config      for all to authenticated using (mi_rol() = 'admin') with check (mi_rol() = 'admin');
create policy admin_tarifas on tarifas     for all to authenticated using (mi_rol() = 'admin') with check (mi_rol() = 'admin');
create policy admin_perfil  on perfiles    for update to authenticated using (mi_rol() = 'admin') with check (mi_rol() = 'admin');
create policy admin_oper    on operaciones for all to authenticated using (mi_rol() = 'admin') with check (mi_rol() = 'admin');
create policy admin_maq     on maquinas    for all to authenticated using (mi_rol() = 'admin') with check (mi_rol() = 'admin');
create policy admin_dias    on dias_especiales for all to authenticated using (mi_rol() = 'admin') with check (mi_rol() = 'admin');
create policy admin_ppto    on ot_ppto     for all to authenticated using (mi_rol() = 'admin') with check (mi_rol() = 'admin');
create policy admin_costo   on hh_costo    for select to authenticated using (mi_rol() in ('admin','gerencia'));
create policy ger_tarifas   on tarifas     for select to authenticated using (mi_rol() = 'gerencia');
create policy ger_ppto      on ot_ppto     for select to authenticated using (mi_rol() = 'gerencia');

-- Catálogos de bodega y servicios
create policy leer_mat   on materiales for select to authenticated using (mi_rol() in ('bodega','jefe','gerencia','admin'));
create policy admin_mat  on materiales for all to authenticated using (mi_rol() = 'admin') with check (mi_rol() = 'admin');
create policy leer_proc  on procesos   for select to authenticated using (mi_rol() in ('jefe','gerencia','admin'));
create policy admin_proc on procesos   for all to authenticated using (mi_rol() = 'admin') with check (mi_rol() = 'admin');

-- OT: jefe y admin crean y editan
create policy jefe_ots_ins on ots for insert to authenticated with check (mi_rol() in ('jefe','gerencia','admin'));
create policy jefe_ots_upd on ots for update to authenticated using (mi_rol() in ('jefe','gerencia','admin')) with check (mi_rol() in ('jefe','gerencia','admin'));
create policy admin_ots_del on ots for delete to authenticated using (mi_rol() = 'admin');

-- Horas: cada uno ve y registra las suyas; jefe y admin ven y corrigen todas
create policy hh_leer on hh_registros for select to authenticated
  using (perfil_id = auth.uid() or mi_rol() in ('jefe','gerencia','admin'));
create policy hh_crear on hh_registros for insert to authenticated
  with check ((perfil_id = auth.uid() and estado = 'pendiente' and mi_rol() is not null) or mi_rol() in ('jefe','gerencia','admin'));
create policy hh_editar on hh_registros for update to authenticated
  using ((perfil_id = auth.uid() and fin is null and estado = 'pendiente') or mi_rol() in ('jefe','gerencia','admin'))
  with check ((perfil_id = auth.uid() and estado = 'pendiente') or mi_rol() in ('jefe','gerencia','admin'));
create policy hh_borrar on hh_registros for delete to authenticated using (mi_rol() in ('jefe','gerencia','admin'));

create policy asis_leer on asistencia for select to authenticated
  using (perfil_id = auth.uid() or mi_rol() in ('jefe','gerencia','admin'));
create policy asis_crear on asistencia for insert to authenticated
  with check ((perfil_id = auth.uid() and mi_rol() is not null) or mi_rol() in ('jefe','gerencia','admin'));
create policy asis_editar on asistencia for update to authenticated
  using (perfil_id = auth.uid() or mi_rol() in ('jefe','gerencia','admin'))
  with check (perfil_id = auth.uid() or mi_rol() in ('jefe','gerencia','admin'));
create policy asis_borrar on asistencia for delete to authenticated using (mi_rol() = 'admin');

-- Consumos y servicios
create policy cons_leer on consumos for select to authenticated using (mi_rol() in ('bodega','jefe','gerencia','admin'));
create policy cons_crear on consumos for insert to authenticated with check (mi_rol() in ('bodega','jefe','gerencia','admin'));
create policy cons_admin_upd on consumos for update to authenticated using (mi_rol() = 'admin') with check (mi_rol() = 'admin');
create policy cons_admin_del on consumos for delete to authenticated using (mi_rol() = 'admin');

create policy serv_leer on servicios for select to authenticated using (mi_rol() in ('jefe','gerencia','admin'));
create policy serv_crear on servicios for insert to authenticated with check (mi_rol() in ('jefe','gerencia','admin'));
create policy serv_admin_upd on servicios for update to authenticated using (mi_rol() = 'admin') with check (mi_rol() = 'admin');
create policy serv_admin_del on servicios for delete to authenticated using (mi_rol() = 'admin');

create policy ing_leer on stock_ingresos for select to authenticated using (mi_rol() in ('bodega','jefe','gerencia','admin'));
create policy ing_crear on stock_ingresos for insert to authenticated with check (mi_rol() in ('bodega','admin'));

-- Vista de horas con su costo. Respeta los permisos de quien consulta:
-- quien no es administrador ve las columnas de costo vacías.
create view v_hh with (security_invoker = true) as
  select r.*, c.costo_hh, c.costo_extra, c.costo_maquina, c.estimado as costo_estimado
  from hh_registros r left join hh_costo c on c.registro_id = r.id;

-- ---------- Producción en kg ----------------------------------------

-- Registro de producción terminada: lo ingresa el jefe de taller
create table if not exists produccion (
  id bigint generated always as identity primary key,
  ot_id bigint not null references ots(id),
  fecha date not null default current_date,
  kg numeric not null check (kg > 0),
  piezas numeric not null default 0 check (piezas >= 0),
  nota text,
  registrado_por uuid references perfiles(id) default auth.uid(),
  creado timestamptz not null default now()
);
create index if not exists produccion_ot on produccion (ot_id);
create index if not exists produccion_fecha on produccion (fecha);

-- Mantiene en la OT el total de kg y de piezas terminadas
create or replace function produccion_totales() returns trigger
language plpgsql security definer set search_path = public as $$
declare oid bigint := coalesce(new.ot_id, old.ot_id);
begin
  update ots set
    kg_producidos = (select coalesce(sum(kg), 0) from produccion where ot_id = oid),
    terminadas    = (select coalesce(sum(piezas), 0) from produccion where ot_id = oid)
  where id = oid;
  if tg_op = 'UPDATE' and old.ot_id <> new.ot_id then
    update ots set
      kg_producidos = (select coalesce(sum(kg), 0) from produccion where ot_id = old.ot_id),
      terminadas    = (select coalesce(sum(piezas), 0) from produccion where ot_id = old.ot_id)
    where id = old.ot_id;
  end if;
  return null;
end $$;
drop trigger if exists produccion_totales on produccion;
create trigger produccion_totales after insert or update or delete on produccion
  for each row execute function produccion_totales();

alter table produccion enable row level security;
drop policy if exists prod_leer on produccion;
drop policy if exists prod_crear on produccion;
drop policy if exists prod_editar on produccion;
drop policy if exists prod_borrar on produccion;
create policy prod_leer   on produccion for select to authenticated using (mi_rol() in ('jefe','gerencia','admin'));
create policy prod_crear  on produccion for insert to authenticated with check (mi_rol() in ('jefe','gerencia','admin'));
create policy prod_editar on produccion for update to authenticated using (mi_rol() in ('jefe','gerencia','admin')) with check (mi_rol() in ('jefe','gerencia','admin'));
create policy prod_borrar on produccion for delete to authenticated using (mi_rol() in ('jefe','gerencia','admin'));

grant all on produccion to authenticated;

-- ---------- Compras con OC y stock por OT ---------------------------

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
grant execute on function traspasar_a_bodega(bigint, bigint, numeric) to authenticated;
grant execute on function ot_stock_saldo(bigint, bigint) to authenticated;

-- Permisos: bodega, jefe de taller y administración
alter table compras enable row level security;
alter table ot_stock enable row level security;
drop policy if exists compras_leer on compras;   drop policy if exists compras_crear on compras;
drop policy if exists compras_editar on compras; drop policy if exists compras_borrar on compras;
drop policy if exists ots_leer on ot_stock;      drop policy if exists ots_crear on ot_stock;
drop policy if exists ots_editar on ot_stock;    drop policy if exists ots_borrar on ot_stock;
create policy compras_leer   on compras for select to authenticated using (mi_rol() in ('bodega','jefe','gerencia','admin'));
create policy compras_crear  on compras for insert to authenticated with check (mi_rol() in ('bodega','jefe','gerencia','admin'));
create policy compras_editar on compras for update to authenticated using (mi_rol() in ('bodega','jefe','gerencia','admin')) with check (mi_rol() in ('bodega','jefe','gerencia','admin'));
create policy compras_borrar on compras for delete to authenticated using (mi_rol() = 'admin');
create policy ots_leer   on ot_stock for select to authenticated using (mi_rol() in ('bodega','jefe','gerencia','admin'));
create policy ots_crear  on ot_stock for insert to authenticated with check (mi_rol() in ('bodega','jefe','gerencia','admin'));
create policy ots_editar on ot_stock for update to authenticated using (mi_rol() in ('bodega','jefe','gerencia','admin')) with check (mi_rol() in ('bodega','jefe','gerencia','admin'));
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

-- ---------- Documentos por OT -----------------------------------------

-- Registro de documentos de cada OT. Si es de una compra, queda ligado a ella.
create table if not exists documentos (
  id bigint generated always as identity primary key,
  ot_id bigint not null references ots(id),
  compra_id bigint references compras(id) on delete set null,
  tipo text not null default 'otro' check (tipo in ('orden_compra','factura','guia','cotizacion','plano','certificado','otro')),
  nombre text not null,
  path text not null unique,            -- ruta del archivo en Storage (bucket "documentos")
  mime text,
  tamano bigint,
  nota text,
  subido_por uuid references perfiles(id) default auth.uid(),
  creado timestamptz not null default now()
);
create index if not exists documentos_ot on documentos (ot_id);
create index if not exists documentos_compra on documentos (compra_id);

alter table documentos enable row level security;
drop policy if exists docs_leer on documentos;  drop policy if exists docs_crear on documentos;
drop policy if exists docs_editar on documentos; drop policy if exists docs_borrar on documentos;
create policy docs_leer   on documentos for select to authenticated using (mi_rol() in ('bodega','jefe','gerencia','admin'));
create policy docs_crear  on documentos for insert to authenticated with check (mi_rol() in ('bodega','jefe','gerencia','admin'));
create policy docs_editar on documentos for update to authenticated using (mi_rol() in ('bodega','jefe','gerencia','admin')) with check (mi_rol() in ('bodega','jefe','gerencia','admin'));
create policy docs_borrar on documentos for delete to authenticated using (mi_rol() = 'admin');
grant all on documentos to authenticated;

-- Carpeta privada para los archivos (solo usuarios de la app con rol)
insert into storage.buckets (id, name, public) values ('documentos', 'documentos', false)
  on conflict (id) do nothing;
drop policy if exists "documentos leer"   on storage.objects;
drop policy if exists "documentos subir"  on storage.objects;
drop policy if exists "documentos borrar" on storage.objects;
create policy "documentos leer" on storage.objects for select to authenticated
  using (bucket_id = 'documentos' and public.mi_rol() in ('bodega','jefe','gerencia','admin'));
create policy "documentos subir" on storage.objects for insert to authenticated
  with check (bucket_id = 'documentos' and public.mi_rol() in ('bodega','jefe','gerencia','admin'));
create policy "documentos borrar" on storage.objects for delete to authenticated
  using (bucket_id = 'documentos' and public.mi_rol() = 'admin');

-- ---------- Datos iniciales (editar desde la app) --------------------

insert into operaciones (nombre) values
  ('Corte'), ('Trazado'), ('Armado'), ('Soldadura'), ('Mecanizado'),
  ('Pintura'), ('Tratamiento térmico'), ('Montaje'), ('Control de calidad'), ('Otro');

-- Valores de ejemplo marcados como estimados: reemplazar por los reales en la app
insert into tarifas (nombre, costo_hh, costo_hh_extra, estimada) values
  ('Ayudante',      6200,  9300, true),
  ('Armador',       8500, 12750, true),
  ('Mecánico',     10200, 15300, true),
  ('Soldador 3G',   9800, 14700, true),
  ('Soldador 6G',  11500, 17250, true),
  ('Pintor',        7400, 11100, true);

insert into procesos (nombre, tipo, unidad, costo_unit, estimada) values
  ('Pintura epóxica', 'pintura', 'm²', 6500, true),
  ('Arenado SA 2½',   'pintura', 'm²', 4200, true),
  ('Tratamiento térmico', 'tratamiento_termico', 'kg', 650, true);
