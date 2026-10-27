// Edge Function "leer-ot": lee un documento de trabajo (OT, cotización, orden de compra del cliente;
// PDF o foto) con la API de Anthropic y devuelve los datos para crear la OT.
// Pueden usarla Jefe de taller, Gerencia y Administrador. El tope diario se comparte con leer-oc.
// La clave va en el secreto ANTHROPIC_API_KEY (Edge Functions › Secrets).
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";

const LIMITE = 60;
const MODELO = "claude-sonnet-5-5";
const MAX_BYTES = 15 * 1024 * 1024;
const CORS = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const out = (o: unknown, s = 200) =>
  new Response(JSON.stringify(o), { status: s, headers: { ...CORS, "Content-Type": "application/json" } });

const PROMPT = `Lees un documento que describe un trabajo para una maestranza en Chile: orden de trabajo (OT), orden de compra del cliente, cotización, solicitud de fabricación o plano con cuadro de datos. Extrae los datos para crear la OT en el sistema de control del taller.
Reglas:
- "numero": el número de la OT. Si el documento no trae uno propio del taller, usa el número de orden de compra o de cotización del cliente.
- "cliente": razón social o nombre del cliente que encarga el trabajo.
- "descripcion": resumen corto (máx. 140 caracteres) de lo que hay que fabricar o hacer, ej. "Fabricación de 12 spools de cañería 6\" A106".
- "cantidad": número de piezas/unidades a fabricar (entero o decimal). Si hay varios ítems distintos, la suma de piezas; si no se puede saber, 1 y avisa en "advertencias".
- "unidad": pza, spool, m, kg, juego, etc. Si no se indica, "pza".
- "kg_cotizados": peso TOTAL en kg del trabajo SOLO si el documento lo indica (peso total, kg totales). No lo calcules tú. Si no aparece, null.
- "fecha_entrega": fecha comprometida de entrega en formato AAAA-MM-DD (fechas chilenas DD/MM/AAAA). Si no hay, null.
- "ppto_horas": horas hombre estimadas SOLO si el documento las indica; si no, null.
- "precio_venta": valor total NETO de la venta en pesos chilenos, sin puntos ni símbolo $, solo si el documento lo trae (si solo trae total con IVA, divide por 1,19 y avísalo). Si no, null.
- "tipo_documento": ot, cotizacion, orden_compra, plano u otro.
- No inventes: si un dato no se lee, null y avisa en "advertencias".
No escribas texto: responde ÚNICAMENTE llamando a la herramienta "registrar_ot".`;

const SCHEMA = {
  type: "object",
  properties: {
    numero: { type: ["string", "null"] },
    cliente: { type: ["string", "null"] },
    descripcion: { type: ["string", "null"] },
    cantidad: { type: ["number", "null"] },
    unidad: { type: ["string", "null"] },
    kg_cotizados: { type: ["number", "null"] },
    fecha_entrega: { type: ["string", "null"], description: "AAAA-MM-DD" },
    ppto_horas: { type: ["number", "null"] },
    precio_venta: { type: ["integer", "null"] },
    tipo_documento: { type: "string", enum: ["ot", "cotizacion", "orden_compra", "plano", "otro"] },
    advertencias: { type: "array", items: { type: "string" } },
  },
  required: ["numero", "cliente", "descripcion", "cantidad", "unidad", "kg_cotizados", "fecha_entrega", "ppto_horas", "precio_venta", "tipo_documento", "advertencias"],
};

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: CORS });
  if (req.method !== "POST") return out({ error: "metodo" }, 405);
  try {
    const url = Deno.env.get("SUPABASE_URL")!, svcKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")!;
    const apiKey = Deno.env.get("ANTHROPIC_API_KEY");
    if (!apiKey) return out({ error: "sin_clave" }, 500);

    // 1) Quién llama: Bodega, Jefe de taller o Administrador activo
    const jwt = (req.headers.get("Authorization") || "").replace(/^Bearer\s+/i, "");
    const svc = createClient(url, svcKey, { auth: { persistSession: false } });
    const { data: u, error: eu } = await svc.auth.getUser(jwt);
    if (eu || !u?.user) return out({ error: "no_autenticado" }, 401);
    const { data: p } = await svc.from("perfiles").select("rol, activo").eq("id", u.user.id).maybeSingle();
    if (!p || !p.activo || !["jefe", "gerencia", "admin"].includes(p.rol)) return out({ error: "sin_permiso" }, 403);

    // 2) Archivo (base64)
    const { archivo, tipo } = await req.json();
    if (!archivo || typeof archivo !== "string") return out({ error: "sin_archivo" }, 400);
    if (archivo.length * 0.75 > MAX_BYTES) return out({ error: "muy_pesado" }, 413);
    const mt = String(tipo || "").toLowerCase();
    const isPdf = mt.includes("pdf");
    const media = isPdf ? "application/pdf" : ["image/jpeg", "image/png", "image/webp", "image/gif"].includes(mt) ? mt : "image/jpeg";
    const part = isPdf
      ? { type: "document", source: { type: "base64", media_type: media, data: archivo } }
      : { type: "image", source: { type: "base64", media_type: media, data: archivo } };

    // 3) Tope diario
    const { data: n } = await svc.rpc("ia_tomar", { p_max: LIMITE });
    if (!n) return out({ error: "tope", limite: LIMITE }, 429);

    // 4) Lectura
    const r = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: { "x-api-key": apiKey, "anthropic-version": "2023-06-01", "content-type": "application/json" },
      body: JSON.stringify({
        model: MODELO,
        max_tokens: 3000,
        tools: [{ name: "registrar_ot", description: "Registra los datos de la orden de trabajo", input_schema: SCHEMA }],
        tool_choice: { type: "tool", name: "registrar_ot" },
        messages: [{ role: "user", content: [part, { type: "text", text: PROMPT }] }],
      }),
    });
    const j = await r.json();
    if (!r.ok) {
      await svc.rpc("ia_devolver");
      return out({ error: "anthropic", status: r.status, detalle: j?.error?.message || "" }, 502);
    }
    const tu = (j.content || []).find((c: any) => c.type === "tool_use");
    if (!tu) { await svc.rpc("ia_devolver"); return out({ error: "sin_respuesta" }, 502); }
    return out({ ok: true, ot: tu.input, usadas: n, limite: LIMITE });
  } catch (e) {
    return out({ error: "interno", detalle: String(e) }, 500);
  }
});
