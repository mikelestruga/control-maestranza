-- =====================================================================
--  CONTROL DE TALLER · documentos por OT (OC, facturas, guías, planos)
--  Ejecutar UNA vez en Supabase > SQL Editor > New snippet > Run
-- =====================================================================

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
create policy docs_leer   on documentos for select to authenticated using (mi_rol() in ('bodega','jefe','admin'));
create policy docs_crear  on documentos for insert to authenticated with check (mi_rol() in ('bodega','jefe','admin'));
create policy docs_editar on documentos for update to authenticated using (mi_rol() in ('bodega','jefe','admin')) with check (mi_rol() in ('bodega','jefe','admin'));
create policy docs_borrar on documentos for delete to authenticated using (mi_rol() = 'admin');
grant all on documentos to authenticated;

-- Carpeta privada para los archivos (solo usuarios de la app con rol)
insert into storage.buckets (id, name, public) values ('documentos', 'documentos', false)
  on conflict (id) do nothing;
drop policy if exists "documentos leer"   on storage.objects;
drop policy if exists "documentos subir"  on storage.objects;
drop policy if exists "documentos borrar" on storage.objects;
create policy "documentos leer" on storage.objects for select to authenticated
  using (bucket_id = 'documentos' and public.mi_rol() in ('bodega','jefe','admin'));
create policy "documentos subir" on storage.objects for insert to authenticated
  with check (bucket_id = 'documentos' and public.mi_rol() in ('bodega','jefe','admin'));
create policy "documentos borrar" on storage.objects for delete to authenticated
  using (bucket_id = 'documentos' and public.mi_rol() = 'admin');
