
-- ============================================================================
-- COMPLETE DATABASE MIGRATION SCRIPT
-- This script recreates the entire database schema for the InsightsLM application
-- ============================================================================

-- Enable required extensions
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";
CREATE EXTENSION IF NOT EXISTS "vector";

-- ============================================================================
-- CUSTOM TYPES
-- ============================================================================

DO $$ BEGIN
    CREATE TYPE source_type AS ENUM ('pdf', 'text', 'website', 'youtube', 'audio');
EXCEPTION
    WHEN duplicate_object THEN null;
END $$;

-- ============================================================================
-- CORE TABLES
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.n8n_chat_histories (
  id serial not null,
  session_id uuid not null,
  message jsonb not null,
  constraint n8n_chat_histories_pkey primary key (id)
) TABLESPACE pg_default;

CREATE TABLE IF NOT EXISTS public.profiles (
    id uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
    email text NOT NULL,
    full_name text,
    avatar_url text,
    created_at timestamp with time zone DEFAULT timezone('utc'::text, now()) NOT NULL,
    updated_at timestamp with time zone DEFAULT timezone('utc'::text, now()) NOT NULL
);

CREATE TABLE IF NOT EXISTS public.notebooks (
    id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id uuid NOT NULL REFERENCES public.profiles(id) ON DELETE CASCADE,
    title text NOT NULL,
    description text,
    color text DEFAULT 'gray',
    icon text DEFAULT '📝',
    generation_status text DEFAULT 'completed',
    audio_overview_generation_status text,
    audio_overview_url text,
    audio_url_expires_at timestamp with time zone,
    example_questions text[] DEFAULT '{}',
    created_at timestamp with time zone DEFAULT timezone('utc'::text, now()) NOT NULL,
    updated_at timestamp with time zone DEFAULT timezone('utc'::text, now()) NOT NULL
);

CREATE TABLE IF NOT EXISTS public.sources (
    id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
    notebook_id uuid NOT NULL REFERENCES public.notebooks(id) ON DELETE CASCADE,
    title text NOT NULL,
    type source_type NOT NULL,
    url text,
    file_path text,
    file_size bigint,
    display_name text,
    content text,
    summary text,
    processing_status text DEFAULT 'pending',
    metadata jsonb DEFAULT '{}',
    created_at timestamp with time zone DEFAULT timezone('utc'::text, now()) NOT NULL,
    updated_at timestamp with time zone DEFAULT timezone('utc'::text, now()) NOT NULL
);

-- Add foreign key constraint aliases if they don't exist
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM information_schema.table_constraints
        WHERE constraint_name = 'fk_sources_notebook_id'
        AND table_name = 'sources'
    ) THEN
        ALTER TABLE public.sources ADD CONSTRAINT fk_sources_notebook_id
            FOREIGN KEY (notebook_id) REFERENCES public.notebooks(id) ON DELETE CASCADE;
    END IF;
EXCEPTION WHEN duplicate_object THEN null;
END $$;

CREATE TABLE IF NOT EXISTS public.notes (
    id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
    notebook_id uuid NOT NULL REFERENCES public.notebooks(id) ON DELETE CASCADE,
    title text NOT NULL,
    content text NOT NULL,
    source_type text DEFAULT 'user',
    extracted_text text,
    created_at timestamp with time zone DEFAULT timezone('utc'::text, now()) NOT NULL,
    updated_at timestamp with time zone DEFAULT timezone('utc'::text, now()) NOT NULL
);

CREATE TABLE IF NOT EXISTS public.documents (
    id bigserial PRIMARY KEY,
    content text,
    metadata jsonb,
    embedding vector(1536)
);

-- ============================================================================
-- INDEXES
-- ============================================================================

CREATE INDEX IF NOT EXISTS idx_notebooks_user_id ON public.notebooks(user_id);
CREATE INDEX IF NOT EXISTS idx_notebooks_updated_at ON public.notebooks(updated_at DESC);
CREATE INDEX IF NOT EXISTS idx_sources_notebook_id ON public.sources(notebook_id);
CREATE INDEX IF NOT EXISTS idx_sources_type ON public.sources(type);
CREATE INDEX IF NOT EXISTS idx_sources_processing_status ON public.sources(processing_status);
CREATE INDEX IF NOT EXISTS idx_notes_notebook_id ON public.notes(notebook_id);
CREATE INDEX IF NOT EXISTS idx_chat_histories_session_id ON public.n8n_chat_histories(session_id);
CREATE INDEX IF NOT EXISTS documents_embedding_idx ON public.documents USING hnsw (embedding vector_cosine_ops);

-- ============================================================================
-- DATABASE FUNCTIONS
-- ============================================================================

CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
BEGIN
    INSERT INTO public.profiles (id, email, full_name)
    VALUES (
        new.id,
        new.email,
        COALESCE(new.raw_user_meta_data ->> 'full_name', new.raw_user_meta_data ->> 'name')
    );
    RETURN new;
END;
$$;

CREATE OR REPLACE FUNCTION public.update_updated_at_column()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
    new.updated_at = timezone('utc'::text, now());
    RETURN new;
END;
$$;

CREATE OR REPLACE FUNCTION public.is_notebook_owner(notebook_id_param uuid)
RETURNS boolean
LANGUAGE sql
STABLE SECURITY DEFINER
AS $$
    SELECT EXISTS (
        SELECT 1 
        FROM public.notebooks 
        WHERE id = notebook_id_param 
        AND user_id = auth.uid()
    );
$$;

CREATE OR REPLACE FUNCTION public.is_notebook_owner_for_document(doc_metadata jsonb)
RETURNS boolean
LANGUAGE sql
STABLE SECURITY DEFINER
AS $$
    SELECT EXISTS (
        SELECT 1 
        FROM public.notebooks 
        WHERE id = (doc_metadata->>'notebook_id')::uuid 
        AND user_id = auth.uid()
    );
$$;

CREATE OR REPLACE FUNCTION public.match_documents(
    query_embedding vector,
    match_count integer DEFAULT NULL,
    filter jsonb DEFAULT '{}'::jsonb
)
RETURNS TABLE(
    id bigint,
    content text,
    metadata jsonb,
    similarity double precision
)
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN QUERY
    SELECT
        documents.id,
        documents.content,
        documents.metadata,
        1 - (documents.embedding <=> query_embedding) as similarity
    FROM public.documents
    WHERE documents.metadata @> filter
    ORDER BY documents.embedding <=> query_embedding
    LIMIT match_count;
END;
$$;

-- ============================================================================
-- ROW LEVEL SECURITY (RLS) POLICIES
-- ============================================================================

ALTER TABLE public.profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.notebooks ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.sources ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.notes ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.documents ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.n8n_chat_histories ENABLE ROW LEVEL SECURITY;

-- Profiles policies
DROP POLICY IF EXISTS "Users can view their own profile" ON public.profiles;
CREATE POLICY "Users can view their own profile"
    ON public.profiles FOR SELECT
    TO authenticated
    USING (auth.uid() = id);

DROP POLICY IF EXISTS "Users can update their own profile" ON public.profiles;
CREATE POLICY "Users can update their own profile"
    ON public.profiles FOR UPDATE
    TO authenticated
    USING (auth.uid() = id)
    WITH CHECK (auth.uid() = id);

-- Notebooks policies
DROP POLICY IF EXISTS "Users can view their own notebooks" ON public.notebooks;
CREATE POLICY "Users can view their own notebooks"
    ON public.notebooks FOR SELECT
    TO authenticated
    USING (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users can create their own notebooks" ON public.notebooks;
CREATE POLICY "Users can create their own notebooks"
    ON public.notebooks FOR INSERT
    TO authenticated
    WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users can update their own notebooks" ON public.notebooks;
CREATE POLICY "Users can update their own notebooks"
    ON public.notebooks FOR UPDATE
    TO authenticated
    USING (auth.uid() = user_id)
    WITH CHECK (auth.uid() = user_id);

DROP POLICY IF EXISTS "Users can delete their own notebooks" ON public.notebooks;
CREATE POLICY "Users can delete their own notebooks"
    ON public.notebooks FOR DELETE
    TO authenticated
    USING (auth.uid() = user_id);

-- Sources policies
DROP POLICY IF EXISTS "Users can view sources from their notebooks" ON public.sources;
CREATE POLICY "Users can view sources from their notebooks"
    ON public.sources FOR SELECT
    TO authenticated
    USING (
        EXISTS (
            SELECT 1 FROM public.notebooks 
            WHERE notebooks.id = sources.notebook_id 
            AND notebooks.user_id = auth.uid()
        )
    );

DROP POLICY IF EXISTS "Users can create sources in their notebooks" ON public.sources;
CREATE POLICY "Users can create sources in their notebooks"
    ON public.sources FOR INSERT
    TO authenticated
    WITH CHECK (
        EXISTS (
            SELECT 1 FROM public.notebooks 
            WHERE notebooks.id = sources.notebook_id 
            AND notebooks.user_id = auth.uid()
        )
    );

DROP POLICY IF EXISTS "Users can update sources in their notebooks" ON public.sources;
CREATE POLICY "Users can update sources in their notebooks"
    ON public.sources FOR UPDATE
    TO authenticated
    USING (
        EXISTS (
            SELECT 1 FROM public.notebooks 
            WHERE notebooks.id = sources.notebook_id 
            AND notebooks.user_id = auth.uid()
        )
    )
    WITH CHECK (
        EXISTS (
            SELECT 1 FROM public.notebooks 
            WHERE notebooks.id = sources.notebook_id 
            AND notebooks.user_id = auth.uid()
        )
    );

DROP POLICY IF EXISTS "Users can delete sources from their notebooks" ON public.sources;
CREATE POLICY "Users can delete sources from their notebooks"
    ON public.sources FOR DELETE
    TO authenticated
    USING (
        EXISTS (
            SELECT 1 FROM public.notebooks 
            WHERE notebooks.id = sources.notebook_id 
            AND notebooks.user_id = auth.uid()
        )
    );

-- Notes policies
DROP POLICY IF EXISTS "Users can view notes from their notebooks" ON public.notes;
CREATE POLICY "Users can view notes from their notebooks"
    ON public.notes FOR SELECT
    TO authenticated
    USING (
        EXISTS (
            SELECT 1 FROM public.notebooks 
            WHERE notebooks.id = notes.notebook_id 
            AND notebooks.user_id = auth.uid()
        )
    );

DROP POLICY IF EXISTS "Users can create notes in their notebooks" ON public.notes;
CREATE POLICY "Users can create notes in their notebooks"
    ON public.notes FOR INSERT
    TO authenticated
    WITH CHECK (
        EXISTS (
            SELECT 1 FROM public.notebooks 
            WHERE notebooks.id = notes.notebook_id 
            AND notebooks.user_id = auth.uid()
        )
    );

DROP POLICY IF EXISTS "Users can update notes in their notebooks" ON public.notes;
CREATE POLICY "Users can update notes in their notebooks"
    ON public.notes FOR UPDATE
    TO authenticated
    USING (
        EXISTS (
            SELECT 1 FROM public.notebooks 
            WHERE notebooks.id = notes.notebook_id 
            AND notebooks.user_id = auth.uid()
        )
    )
    WITH CHECK (
        EXISTS (
            SELECT 1 FROM public.notebooks 
            WHERE notebooks.id = notes.notebook_id 
            AND notebooks.user_id = auth.uid()
        )
    );

DROP POLICY IF EXISTS "Users can delete notes from their notebooks" ON public.notes;
CREATE POLICY "Users can delete notes from their notebooks"
    ON public.notes FOR DELETE
    TO authenticated
    USING (
        EXISTS (
            SELECT 1 FROM public.notebooks 
            WHERE notebooks.id = notes.notebook_id 
            AND notebooks.user_id = auth.uid()
        )
    );

-- Documents policies
DROP POLICY IF EXISTS "Users can view documents from their notebooks" ON public.documents;
CREATE POLICY "Users can view documents from their notebooks"
    ON public.documents FOR SELECT
    TO authenticated
    USING (public.is_notebook_owner_for_document(metadata));

DROP POLICY IF EXISTS "Users can create documents in their notebooks" ON public.documents;
CREATE POLICY "Users can create documents in their notebooks"
    ON public.documents FOR INSERT
    TO authenticated
    WITH CHECK (public.is_notebook_owner_for_document(metadata));

DROP POLICY IF EXISTS "Users can update documents in their notebooks" ON public.documents;
CREATE POLICY "Users can update documents in their notebooks"
    ON public.documents FOR UPDATE
    TO authenticated
    USING (public.is_notebook_owner_for_document(metadata))
    WITH CHECK (public.is_notebook_owner_for_document(metadata));

DROP POLICY IF EXISTS "Users can delete documents from their notebooks" ON public.documents;
CREATE POLICY "Users can delete documents from their notebooks"
    ON public.documents FOR DELETE
    TO authenticated
    USING (public.is_notebook_owner_for_document(metadata));

-- Chat histories policies
DROP POLICY IF EXISTS "Users can view chat histories from their notebooks" ON public.n8n_chat_histories;
CREATE POLICY "Users can view chat histories from their notebooks"
    ON public.n8n_chat_histories FOR SELECT
    TO authenticated
    USING (public.is_notebook_owner(session_id::uuid));

DROP POLICY IF EXISTS "Users can create chat histories in their notebooks" ON public.n8n_chat_histories;
CREATE POLICY "Users can create chat histories in their notebooks"
    ON public.n8n_chat_histories FOR INSERT
    TO authenticated
    WITH CHECK (public.is_notebook_owner(session_id::uuid));

DROP POLICY IF EXISTS "Users can delete chat histories from their notebooks" ON public.n8n_chat_histories;
CREATE POLICY "Users can delete chat histories from their notebooks"
    ON public.n8n_chat_histories FOR DELETE
    TO authenticated
    USING (public.is_notebook_owner(session_id::uuid));

-- Service role policies for n8n to write chat histories
DROP POLICY IF EXISTS "Service role can manage chat histories" ON public.n8n_chat_histories;
CREATE POLICY "Service role can manage chat histories"
    ON public.n8n_chat_histories FOR ALL
    TO service_role
    USING (true)
    WITH CHECK (true);

-- Service role policies for documents (n8n writes embeddings)
DROP POLICY IF EXISTS "Service role can manage documents" ON public.documents;
CREATE POLICY "Service role can manage documents"
    ON public.documents FOR ALL
    TO service_role
    USING (true)
    WITH CHECK (true);

-- Service role policies for sources (n8n updates processing status)
DROP POLICY IF EXISTS "Service role can manage sources" ON public.sources;
CREATE POLICY "Service role can manage sources"
    ON public.sources FOR ALL
    TO service_role
    USING (true)
    WITH CHECK (true);

-- Service role policies for notebooks (n8n updates generation status)
DROP POLICY IF EXISTS "Service role can manage notebooks" ON public.notebooks;
CREATE POLICY "Service role can manage notebooks"
    ON public.notebooks FOR ALL
    TO service_role
    USING (true)
    WITH CHECK (true);

-- ============================================================================
-- TRIGGERS
-- ============================================================================

DROP TRIGGER IF EXISTS update_profiles_updated_at ON public.profiles;
DROP TRIGGER IF EXISTS update_notebooks_updated_at ON public.notebooks;
DROP TRIGGER IF EXISTS update_sources_updated_at ON public.sources;
DROP TRIGGER IF EXISTS update_notes_updated_at ON public.notes;
DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;

CREATE TRIGGER update_profiles_updated_at
    BEFORE UPDATE ON public.profiles
    FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
CREATE TRIGGER update_notebooks_updated_at
    BEFORE UPDATE ON public.notebooks
    FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
CREATE TRIGGER update_sources_updated_at
    BEFORE UPDATE ON public.sources
    FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();
CREATE TRIGGER update_notes_updated_at
    BEFORE UPDATE ON public.notes
    FOR EACH ROW EXECUTE FUNCTION public.update_updated_at_column();

CREATE TRIGGER on_auth_user_created
    AFTER INSERT ON auth.users
    FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

-- ============================================================================
-- REALTIME CONFIGURATION
-- ============================================================================

ALTER TABLE public.notebooks REPLICA IDENTITY FULL;
ALTER TABLE public.sources REPLICA IDENTITY FULL;
ALTER TABLE public.notes REPLICA IDENTITY FULL;
ALTER TABLE public.n8n_chat_histories REPLICA IDENTITY FULL;

-- Add tables to realtime publication (guarded against duplicate membership)
DO $$ BEGIN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.notebooks;
EXCEPTION WHEN duplicate_object THEN null;
END $$;

DO $$ BEGIN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.sources;
EXCEPTION WHEN duplicate_object THEN null;
END $$;

DO $$ BEGIN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.notes;
EXCEPTION WHEN duplicate_object THEN null;
END $$;

DO $$ BEGIN
    ALTER PUBLICATION supabase_realtime ADD TABLE public.n8n_chat_histories;
EXCEPTION WHEN duplicate_object THEN null;
END $$;

-- ============================================================================
-- STORAGE BUCKETS
-- ============================================================================

INSERT INTO storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
VALUES 
  ('sources', 'sources', false, 52428800, ARRAY[
    'application/pdf',
    'text/plain',
    'text/csv',
    'application/msword',
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
    'audio/mpeg',
    'audio/wav',
    'audio/mp4',
    'audio/m4a'
  ]),
  ('audio', 'audio', false, 104857600, ARRAY[
    'audio/mpeg',
    'audio/wav',
    'audio/mp4',
    'audio/m4a'
  ]),
  ('public-images', 'public-images', true, 10485760, ARRAY[
    'image/jpeg',
    'image/png',
    'image/gif',
    'image/webp',
    'image/svg+xml'
  ])
ON CONFLICT (id) DO UPDATE SET
  file_size_limit = EXCLUDED.file_size_limit,
  allowed_mime_types = EXCLUDED.allowed_mime_types,
  public = EXCLUDED.public;

-- ============================================================================
-- STORAGE RLS POLICIES
-- ============================================================================

-- Sources bucket policies
DROP POLICY IF EXISTS "Users can view their own source files" ON storage.objects;
CREATE POLICY "Users can view their own source files"
ON storage.objects FOR SELECT
TO authenticated
USING (
  bucket_id = 'sources' AND
  (storage.foldername(name))[1]::uuid IN (
    SELECT id FROM public.notebooks WHERE user_id = auth.uid()
  )
);

DROP POLICY IF EXISTS "Users can upload source files to their notebooks" ON storage.objects;
CREATE POLICY "Users can upload source files to their notebooks"
ON storage.objects FOR INSERT
TO authenticated
WITH CHECK (
  bucket_id = 'sources' AND
  (storage.foldername(name))[1]::uuid IN (
    SELECT id FROM public.notebooks WHERE user_id = auth.uid()
  )
);

DROP POLICY IF EXISTS "Users can update their own source files" ON storage.objects;
CREATE POLICY "Users can update their own source files"
ON storage.objects FOR UPDATE
TO authenticated
USING (
  bucket_id = 'sources' AND
  (storage.foldername(name))[1]::uuid IN (
    SELECT id FROM public.notebooks WHERE user_id = auth.uid()
  )
);

DROP POLICY IF EXISTS "Users can delete their own source files" ON storage.objects;
CREATE POLICY "Users can delete their own source files"
ON storage.objects FOR DELETE
TO authenticated
USING (
  bucket_id = 'sources' AND
  (storage.foldername(name))[1]::uuid IN (
    SELECT id FROM public.notebooks WHERE user_id = auth.uid()
  )
);

-- Audio bucket policies
DROP POLICY IF EXISTS "Users can view their own audio files" ON storage.objects;
CREATE POLICY "Users can view their own audio files"
ON storage.objects FOR SELECT
TO authenticated
USING (
  bucket_id = 'audio' AND
  (storage.foldername(name))[1]::uuid IN (
    SELECT id FROM public.notebooks WHERE user_id = auth.uid()
  )
);

DROP POLICY IF EXISTS "Service role can manage audio files" ON storage.objects;
CREATE POLICY "Service role can manage audio files"
ON storage.objects FOR ALL
TO service_role
USING (bucket_id = 'audio')
WITH CHECK (bucket_id = 'audio');

DROP POLICY IF EXISTS "Users can delete their own audio files" ON storage.objects;
CREATE POLICY "Users can delete their own audio files"
ON storage.objects FOR DELETE
TO authenticated
USING (
  bucket_id = 'audio' AND
  (storage.foldername(name))[1]::uuid IN (
    SELECT id FROM public.notebooks WHERE user_id = auth.uid()
  )
);

-- Public images bucket policies
DROP POLICY IF EXISTS "Anyone can view public images" ON storage.objects;
CREATE POLICY "Anyone can view public images"
ON storage.objects FOR SELECT
USING (bucket_id = 'public-images');

DROP POLICY IF EXISTS "Service role can manage public images" ON storage.objects;
CREATE POLICY "Service role can manage public images"
ON storage.objects FOR ALL
TO service_role
USING (bucket_id = 'public-images')
WITH CHECK (bucket_id = 'public-images');

-- Service role can manage source files (n8n needs to read/write)
DROP POLICY IF EXISTS "Service role can manage source files" ON storage.objects;
CREATE POLICY "Service role can manage source files"
ON storage.objects FOR ALL
TO service_role
USING (bucket_id = 'sources')
WITH CHECK (bucket_id = 'sources');
