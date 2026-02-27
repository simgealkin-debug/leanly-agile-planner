-- ===================== SUPABASE DATABASE SCHEMA =====================
-- Run this SQL in Supabase SQL Editor to create the tables

-- ===================== USER PROFILES =====================
-- Extends Supabase Auth users table with custom fields
CREATE TABLE IF NOT EXISTS user_profiles (
  id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  email TEXT,
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- ===================== TASKS =====================
CREATE TABLE IF NOT EXISTS tasks (
  id TEXT NOT NULL,
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  title TEXT NOT NULL,
  status TEXT NOT NULL CHECK (status IN ('todo', 'doing', 'done')),
  focus TEXT NOT NULL CHECK (focus IN ('work', 'personal', 'learning')),
  tags TEXT[] DEFAULT '{}',
  due_date TIMESTAMPTZ,
  created_at TIMESTAMPTZ NOT NULL,
  updated_at TIMESTAMPTZ NOT NULL,
  rolled_over BOOLEAN DEFAULT FALSE,
  carried_over_from_day TEXT,
  committed_today BOOLEAN DEFAULT FALSE,
  PRIMARY KEY (id, user_id)
);

-- Index for faster queries
CREATE INDEX IF NOT EXISTS idx_tasks_user_id ON tasks(user_id);
CREATE INDEX IF NOT EXISTS idx_tasks_user_status ON tasks(user_id, status);
CREATE INDEX IF NOT EXISTS idx_tasks_user_updated ON tasks(user_id, updated_at DESC);

-- ===================== DAY LOGS =====================
CREATE TABLE IF NOT EXISTS day_logs (
  id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id UUID NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  day_key TEXT NOT NULL, -- 'YYYY-MM-DD'
  mood TEXT NOT NULL CHECK (mood IN ('good', 'meh', 'hard')),
  mode TEXT NOT NULL CHECK (mode IN ('scrum', 'kanban', 'xp')),
  tasks_snapshot JSONB NOT NULL,
  archived_at TIMESTAMPTZ NOT NULL,
  UNIQUE(user_id, day_key)
);

-- Index for faster queries
CREATE INDEX IF NOT EXISTS idx_day_logs_user_id ON day_logs(user_id);
CREATE INDEX IF NOT EXISTS idx_day_logs_user_day ON day_logs(user_id, day_key DESC);

-- ===================== PREMIUM ENTITLEMENTS =====================
CREATE TABLE IF NOT EXISTS premium_entitlements (
  user_id UUID PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  is_premium BOOLEAN DEFAULT FALSE,
  purchase_date TIMESTAMPTZ,
  platform TEXT CHECK (platform IN ('ios', 'android')),
  created_at TIMESTAMPTZ DEFAULT NOW(),
  updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- ===================== ROW LEVEL SECURITY (RLS) =====================
-- Enable RLS on all tables
ALTER TABLE user_profiles ENABLE ROW LEVEL SECURITY;
ALTER TABLE tasks ENABLE ROW LEVEL SECURITY;
ALTER TABLE day_logs ENABLE ROW LEVEL SECURITY;
ALTER TABLE premium_entitlements ENABLE ROW LEVEL SECURITY;

-- ===================== RLS POLICIES =====================

-- User Profiles: Users can only see/update their own profile
CREATE POLICY "Users can view own profile"
  ON user_profiles FOR SELECT
  USING (auth.uid() = id);

CREATE POLICY "Users can update own profile"
  ON user_profiles FOR UPDATE
  USING (auth.uid() = id);

CREATE POLICY "Users can insert own profile"
  ON user_profiles FOR INSERT
  WITH CHECK (auth.uid() = id);

-- Tasks: Users can only see/modify their own tasks
CREATE POLICY "Users can view own tasks"
  ON tasks FOR SELECT
  USING (auth.uid() = user_id);

CREATE POLICY "Users can insert own tasks"
  ON tasks FOR INSERT
  WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can update own tasks"
  ON tasks FOR UPDATE
  USING (auth.uid() = user_id);

CREATE POLICY "Users can delete own tasks"
  ON tasks FOR DELETE
  USING (auth.uid() = user_id);

-- Day Logs: Users can only see/modify their own day logs
CREATE POLICY "Users can view own day logs"
  ON day_logs FOR SELECT
  USING (auth.uid() = user_id);

CREATE POLICY "Users can insert own day logs"
  ON day_logs FOR INSERT
  WITH CHECK (auth.uid() = user_id);

CREATE POLICY "Users can update own day logs"
  ON day_logs FOR UPDATE
  USING (auth.uid() = user_id);

CREATE POLICY "Users can delete own day logs"
  ON day_logs FOR DELETE
  USING (auth.uid() = user_id);

-- Premium Entitlements: Users can only see their own premium status
CREATE POLICY "Users can view own premium"
  ON premium_entitlements FOR SELECT
  USING (auth.uid() = user_id);

CREATE POLICY "Users can update own premium"
  ON premium_entitlements FOR UPDATE
  USING (auth.uid() = user_id);

CREATE POLICY "Users can insert own premium"
  ON premium_entitlements FOR INSERT
  WITH CHECK (auth.uid() = user_id);

-- ===================== FUNCTIONS =====================

-- Function to automatically create user profile on signup
CREATE OR REPLACE FUNCTION public.handle_new_user()
RETURNS TRIGGER AS $$
BEGIN
  INSERT INTO public.user_profiles (id, email)
  VALUES (NEW.id, NEW.email);
  RETURN NEW;
END;
$$ LANGUAGE plpgsql SECURITY DEFINER;

-- Trigger to create profile when user signs up
DROP TRIGGER IF EXISTS on_auth_user_created ON auth.users;
CREATE TRIGGER on_auth_user_created
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_user();

-- Function to update updated_at timestamp
CREATE OR REPLACE FUNCTION public.update_updated_at_column()
RETURNS TRIGGER AS $$
BEGIN
  NEW.updated_at = NOW();
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

-- Triggers for updated_at
CREATE TRIGGER update_user_profiles_updated_at
  BEFORE UPDATE ON user_profiles
  FOR EACH ROW
  EXECUTE FUNCTION public.update_updated_at_column();

CREATE TRIGGER update_premium_entitlements_updated_at
  BEFORE UPDATE ON premium_entitlements
  FOR EACH ROW
  EXECUTE FUNCTION public.update_updated_at_column();
