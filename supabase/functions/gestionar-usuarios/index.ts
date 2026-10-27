// Edge Function "gestionar-usuarios": SOLO el administrador.
//   { accion: "cambiar_clave", usuario_id, clave }
//   { accion: "eliminar",      usuario_id, clave_admin }   (pide la clave del propio administrador)
// Verifica en el servidor que quien llama es un perfil 'admin' activo.
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";

const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const out = (o: unknown, s = 200) =>
  new Response(JSON.stringify(o), { status: s, headers: { ...CORS, "Content-Type": "application/json" } });

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return out({ error: "metodo" }, 405);
  try {
    const url = Deno.env.get("SUPABASE_URL")!, svcKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const anonKey = Deno.env.get("SUPABASE_ANON_KEY")!;
    const svc = createClient(url, svcKey, { auth: { persistSession: false } });

    // 1) Quién llama: solo administrador activo
    const jwt = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
    const { data: u, error: eu } = await svc.auth.getUser(jwt);
    if (eu || !u?.user) return out({ error: "no_autenticado" }, 401);
    const { data: yo } = await svc.from("perfiles").select("rol, activo").eq("id", u.user.id).maybeSingle();
    if (!yo || !yo.activo || yo.rol !== "admin") return out({ error: "sin_permiso" }, 403);

    const body = await req.json();
    const { accion, usuario_id } = body;
    if (typeof usuario_id !== "string" || !usuario_id) return out({ error: "sin_usuario" }, 400);
    const { data: obj } = await svc.from("perfiles").select("id, nombre, rol, activo, usuario").eq("id", usuario_id).maybeSingle();
    const { data: yoNombre } = await svc.from("perfiles").select("nombre").eq("id", u.user.id).maybeSingle();
    // Deja constancia en el registro de cambios (solo lo lee el administrador)
    const anotar = (accion: string, cambios: unknown) => svc.from("auditoria").insert({
      usuario_id: u.user.id, usuario_nombre: yoNombre?.nombre ?? "Administrador", usuario_rol: "admin", seccion: "Trabajadores", accion,
      tabla: "perfiles", registro: usuario_id, detalle: `${obj!.nombre} (${obj!.usuario ?? ""})`, cambios });
    if (!obj) return out({ error: "sin_usuario" }, 404);

    // 2a) Cambiar clave
    if (accion === "cambiar_clave") {
      const clave = body.clave;
      if (typeof clave !== "string" || clave.length < 6 || clave.length > 72) return out({ error: "clave_corta" }, 400);
      const { error } = await svc.auth.admin.updateUserById(usuario_id, { password: clave });
      if (error) return out({ error: "no_se_pudo", detalle: error.message }, 500);
      await anotar("modificar", { clave: ["(anterior)", "(cambiada por el administrador)"] });
      return out({ ok: true });
    }

    // 2b) Eliminar: exige la clave del administrador que lo pide
    if (accion === "eliminar") {
      if (usuario_id === u.user.id) return out({ error: "a_si_mismo" }, 400);
      const clave = body.clave_admin;
      if (typeof clave !== "string" || !clave) return out({ error: "clave_incorrecta" }, 400);
      const anon = createClient(url, anonKey, { auth: { persistSession: false, autoRefreshToken: false } });
      const { error: ec } = await anon.auth.signInWithPassword({ email: u.user.email!, password: clave });
      if (ec) return out({ error: "clave_incorrecta" }, 403);
      if (obj.rol === "admin") {
        const { count } = await svc.from("perfiles").select("id", { count: "exact", head: true }).eq("rol", "admin").eq("activo", true);
        if ((count ?? 0) <= 1) return out({ error: "ultimo_admin" }, 400);
      }
      // Con historial de horas o asistencia no se borra: se perdería el costo de las OT
      const h = await svc.from("hh_registros").select("id", { count: "exact", head: true }).eq("perfil_id", usuario_id);
      const a = await svc.from("asistencia").select("perfil_id", { count: "exact", head: true }).eq("perfil_id", usuario_id);
      if ((h.count ?? 0) > 0 || (a.count ?? 0) > 0) return out({ error: "tiene_historial" }, 409);
      const { error } = await svc.auth.admin.deleteUser(usuario_id);
      if (error) return out({ error: /foreign key|violates|Database error/i.test(error.message) ? "tiene_historial" : "no_se_pudo", detalle: error.message }, /foreign key|violates|Database error/i.test(error.message) ? 409 : 500);
      await anotar("eliminar", { nombre: [obj.nombre, null], usuario: [obj.usuario, null], rol: [obj.rol, null] });
      return out({ ok: true });
    }
    return out({ error: "accion" }, 400);
  } catch (e) {
    return out({ error: "interno", detalle: String(e) }, 500);
  }
});
