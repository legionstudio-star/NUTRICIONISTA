-- =====================================================================
-- Plataforma de Encuestas - Nutrición
-- Esquema de Supabase: tablas, índices, Row Level Security y Realtime.
--
-- Ejecutar completo en: Supabase Dashboard → SQL Editor → New query → Run
-- Es idempotente: se puede ejecutar varias veces sin romper nada.
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1. Esquema privado para funciones auxiliares (no expuesto por la API)
-- ---------------------------------------------------------------------
create schema if not exists private;

-- ---------------------------------------------------------------------
-- 2. Tabla de administradores (cuentas autorizadas para ver el panel)
-- ---------------------------------------------------------------------
create table if not exists public.admin_users (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);

alter table public.admin_users enable row level security;

-- Nadie puede modificar admin_users desde la API: solo desde el SQL Editor.
revoke all on public.admin_users from anon;
revoke insert, update, delete, truncate, references, trigger on public.admin_users from authenticated;
grant select on public.admin_users to authenticated;

drop policy if exists "admin_users: cada usuario ve solo su propia fila" on public.admin_users;
create policy "admin_users: cada usuario ve solo su propia fila"
  on public.admin_users
  for select
  to authenticated
  using (user_id = (select auth.uid()));

-- ---------------------------------------------------------------------
-- 3. Función auxiliar: ¿el usuario actual es administrador?
--    SECURITY DEFINER para poder consultar admin_users sin depender de RLS.
-- ---------------------------------------------------------------------
create or replace function private.is_admin()
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1 from public.admin_users a where a.user_id = (select auth.uid())
  );
$$;

revoke all on function private.is_admin() from public;
grant usage on schema private to anon, authenticated;
grant execute on function private.is_admin() to anon, authenticated;

-- ---------------------------------------------------------------------
-- 4. Tabla principal de respuestas
-- ---------------------------------------------------------------------
create table if not exists public.survey_responses (
  id           uuid primary key default gen_random_uuid(),
  created_at   timestamptz not null default now(),
  survey_type  text not null,
  survey_title text,
  score        integer,
  answers      jsonb not null,
  source       text not null default 'web',
  -- Identificador generado en el navegador. Sirve para:
  --  * evitar duplicados si un envío se reintenta (doble clic, cola offline),
  --  * deduplicar la migración de respuestas antiguas de localStorage.
  legacy_id    text unique,

  constraint survey_responses_type_chk
    check (survey_type in ('satisfaccion', 'concertacion')),
  constraint survey_responses_title_chk
    check (survey_title is null or char_length(survey_title) <= 200),
  constraint survey_responses_score_chk
    check (score is null or (score between 0 and 100 and survey_type = 'satisfaccion')),
  constraint survey_responses_answers_chk
    check (jsonb_typeof(answers) = 'object' and pg_column_size(answers) <= 32768),
  constraint survey_responses_source_chk
    check (source in ('web', 'cola_local', 'migracion_local')),
  constraint survey_responses_legacy_id_chk
    check (legacy_id is null or char_length(legacy_id) <= 120)
);

create index if not exists survey_responses_created_at_idx
  on public.survey_responses (created_at desc);
create index if not exists survey_responses_type_created_at_idx
  on public.survey_responses (survey_type, created_at desc);

alter table public.survey_responses enable row level security;

-- Permisos a nivel de tabla (RLS filtra encima de esto).
-- El visitante anónimo SOLO puede insertar: ni leer, ni modificar, ni borrar.
revoke all on public.survey_responses from anon;
grant insert on public.survey_responses to anon;
revoke update, truncate, references, trigger on public.survey_responses from authenticated;
grant select, insert, delete on public.survey_responses to authenticated;

-- INSERT público (sin sesión) o de cualquier usuario autenticado.
--  * Visitantes: la fecha la pone el servidor (no pueden falsificarla) y
--    solo pueden usar source 'web' o 'cola_local'.
--  * Administradores: pueden migrar respuestas antiguas conservando su fecha.
drop policy if exists "survey_responses: insert publico" on public.survey_responses;
create policy "survey_responses: insert publico"
  on public.survey_responses
  for insert
  to anon, authenticated
  with check (
    survey_type in ('satisfaccion', 'concertacion')
    and (
      (
        source in ('web', 'cola_local')
        and created_at between now() - interval '10 minutes' and now() + interval '10 minutes'
      )
      or (select private.is_admin())
    )
  );

-- SELECT solo para administradores.
drop policy if exists "survey_responses: lectura solo admin" on public.survey_responses;
create policy "survey_responses: lectura solo admin"
  on public.survey_responses
  for select
  to authenticated
  using ((select private.is_admin()));

-- DELETE solo para administradores (botón "Borrar respuestas" del panel).
drop policy if exists "survey_responses: borrado solo admin" on public.survey_responses;
create policy "survey_responses: borrado solo admin"
  on public.survey_responses
  for delete
  to authenticated
  using ((select private.is_admin()));

-- No existe política de UPDATE: las respuestas no se pueden editar desde la API.

-- ---------------------------------------------------------------------
-- 5. Realtime: el panel recibe nuevas respuestas en vivo.
--    Realtime respeta RLS, así que solo los administradores reciben eventos.
-- ---------------------------------------------------------------------
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (
       select 1 from pg_publication_tables
       where pubname = 'supabase_realtime'
         and schemaname = 'public'
         and tablename = 'survey_responses'
     ) then
    alter publication supabase_realtime add table public.survey_responses;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 6. Registrar a la nutricionista como administradora
--    (ejecutar DESPUÉS de crear su usuario en Authentication → Users)
--    Reemplaza el correo y ejecuta solo estas líneas:
-- ---------------------------------------------------------------------
-- insert into public.admin_users (user_id)
-- select id from auth.users where email = 'correo-de-la-nutricionista@ejemplo.com'
-- on conflict (user_id) do nothing;
