-- Leanly cloud tables + RLS. Run in Supabase SQL Editor once per project.
-- Enable Apple provider in Authentication > Providers (Sign in with Apple).

create table if not exists public.leanly_tasks (
  user_id uuid not null references auth.users (id) on delete cascade,
  task_id text not null,
  data jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now(),
  primary key (user_id, task_id)
);

create table if not exists public.leanly_settings (
  user_id uuid primary key references auth.users (id) on delete cascade,
  data jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now()
);

create table if not exists public.leanly_day_logs (
  user_id uuid not null references auth.users (id) on delete cascade,
  day_key text not null,
  data jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default now(),
  primary key (user_id, day_key)
);

create table if not exists public.leanly_pomodoro_days (
  user_id uuid not null references auth.users (id) on delete cascade,
  day_key text not null,
  sessions jsonb not null default '[]'::jsonb,
  updated_at timestamptz not null default now(),
  primary key (user_id, day_key)
);

alter table public.leanly_tasks enable row level security;
alter table public.leanly_settings enable row level security;
alter table public.leanly_day_logs enable row level security;
alter table public.leanly_pomodoro_days enable row level security;

drop policy if exists "leanly_tasks_own" on public.leanly_tasks;
drop policy if exists "leanly_settings_own" on public.leanly_settings;
drop policy if exists "leanly_day_logs_own" on public.leanly_day_logs;
drop policy if exists "leanly_pomodoro_days_own" on public.leanly_pomodoro_days;

create policy "leanly_tasks_own" on public.leanly_tasks
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

create policy "leanly_settings_own" on public.leanly_settings
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

create policy "leanly_day_logs_own" on public.leanly_day_logs
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);

create policy "leanly_pomodoro_days_own" on public.leanly_pomodoro_days
  for all using (auth.uid() = user_id) with check (auth.uid() = user_id);
