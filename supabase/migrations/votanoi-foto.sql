-- ============================================================
-- VOTANOI: Foto candidati
-- Da eseguire nel SQL Editor del progetto Supabase civicivoghera
-- (rwmmolgtrqilqeoentop.supabase.co)
-- ============================================================

-- 1. Aggiungi colonna foto_url a ballot_candidates
ALTER TABLE ballot_candidates ADD COLUMN IF NOT EXISTS foto_url TEXT;

-- ============================================================
-- 2. Bucket Supabase Storage "candidati-foto"
--    (se il bucket esiste già, questo blocco viene ignorato)
-- ============================================================
INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES (
  'candidati-foto',
  'candidati-foto',
  true,          -- accesso pubblico in lettura
  5242880,       -- max 5 MB per file
  ARRAY['image/jpeg','image/png','image/webp','image/gif']
)
ON CONFLICT (id) DO NOTHING;

-- Policy: lettura pubblica
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE tablename = 'objects' AND schemaname = 'storage'
      AND policyname = 'candidati-foto public read'
  ) THEN
    EXECUTE $p$
      CREATE POLICY "candidati-foto public read"
        ON storage.objects FOR SELECT
        USING (bucket_id = 'candidati-foto');
    $p$;
  END IF;
END $$;

-- Policy: upload con chiave anonima (admin usa anon key)
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE tablename = 'objects' AND schemaname = 'storage'
      AND policyname = 'candidati-foto anon upload'
  ) THEN
    EXECUTE $p$
      CREATE POLICY "candidati-foto anon upload"
        ON storage.objects FOR INSERT
        TO anon
        WITH CHECK (bucket_id = 'candidati-foto');
    $p$;
  END IF;
END $$;

-- Policy: delete con chiave anonima (sostituzione foto)
DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_policies
    WHERE tablename = 'objects' AND schemaname = 'storage'
      AND policyname = 'candidati-foto anon delete'
  ) THEN
    EXECUTE $p$
      CREATE POLICY "candidati-foto anon delete"
        ON storage.objects FOR DELETE
        TO anon
        USING (bucket_id = 'candidati-foto');
    $p$;
  END IF;
END $$;

-- ============================================================
-- 3. Aggiorna manage_ballot per gestire foto_url
-- ============================================================
CREATE OR REPLACE FUNCTION manage_ballot(
  p_token  TEXT,
  p_action TEXT,
  p_data   JSONB DEFAULT '{}'::JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_ok BOOLEAN;
BEGIN
  -- Autenticazione
  IF p_token IS DISTINCT FROM 'votanoi_admin_2026_X9k' THEN
    RETURN jsonb_build_object('ok', false, 'error', 'Unauthorized');
  END IF;

  -- ── toggle_list ─────────────────────────────────────────
  IF p_action = 'toggle_list' THEN
    UPDATE ballot_lists
    SET active = (p_data->>'active')::BOOLEAN
    WHERE id = p_data->>'list_id';
    RETURN jsonb_build_object('ok', true);
  END IF;

  -- ── upsert_candidate ────────────────────────────────────
  IF p_action = 'upsert_candidate' THEN
    INSERT INTO ballot_candidates (
      list_id, ballot_name, full_name, gender, why, active, foto_url
    ) VALUES (
      p_data->>'list_id',
      p_data->>'ballot_name',
      p_data->>'full_name',
      p_data->>'gender',
      NULLIF(p_data->>'why', ''),
      COALESCE((p_data->>'active')::BOOLEAN, true),
      NULLIF(p_data->>'foto_url', '')
    )
    ON CONFLICT (list_id, ballot_name)
    DO UPDATE SET
      full_name = EXCLUDED.full_name,
      gender    = EXCLUDED.gender,
      why       = EXCLUDED.why,
      active    = EXCLUDED.active,
      -- preserva foto esistente se non viene passata
      foto_url  = CASE
                    WHEN p_data ? 'foto_url'
                    THEN NULLIF(p_data->>'foto_url', '')
                    ELSE ballot_candidates.foto_url
                  END;
    RETURN jsonb_build_object('ok', true);
  END IF;

  -- ── delete_candidate ────────────────────────────────────
  IF p_action = 'delete_candidate' THEN
    DELETE FROM ballot_candidates
    WHERE id = (p_data->>'id')::UUID;
    RETURN jsonb_build_object('ok', true);
  END IF;

  RETURN jsonb_build_object('ok', false, 'error', 'Azione sconosciuta: ' || p_action);
END;
$$;

-- ============================================================
-- 4. Query di scoperta: struttura tabella candidati civicivoghera
--    Esegui per sapere quale colonna contiene le foto e i nomi
-- ============================================================
-- SELECT column_name, data_type
-- FROM information_schema.columns
-- WHERE table_name IN ('candidati', 'candidates', 'members')
-- ORDER BY table_name, ordinal_position;

-- ============================================================
-- 5. Import foto Civici (da eseguire DOPO aver scoperto la struttura)
--    Adatta 'foto_url', 'nome', 'cognome' ai nomi reali delle colonne
-- ============================================================
-- UPDATE ballot_candidates bc
-- SET foto_url = c.foto_url        -- ← adatta nome colonna
-- FROM candidati c                 -- ← adatta nome tabella
-- WHERE bc.list_id = 'civici'
--   AND bc.foto_url IS NULL        -- non sovrascrivere esistenti
--   AND (
--     UPPER(bc.ballot_name) = UPPER(COALESCE(c.cognome,'') || ' ' || COALESCE(c.nome,''))
--     OR
--     UPPER(bc.ballot_name) = UPPER(COALESCE(c.nome,'') || ' ' || COALESCE(c.cognome,''))
--   );
