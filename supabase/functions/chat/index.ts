// Supabase Edge Function — Chatbot RAG programma elettorale
// Progetto: perronesindaco (zkpjqaguwfoacyyklgrz)
// Deploy: supabase functions deploy chat --no-verify-jwt
// Segreti:  supabase secrets set ANTHROPIC_API_KEY=sk-ant-...

import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

const ALLOWED_ORIGINS = [
  "https://www.perronesindaco.it",
  "https://perronesindaco.it",
  "https://perronesindaco.vercel.app",
];

function corsHeaders(origin: string | null): Record<string, string> {
  const allowed = origin && ALLOWED_ORIGINS.includes(origin) ? origin : ALLOWED_ORIGINS[0];
  return {
    "Access-Control-Allow-Origin": allowed,
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Vary": "Origin",
  };
}

const SUPABASE_URL  = "https://zkpjqaguwfoacyyklgrz.supabase.co";
const SUPABASE_ANON = Deno.env.get("SUPABASE_ANON_KEY") ?? "";
const ANTHROPIC_KEY = Deno.env.get("ANTHROPIC_API_KEY") ?? "";

const SYSTEM_PROMPT = `Sei un assistente esperto del programma amministrativo della coalizione CiViCi per Voghera, PD, M5S, Casa Riformista e Alleanza Verdi Sinistra, guidata dal candidato sindaco Marcello Bergonzi Perrone per le elezioni comunali di Voghera 2026.

Rispondi SOLO in italiano, in modo chiaro e preciso, basandoti esclusivamente sulle informazioni estratte dal programma che ti vengono fornite nel contesto.
Se l'informazione non è presente nel programma, dillo onestamente senza inventare.
Sii conciso ma completo. Usa elenchi puntati quando aiuta la chiarezza.`;

serve(async (req: Request) => {
  const origin = req.headers.get("origin");
  const cors = corsHeaders(origin);

  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: cors });
  }
  if (req.method !== "POST") {
    return new Response("Method not allowed", { status: 405, headers: cors });
  }

  try {
    const { question } = await req.json() as { question: string };
    if (!question?.trim()) {
      return json({ error: "Domanda vuota" }, 400, cors);
    }
    if (question.trim().length > 500) {
      return json({ error: "Domanda troppo lunga (max 500 caratteri)" }, 400, cors);
    }
    if (!ANTHROPIC_KEY) throw new Error("ANTHROPIC_API_KEY non configurata");

    // 1. Recupera chunk rilevanti dal DB via funzione SQL
    const supabase = createClient(SUPABASE_URL, SUPABASE_ANON);
    const { data: chunks, error: dbError } = await supabase
      .rpc("cerca_chunks", { query_text: question.trim(), max_results: 5 });

    if (dbError) throw new Error(`DB error: ${dbError.message}`);

    const context = chunks && chunks.length > 0
      ? (chunks as { contenuto: string }[]).map(c => c.contenuto).join("\n\n---\n\n")
      : "Nessun contesto disponibile nel programma.";

    // 2. Chiama Claude API
    const res = await fetch("https://api.anthropic.com/v1/messages", {
      method: "POST",
      headers: {
        "x-api-key": ANTHROPIC_KEY,
        "anthropic-version": "2023-06-01",
        "content-type": "application/json",
      },
      body: JSON.stringify({
        model: "claude-haiku-4-5-20251001",
        max_tokens: 1024,
        system: SYSTEM_PROMPT,
        messages: [{
          role: "user",
          content: `Contesto estratto dal programma elettorale:\n<contesto>\n${context}\n</contesto>\n\nDomanda: ${question}`,
        }],
      }),
    });

    if (!res.ok) throw new Error(`Claude API error ${res.status}`);

    const data = await res.json() as { content: { text: string }[] };
    return json({ answer: data.content[0]?.text ?? "Nessuna risposta." }, 200, cors);

  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    console.error("chat error:", msg);
    return json({ error: "Errore interno. Riprova tra qualche secondo." }, 500, cors);
  }
});

function json(body: unknown, status = 200, cors: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...cors, "Content-Type": "application/json" },
  });
}
