// Edge Function "leer-oc": lee una orden de compra, factura o guía (PDF o foto)
// con la API de Anthropic y devuelve sus líneas para cargarlas al stock de una OT.
// Pueden usarla Bodega, Jefe de taller y Administrador. Tope diario: LIMITE.
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

const PROMPT = `Lees una orden de compra, factura, guía de despacho o cotización de MATERIALES para una maestranza en Chile (aceros, perfiles, planchas, cañerías, fittings, pernos, pintura, consumibles de soldadura, etc.). Extrae los datos del documento y TODAS sus líneas de productos.
Reglas:
- "tipo": orden_compra, factura, guia, cotizacion u otro.
- "numero": número del documento (N° de OC, factura o guía).
- "proveedor": razón social de quien vende (en una OC, el proveedor al que se le compra).
- Fechas chilenas DD/MM/AAAA: devuélvelas como AAAA-MM-DD.
- Montos en pesos chilenos como números sin puntos ni símbolo $. "neto" = sin IVA, "total" = con IVA.
- Cada línea:
  - "descripcion": tal como aparece (incluye medidas, espesor, norma, calidad).
  - "codigo": código del producto si existe.
  - "cantidad": número. "unidad": la del documento normalizada en minúsculas (un, kg, m, m2, tira, plancha, barra, tubo, lt, gl, juego, caja, rollo). Si no se indica, "un".
  - "precio_unitario_neto": precio por unidad SIN IVA. Si el documento solo trae precios con IVA, divide por 1,19 y avísalo en "advertencias". Si solo hay total de la línea, calcula total / cantidad.
  - "kg_total": peso total de la línea en kg SOLO si el documento lo indica (columna de peso, kg teóricos, o la unidad es kg). Si no aparece, null. No lo calcules tú.
- No incluyas como líneas: descuentos globales, flete, IVA, subtotales ni totales.
- No inventes: si un dato no se lee, null y avisa en "advertencias".
No escribas texto: responde ÚNICAMENTE llamando a la herramienta "registrar_compra".`;

const SCHEMA = {
  type: "object",
  properties: {
    tipo: { type: "string", enum: ["orden_compra", "factura", "guia", "cotizacion", "otro"] },
    numero: { type: ["string", "null"] },
    proveedor: { type: ["string", "null"] },
    fecha: { type: ["string", "null"], description: "AAAA-MM-DD" },
    neto: { type: ["integer", "null"] },
    total: { type: ["integer", "null"] },
    items: {
      type: "array",
      items: {
        type: "object",
        properties: {
          codigo: { type: ["string", "null"] },
          descripcion: { type: "string" },
          cantidad: { type: "number" },
          unidad: { type: ["string", "null"] },
          precio_unitario_neto: { type: ["number", "null"] },
          kg_total: { type: ["number", "null"] },
        },
        required: ["descripcion", "cantidad", "unidad", "precio_unitario_neto", "kg_total"],
      },
    },
    advertencias: { type: "array", items: { type: "string" } },
  },
  required: ["tipo", "numero", "proveedor", "fecha", "neto", "total", "items", "advertencias"],
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
    if (!p || !p.activo || !["bodega", "jefe", "admin"].includes(p.rol)) return out({ error: "sin_permiso" }, 403);

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
        max_tokens: 12000,
        tools: [{ name: "registrar_compra", description: "Registra la compra y todas sus líneas", input_schema: SCHEMA }],
        tool_choice: { type: "tool", name: "registrar_compra" },
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
    return out({ ok: true, compra: tu.input, usadas: n, limite: LIMITE });
  } catch (e) {
    return out({ error: "interno", detalle: String(e) }, 500);
  }
});
